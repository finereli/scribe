import Foundation
import AVFoundation

/// Transcribes a saved call from its two recordings: the same turn cutting
/// and uploads as a live call, only as fast as the audio can be read.
/// Used for calls recorded without a working key, turns lost while offline,
/// and calls from before Scribe went online.
final class Retranscriber {
    struct Result {
        var turns: [Turn]
        var missing: Int
        /// Set when the run stopped because of the key or the account.
        var problem: TranscriptionProblem?
        /// Neither recording could be opened, e.g. the app was killed
        /// before the files were closed.
        var unreadable = false
    }

    let recognition: RecognitionQueue
    /// Called on main with every status report, as for a live call.
    var onStatus: ((TranscriptionProblem?) -> Void)?
    private let folder: URL
    private let session: Session
    private var turns: [UUID: Turn] = [:]
    private var missing = 0
    private var problem: TranscriptionProblem?
    private var cancelled = false

    init(folder: URL, session: Session) {
        self.folder = folder
        self.session = session
        recognition = RecognitionQueue()
    }

    /// Calls back on main when every turn is in or has failed.
    func run(completion: @escaping (Result) -> Void) {
        recognition.onUpdate = { [weak self] turn in
            guard turn.isFinal, !turn.text.isEmpty else { return }
            self?.turns[turn.id] = turn
        }
        recognition.onFailed = { [weak self] _ in self?.missing += 1 }
        recognition.onStatus = { [weak self] problem in
            self?.onStatus?(problem)
            guard let self, let problem, problem != .offline, self.problem == nil else { return }
            // A key or credit problem fails every turn after it; stop paying
            // attention to the rest.
            self.problem = problem
            self.cancel()
        }

        let sides: [(Speaker, String, TimeInterval)] = [
            (.me, Session.micFile, session.micOffset ?? 0),
            (.them, Session.systemFile, session.systemOffset ?? 0),
        ]
        let tracks = sides.compactMap { speaker, name, offset -> (TurnRecognizer, AVAudioFile, TimeInterval)? in
            guard let file = try? AVAudioFile(forReading: folder.appendingPathComponent(name)) else { return nil }
            return (TurnRecognizer(speaker: speaker, recognition: recognition), file, offset)
        }
        guard !tracks.isEmpty else {
            DispatchQueue.main.async { completion(Result(turns: [], missing: 0, unreadable: true)) }
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            // Interleave the two tracks by time so each turn's prompt holds
            // what was said just before it, by either side.
            let chunk: AVAudioFrameCount = 1_600   // 0.1 s
            var t: TimeInterval = 0
            while !cancelled, tracks.contains(where: { $0.1.framePosition < $0.1.length }) {
                for (recognizer, file, offset) in tracks where file.framePosition < file.length {
                    let at = offset + Double(file.framePosition) / file.processingFormat.sampleRate
                    guard at <= t + 0.1,
                          let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk),
                          (try? file.read(into: buffer, frameCount: chunk)) != nil else { continue }
                    recognizer.feed(buffer, at: at, db: SpeakerStream.decibels(buffer))
                }
                t += 0.1
            }
            tracks.forEach { $0.0.finishTurn() }
            recognition.drain { [self] in
                completion(Result(turns: turns.values.sorted { $0.start < $1.start },
                                  missing: missing, problem: problem))
            }
        }
    }

    func cancel() {
        cancelled = true
        recognition.cancelAll()
    }
}
