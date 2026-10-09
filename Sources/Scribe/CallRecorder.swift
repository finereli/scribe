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

    private var micDevice: AudioDeviceID = 0
    private var currentMicDevice: () -> AudioDeviceID = { 0 }
    private var watchdog: Timer?

    /// Starts both sides. A failure on one side doesn't stop the other;
    /// the errors come back so the UI can say what's missing.
    /// `micDevice` is asked again every couple of seconds; when its answer
    /// changes (a new system default, a device picked mid-call) the mic
    /// follows.
    func start(micDevice: @escaping () -> AudioDeviceID) -> [String] {
        currentMicDevice = micDevice
        self.micDevice = micDevice()
        var problems: [String] = []
        if let error = startMic() { problems.append("Microphone: \(error.localizedDescription)") }
        if let error = startSystem() { problems.append("System audio: \(error.localizedDescription)") }

        // Audio flows continuously while capturing, silence included. A side
        // that goes quiet has been stopped underneath us, typically when
        // Bluetooth buds switch between music and call mode and macOS
        // rebuilds the audio setup. Restart it.
        watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.checkStreams()
        }
        return problems
    }

    private func startMic() -> Error? {
        Log.write("mic: starting device \(micDevice)")
        do {
            try mic.start(deviceID: micDevice) { [micStream] in micStream.ingest($0) }
            Log.write("mic: started")
            return nil
        } catch {
            Log.write("mic: failed: \(error.localizedDescription)")
            return error
        }
    }

    private func startSystem() -> Error? {
        Log.write("system audio: starting")
        do {
            try system.start { [systemStream] in systemStream.ingest($0) }
            Log.write("system audio: started")
            return nil
        } catch {
            Log.write("system audio: failed: \(error.localizedDescription)")
            return error
        }
    }

    private func checkStreams() {
        let now = Date()
        let wanted = currentMicDevice()
        if wanted != 0 && wanted != micDevice {
            Log.write("mic: switching from device \(micDevice) to \(wanted)")
            mic.stop()
            micDevice = wanted
            micStream.lastBufferAt = now
            _ = startMic()
        } else if now.timeIntervalSince(micStream.lastBufferAt) > 3 {
            Log.write("mic: no audio for 3s, restarting")
            mic.stop()
            micStream.lastBufferAt = now   // give the restart time to deliver
            _ = startMic()
        }
        if now.timeIntervalSince(systemStream.lastBufferAt) > 3 {
            Log.write("system audio: no audio for 3s, restarting")
            system.stop()
            systemStream.lastBufferAt = now
            _ = startSystem()
        }
    }

    func stop(completion: @escaping () -> Void) {
        watchdog?.invalidate()
        watchdog = nil
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
