import Foundation
import AVFoundation
import CoreAudio

/// One call in progress: mic and system audio captured side by side, each
/// with its own file and its own recognizer.
final class CallRecorder {
    let micStream: SpeakerStream
    let systemStream: SpeakerStream
    let recognition: RecognitionQueue
    private let mic = MicCapture()
    private let system = SystemAudioCapture()

    init(folder: URL, languageCode: String, start: Date) {
        let recognition = RecognitionQueue(languageCode: languageCode)
        self.recognition = recognition
        micStream = SpeakerStream(
            recognizer: TurnRecognizer(speaker: .me, recognition: recognition),
            fileURL: folder.appendingPathComponent(Session.micFile), callStart: start)
        systemStream = SpeakerStream(
            recognizer: TurnRecognizer(speaker: .them, recognition: recognition),
            fileURL: folder.appendingPathComponent(Session.systemFile), callStart: start)
    }

    private var micDevice: AudioDeviceID = 0
    private var currentMicDevice: () -> AudioDeviceID = { 0 }
    private var watchdog: Timer?

    /// Stopping and restarting capture happens here, never on main. When a
    /// device vanishes (buds disconnecting, a call app releasing its device)
    /// Core Audio can deadlock inside removeTap or AudioDeviceStop, and on
    /// main that froze the whole app. Here it only stalls this queue.
    private let captureQueue = DispatchQueue(label: "com.finereli.scribe.capture", qos: .userInitiated)
    /// A restart is queued or running. Main only.
    private var restarting = false

    /// Starts both sides. A failure on one side doesn't stop the other;
    /// the errors come back so the UI can say what's missing.
    /// `micDevice` is asked again every couple of seconds; when its answer
    /// changes (a new system default, a device picked mid-call) the mic
    /// follows.
    func start(micDevice: @escaping () -> AudioDeviceID) -> [String] {
        currentMicDevice = micDevice
        self.micDevice = micDevice()
        var problems: [String] = []
        if let error = startMic(device: self.micDevice) { problems.append("Microphone: \(error.localizedDescription)") }
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

    private func startMic(device: AudioDeviceID) -> Error? {
        Log.write("mic: starting device \(device)")
        do {
            try mic.start(deviceID: device) { [micStream] in micStream.ingest($0) }
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
        if restarting {
            Log.write("watchdog: previous restart still running, skipping")
            return
        }
        let now = Date()
        let wanted = currentMicDevice()
        var restartMic = false
        if wanted != 0 && wanted != micDevice {
            Log.write("mic: switching from device \(micDevice) to \(wanted)")
            micDevice = wanted
            restartMic = true
        } else if now.timeIntervalSince(micStream.lastBufferAt) > 3 {
            Log.write("mic: no audio for 3s, restarting")
            restartMic = true
        }
        let restartSystem = now.timeIntervalSince(systemStream.lastBufferAt) > 3
        if restartSystem { Log.write("system audio: no audio for 3s, restarting") }
        guard restartMic || restartSystem else { return }

        // Give the restart time to deliver before the next check.
        if restartMic { micStream.lastBufferAt = now }
        if restartSystem { systemStream.lastBufferAt = now }
        restarting = true
        let device = micDevice
        captureQueue.async { [self] in
            if restartMic {
                mic.stop()
                _ = startMic(device: device)
            }
            if restartSystem {
                system.stop()
                _ = startSystem()
            }
            DispatchQueue.main.async { self.restarting = false }
        }
    }

    /// New words are transcribed in `languageCode` from the next turn on.
    func setLanguage(_ languageCode: String) {
        recognition.setLanguage(languageCode)
        micStream.endTurn()
        systemStream.endTurn()
    }

    func stop(completion: @escaping () -> Void) {
        watchdog?.invalidate()
        watchdog = nil

        // Close the files once capture has stopped, or after two seconds if
        // Core Audio is stuck, so a hung device never costs the recording.
        var finished = false
        let finishStreams = { [micStream, systemStream] in
            guard !finished else { return }
            finished = true
            let group = DispatchGroup()
            for stream in [micStream, systemStream] {
                group.enter()
                stream.finish { group.leave() }
            }
            group.notify(queue: .main, execute: completion)
        }
        captureQueue.async { [mic, system] in
            mic.stop()
            system.stop()
            DispatchQueue.main.async(execute: finishStreams)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if !finished { Log.write("stop: capture didn't stop within 2s, saving anyway") }
            finishStreams()
        }
    }
}
