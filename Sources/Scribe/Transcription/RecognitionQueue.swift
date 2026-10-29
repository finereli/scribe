import Foundation
import AVFoundation

/// Transcribes turns with OpenAI, one upload per turn.
///
/// A turn's audio is collected while the person talks. When the turn ends it
/// goes up as a small WAV and its text comes back a second or two later.
/// Turns upload in parallel (a few at a time) and land in any order; each
/// carries its own start time, so the transcript sorts itself. The Mac does
/// nothing but record. No language is set: OpenAI works it out for each
/// turn, so a call can move between languages freely.
///
/// When a turn can't be transcribed its audio is still in the recording, so
/// the call can be transcribed again later. What can go wrong:
/// - No key, or a key OpenAI rejects: fail at once, and keep failing fast
///   until the key changes.
/// - Out of credit: fail, and don't try again for a minute.
/// - Rate limits and server errors: retry with backoff.
/// - Offline: keep retrying for a few minutes, so a dropped connection
///   catches up instead of losing turns.
final class RecognitionQueue: @unchecked Sendable {
    /// Called on main for every partial and final result.
    var onUpdate: ((Turn) -> Void)?
    /// Called on main for a turn that couldn't be transcribed.
    var onFailed: ((Turn) -> Void)?
    /// Called on main with a problem, or nil once a turn goes through.
    var onStatus: ((TranscriptionProblem?) -> Void)?
    /// Called on main with turns finished and turns started so far.
    var onProgress: ((Int, Int) -> Void)?

    private final class Job: @unchecked Sendable {
        let id = UUID()
        let speaker: Speaker
        let start: TimeInterval
        var samples: [Float] = []
        var prompt = ""
        var attempt = 0
        var offlineSince: Date?

        init(speaker: Speaker, start: TimeInterval) {
            self.speaker = speaker
            self.start = start
        }

        var turn: Turn {
            Turn(id: id, speaker: speaker, start: start,
                 end: start + Double(samples.count) / WAV.sampleRate, text: "", isFinal: true)
        }
    }

    // Touched only on `queue`.
    private let queue = DispatchQueue(label: "com.finereli.scribe.recognition")
    private var open: [UUID: Job] = [:]
    private var waiting: [Job] = []
    private var running = 0
    private var retrying = 0
    private var started = 0
    private var finished = 0
    /// The last words transcribed, sent as the prompt so a turn that starts
    /// mid-thought has context.
    private var context = ""
    private var cancelled = false
    private var drainWaiters: [() -> Void] = []
    /// A key OpenAI turned down, and why. Turns fail fast until it changes.
    private var refused: (key: String, problem: TranscriptionProblem, until: Date)?

    private let maxUploads = 6
    private let offlinePatience: TimeInterval = 180

    // MARK: - Turns (any thread)

    func begin(speaker: Speaker, at start: TimeInterval) -> UUID {
        let job = Job(speaker: speaker, start: start)
        queue.async {
            guard !self.cancelled else { return }
            self.open[job.id] = job
            self.started += 1
            self.progress()
            // Show that this speaker is talking until the text arrives, unless
            // it's already clear no text is coming.
            if self.blocker() == nil {
                self.emit(Turn(id: job.id, speaker: speaker, start: start, end: start, text: "…", isFinal: false))
            }
        }
        return job.id
    }

