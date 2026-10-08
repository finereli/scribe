import Foundation
import AVFoundation
import Speech

/// Live speech recognition for one speaker, one turn at a time.
///
/// Rather than one recognition request for the whole call, a request opens
/// when this speaker starts talking and closes after a pause. That keeps
/// every request well under Apple's one-minute server limit (Hebrew and
/// Russian aren't on-device), gives each turn a real start time for
/// interleaving the two speakers, and keeps the recognizer idle during
/// silence.
final class TurnRecognizer {
    let speaker: Speaker
    /// Called on the main queue for every partial and final result.
    var onUpdate: ((Turn) -> Void)?
    /// Called on the main queue for recognizer errors worth showing.
    var onError: ((String) -> Void)?

    private let recognizer: SFSpeechRecognizer?
    private let onDevice: Bool
    private static let sampleRate: Double = 16_000

    // Turn state, touched only on the owning stream's queue.
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var turnStart: TimeInterval = 0
    private var lastVoice: TimeInterval = 0
    private var preroll: [(buffer: AVAudioPCMBuffer, at: TimeInterval)] = []
    private var floorDB: Float = -60

    // Running tasks, touched only on main.
    private var tasks: [UUID: SFSpeechRecognitionTask] = [:]

    // Pause that ends a turn, and the limits that force one to end.
    private let pauseToEnd: TimeInterval = 1.0
    private let softLimit: TimeInterval = 40
    private let hardLimit: TimeInterval = 55
    private let prerollLength: TimeInterval = 0.4

    init(speaker: Speaker, languageCode: String) {
        self.speaker = speaker
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: languageCode))
        recognizer?.defaultTaskHint = .dictation
        self.recognizer = recognizer
        self.onDevice = recognizer?.supportsOnDeviceRecognition ?? false
    }

    /// Feed one 16 kHz mono buffer that starts `at` seconds into the call.
    func feed(_ buffer: AVAudioPCMBuffer, at t: TimeInterval, db: Float) {
        let length = Double(buffer.frameLength) / Self.sampleRate
        let end = t + length

        // Track the noise floor: drop to quiet instantly, rise slowly, so a
        // noisy room doesn't count as speech and a quiet one stays sensitive.
        floorDB = db < floorDB ? db : min(floorDB + Float(length) * 0.5, -30)
        let voiced = db > max(floorDB + 10, -55)

        guard let request else {
            preroll.append((buffer, t))
            while let first = preroll.first, end - first.at > prerollLength { preroll.removeFirst() }
            guard voiced else { return }
            begin(at: preroll.first?.at ?? t)
            preroll.forEach { self.request?.append($0.buffer) }
            preroll = []
            lastVoice = end
            return
        }

        request.append(buffer)
        if voiced { lastVoice = end }
        let silence = end - lastVoice
        let elapsed = end - turnStart
        if silence > pauseToEnd || (elapsed > softLimit && silence > 0.3) || elapsed > hardLimit {
            finishTurn()
        }
    }

    /// Close the turn in progress; its final result still arrives.
    func finishTurn() {
        request?.endAudio()
        request = nil
    }

    private func begin(at start: TimeInterval) {
        guard let recognizer, recognizer.isAvailable else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = onDevice
        request.addsPunctuation = true
        self.request = request
        turnStart = start

        let id = UUID()
        let speaker = self.speaker
        var turn = Turn(id: id, speaker: speaker, start: start, end: start, text: "", isFinal: false)

        let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            // SFSpeechRecognizer delivers on its queue, which is main.
            guard let self else { return }
            if let result {
                turn.text = result.bestTranscription.formattedString
                if let last = result.bestTranscription.segments.last {
                    turn.end = start + last.timestamp + last.duration
                }
                turn.isFinal = result.isFinal
                self.onUpdate?(turn)
                if result.isFinal { self.tasks[id] = nil }
            } else if let error {
                // Ending a turn with no speech in it surfaces as an error.
                let code = (error as NSError).code
                if ![203, 216, 301, 1110].contains(code) {
                    self.onError?("\(speaker.label): \(error.localizedDescription)")
                }
                turn.isFinal = true
                self.onUpdate?(turn)
                self.tasks[id] = nil
            }
        }
        DispatchQueue.main.async { self.tasks[id] = task }
    }

    /// Stop everything, waiting for nothing.
    func cancelAll() {
        DispatchQueue.main.async {
            self.tasks.values.forEach { $0.cancel() }
            self.tasks = [:]
        }
    }
}
