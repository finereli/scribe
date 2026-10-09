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

        init(speaker: Speaker, start: TimeInterval) {
            self.speaker = speaker
            self.start = start
            turn = Turn(id: id, speaker: speaker, start: start, end: start, text: "", isFinal: false)
        }
    }

    private let recognizer: SFSpeechRecognizer?
    private let onDevice: Bool
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
            job.turn.text = result.bestTranscription.formattedString
            if let last = result.bestTranscription.segments.last {
                job.turn.end = job.start + last.timestamp + last.duration
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