    func append(_ buffer: AVAudioPCMBuffer, to id: UUID) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        queue.async { self.open[id]?.samples += samples }
    }

    func end(_ id: UUID) {
        queue.async {
            guard !self.cancelled, let job = self.open.removeValue(forKey: id) else { return }
            job.prompt = self.context
            self.waiting.append(job)
            self.pump()
        }
    }

    func cancelAll() {
        queue.async {
            self.cancelled = true
            self.open = [:]
            self.waiting = []
            self.checkDrained()
        }
    }

    /// Calls back on main once every turn begun so far is transcribed or has
    /// failed. Turns still open count, so end them first.
    func drain(_ completion: @escaping () -> Void) {
        queue.async {
            self.drainWaiters.append(completion)
            self.checkDrained()
        }
    }

    // MARK: - Uploading (on queue)

    private func pump() {
        while running < maxUploads, !waiting.isEmpty, !cancelled {
            let job = waiting.removeFirst()
            if let problem = blocker() {
                fail(job, problem: problem, reason: "skipped")
                continue
            }
            guard let key = APIKey.current else {
                fail(job, problem: .noKey, reason: "no key")
                continue
            }
            running += 1
            job.attempt += 1
            let wav = WAV.encode(job.samples)
            let sent = Date()
            Task {
                let outcome = await OpenAI.transcribe(wav: wav, prompt: job.prompt, key: key)
                self.queue.async {
                    self.running -= 1
                    self.handle(outcome, for: job, key: key, sent: sent)
                    self.pump()
                }
            }
        }
        checkDrained()
    }

    private func handle(_ outcome: OpenAI.Outcome, for job: Job, key: String, sent: Date) {
        guard !cancelled else { return }
        let label = job.speaker.label
        switch outcome {
        case .text(let text):
            var turn = job.turn
            turn.text = text
            if !text.isEmpty { context = String((context + " " + text).suffix(200)) }
            Log.write(String(format: "recognizer %@: %.1fs of audio in %.1fs", label,
                             turn.end - turn.start, Date().timeIntervalSince(sent)))
            refused = nil
            finished += 1
            emit(turn)
            status(nil)
            progress()
        case .rejected(let message):
            refused = (key, .rejected(message), .distantFuture)
            fail(job, problem: .rejected(message), reason: message)
        case .noCredit:
            refused = (key, .noCredit, Date().addingTimeInterval(60))
            fail(job, problem: .noCredit, reason: "out of credit")
        case .busy(let reason):
            Log.write("recognizer \(label): attempt \(job.attempt) busy: \(reason)")
            if job.attempt < 6 {
                retry(job, after: min(30, pow(2, Double(job.attempt))))
            } else {
                fail(job, problem: nil, reason: reason)
            }
        case .offline(let reason):
            Log.write("recognizer \(label): attempt \(job.attempt) offline: \(reason)")
            let since = job.offlineSince ?? Date()
            job.offlineSince = since
            status(.offline)
            if Date().timeIntervalSince(since) < offlinePatience {
                retry(job, after: 5)
            } else {
                fail(job, problem: nil, reason: "offline for \(Int(offlinePatience))s")
            }
        case .failed(let reason):
            fail(job, problem: nil, reason: reason)
        }
    }

    private func retry(_ job: Job, after delay: TimeInterval) {
        retrying += 1
        queue.asyncAfter(deadline: .now() + delay) {
            self.retrying -= 1
            guard !self.cancelled else { return self.checkDrained() }
            self.waiting.insert(job, at: 0)
            self.pump()
        }
    }

    private func fail(_ job: Job, problem: TranscriptionProblem?, reason: String) {
        Log.write("recognizer \(job.speaker.label): turn at \(Format.duration(job.start)) not transcribed: \(reason)")
        finished += 1
        let turn = job.turn
        DispatchQueue.main.async { self.onFailed?(turn) }
        if let problem { status(problem) }
        progress()
    }

    /// Why a turn would fail before it's sent, if it would.
    private func blocker() -> TranscriptionProblem? {
        guard let key = APIKey.current else { return .noKey }
        guard let refused, refused.key == key, Date() < refused.until else { return nil }
        return refused.problem
    }

    private func checkDrained() {
        let idle = running == 0 && retrying == 0 && (cancelled || (open.isEmpty && waiting.isEmpty))
        guard idle, !drainWaiters.isEmpty else { return }
        let waiters = drainWaiters
        drainWaiters = []
        DispatchQueue.main.async { waiters.forEach { $0() } }
    }

    private func status(_ problem: TranscriptionProblem?) {
        DispatchQueue.main.async { self.onStatus?(problem) }
    }

    private func progress() {
        let (done, total) = (finished, started)
        DispatchQueue.main.async { self.onProgress?(done, total) }
    }

    private func emit(_ turn: Turn) {
        DispatchQueue.main.async { self.onUpdate?(turn) }
    }
}
