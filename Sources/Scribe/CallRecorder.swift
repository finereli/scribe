import Foundation
import AVFoundation
import CoreAudio

/// One call in progress: mic and system audio captured side by side, each
/// with its own file and its own recognizer.
final class CallRecorder {
    let micStream: SpeakerStream
    let systemStream: SpeakerStream
    private let mic = MicCapture()
    private let system = SystemAudioCapture()

    init(folder: URL, languageCode: String, start: Date) {
        micStream = SpeakerStream(
            recognizer: TurnRecognizer(speaker: .me, languageCode: languageCode),
            fileURL: folder.appendingPathComponent(Session.micFile), callStart: start)
        systemStream = SpeakerStream(
            recognizer: TurnRecognizer(speaker: .them, languageCode: languageCode),
            fileURL: folder.appendingPathComponent(Session.systemFile), callStart: start)
    }

    /// Starts both sides. A failure on one side doesn't stop the other;
    /// the errors come back so the UI can say what's missing.
    func start(micDevice: AudioDeviceID) -> [String] {
        var problems: [String] = []
        Log.write("mic: starting device \(micDevice)")
        do {
            try mic.start(deviceID: micDevice) { [micStream] in micStream.ingest($0) }
            Log.write("mic: started")
        } catch {
            problems.append("Microphone: \(error.localizedDescription)")
        }
        Log.write("system audio: starting")
        do {
            try system.start { [systemStream] in systemStream.ingest($0) }
            Log.write("system audio: started")
        } catch {
            problems.append("System audio: \(error.localizedDescription)")
        }
        return problems
    }

    func stop(completion: @escaping () -> Void) {
        mic.stop()
        system.stop()
        let group = DispatchGroup()
        for stream in [micStream, systemStream] {
            group.enter()
            stream.finish { group.leave() }
        }
        group.notify(queue: .main, execute: completion)
    }
}
