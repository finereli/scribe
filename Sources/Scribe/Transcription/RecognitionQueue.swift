import Foundation
import AVFoundation
import Speech

/// Runs speech recognition one turn at a time for both speakers.
///
/// macOS runs one recognition task per app: starting a second one cancels
/// the first. So turns queue up here. A turn that starts while nothing else
/// is being recognized streams live, with partial results as the person
/// talks. A turn that starts while the other speaker's turn is running
/// collects its audio, and is recognized from that buffer as soon as the
/// recognizer is free.
final class RecognitionQueue {
    /// Called on the main queue for every partial and final result.
    var onUpdate: ((Turn) -> Void)?
    /// Called on the main queue for recognizer errors worth showing.
    var onError: ((String) -> Void)?

    private final class Job {
        let id = UUID()
        let speaker: Speaker
        let start: TimeInterval
        var buffers: [AVAudioPCMBuffer] = []
        var ended = false
        var request: SFSpeechAudioBufferRecognitionRequest?
        var task: SFSpeechRecognitionTask?
        var turn: Turn
        /// Text from before the recognizer last started over, and the
        /// latest result since then. See `handle`.
        var earlier = ""
        var latest = ""

        init(speaker: Speaker, start: TimeInterval) {
            self.speaker = speaker
            self.start = start
            turn = Turn(id: id, speaker: speaker, start: start, end: start, text: "", isFinal: false)
        }
    }

    // Replaced when the language changes mid-call; touched only on `queue`
    // after init.
    private var recognizer: SFSpeechRecognizer?
    private var onDevice: Bool
    private let queue = DispatchQueue(label: "com.finereli.scribe.recognition")
    private var jobs: [UUID: Job] = [:]
    private var active: Job?
    private var pending: [Job] = []

    init(languageCode: String) {
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: languageCode))
        recognizer?.defaultTaskHint = .dictation
        self.recognizer = recognizer
        onDevice = recognizer?.supportsOnDeviceRecognition ?? false
    }

    // MARK: - Turns (any thread)

    func begin(speaker: Speaker, at start: TimeInterval) -> UUID {
        let job = Job(speaker: speaker, start: start)
        queue.async {
            self.jobs[job.id] = job
            if self.active == nil { self.run(job) } else { self.pending.append(job) }
        }
        return job.id
    }

    func append(_ buffer: AVAudioPCMBuffer, to id: UUID) {
        queue.async {
            guard let job = self.jobs[id] else { return }
            if let request = job.request { request.append(buffer) } else { job.buffers.append(buffer) }
        }
    }

    func end(_ id: UUID) {
        queue.async {
            guard let job = self.jobs[id], !job.ended else { return }
            job.ended = true
            job.request?.endAudio()
            if job === self.active { self.watch(job) }
        }
    }

    /// Switch languages mid-call. Turns already running finish in the old
    /// language; turns that start or are still queued use the new one.
    func setLanguage(_ languageCode: String) {
        queue.async {
            let recognizer = SFSpeechRecognizer(locale: Locale(identifier: languageCode))
            recognizer?.defaultTaskHint = .dictation
            self.recognizer = recognizer
            self.onDevice = recognizer?.supportsOnDeviceRecognition ?? false
            Log.write("recognizer: switched to \(languageCode)")
        }
    }

    func cancelAll() {
        queue.async {
            self.active?.task?.cancel()
            self.active = nil
            self.pending = []
            self.jobs = [:]
        }
    }

    // MARK: - Running (on queue)

    private func run(_ job: Job) {
        guard let recognizer, recognizer.isAvailable else {
            Log.write("recognizer unavailable, dropping a \(job.speaker.label) turn")
            jobs[job.id] = nil
            runNext()
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = onDevice
        request.addsPunctuation = true
        job.request = request
        active = job

        job.task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            self?.queue.async { self?.handle(job, result: result, error: error) }
        }
        job.buffers.forEach { request.append($0) }
        job.buffers = []
        if job.ended {
            request.endAudio()
            watch(job)
        }
    }

    private func handle(_ job: Job, result: SFSpeechRecognitionResult?, error: Error?) {
        guard jobs[job.id] != nil, !job.turn.isFinal else { return }
        if let result {
            // On-device recognition starts over after a pause inside a turn:
            // the next result holds only the words since the pause, and the
            // final one is often empty. Keep what came before, or a turn with
            // a pause in it loses everything up to its last few words.
            let text = result.bestTranscription.formattedString
            if text.isEmpty {
                // An empty final result: keep what the partials said.
            } else if Self.startedOver(from: job.latest, to: text) {
                job.earlier = Self.join(job.earlier, job.latest)
                job.latest = text
            } else if Self.repeats(job.earlier, in: text) {
                // Sometimes it hands back the whole turn again after all.
                job.earlier = ""
                job.latest = text
            } else {
                job.latest = text
            }
            job.turn.text = Self.join(job.earlier, job.latest)
            if Self.trace { print("TRACE \(job.id.uuidString.prefix(4)) \(result.isFinal ? "F" : "p") [\(job.earlier.split(separator: " ").count)] \(text)") }
            if let last = result.bestTranscription.segments.last {
                job.turn.end = max(job.turn.end, job.start + last.timestamp + last.duration)
            }
            if result.isFinal { finish(job) } else { emit(job.turn) }
        } else if let error {
            let code = (error as NSError).code
            Log.write("recognizer \(job.speaker.label): \((error as NSError).domain) \(code) \(error.localizedDescription)")
            // 1110 is "no speech detected": a turn that was only noise.
            if code != 1110 && job.turn.text.isEmpty {
                let message = "\(job.speaker.label): \(error.localizedDescription)"
                DispatchQueue.main.async { self.onError?(message) }
            }
            finish(job)
        }
    }

    /// A result that isn't a revision of the previous one: it lost several
    /// words, or it's shorter and begins differently. Revisions touch the
    /// last word or two, and early on the first word ("I think" becoming
    /// "Think"), hence the three-word minimum for the second test.
    static func startedOver(from previous: String, to text: String) -> Bool {
        let before = previous.split(separator: " ")
        let after = text.split(separator: " ")
        guard !before.isEmpty, after.count < before.count else { return false }
        if after.count + 3 < before.count { return true }
        let first = { (w: Substring?) in w.map { $0.lowercased().filter(\.isLetter) } }
        return before.count >= 3 && first(before.first) != first(after.first)
    }

    /// Whether `text` starts with the same words as `earlier`, meaning the
    /// recognizer is returning the whole turn again.
    static func repeats(_ earlier: String, in text: String) -> Bool {
        let a = words(earlier), b = words(text)
        let n = min(a.count, 4)
        return n > 0 && b.count >= a.count && Array(b.prefix(n)) == Array(a.prefix(n))
    }

    private static func words(_ s: String) -> [String] {
        s.split(separator: " ").map { $0.lowercased().filter { $0.isLetter || $0.isNumber } }
    }

    private static let trace = ProcessInfo.processInfo.environment["SCRIBE_TRACE"] != nil

    static func join(_ a: String, _ b: String) -> String {
        a.isEmpty ? b : b.isEmpty ? a : a + " " + b
    }

    private func finish(_ job: Job) {
        job.turn.isFinal = true
        emit(job.turn)
        jobs[job.id] = nil
        if job === active {
            active = nil
            runNext()
        }
    }

    private func runNext() {
        guard active == nil, !pending.isEmpty else { return }
        run(pending.removeFirst())
    }

    /// A task that never returns its final result would stall the queue.
    private func watch(_ job: Job) {
        queue.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, self.jobs[job.id] != nil, job === self.active else { return }
            Log.write("recognizer \(job.speaker.label): no final result after 15s, moving on")
            job.task?.cancel()
            self.finish(job)
        }
    }

    private func emit(_ turn: Turn) {
        DispatchQueue.main.async { self.onUpdate?(turn) }
    }
}
