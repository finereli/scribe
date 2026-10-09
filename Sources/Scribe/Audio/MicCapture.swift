import Foundation
import AVFoundation
import CoreAudio

/// Captures the chosen input device (your side of the call) with
/// AVAudioEngine. A fresh engine per call, so a device picked since the last
/// call is honored with its own format.
final class MicCapture {
    private var engine: AVAudioEngine?
    private var observer: NSObjectProtocol?

    func start(deviceID: AudioDeviceID, handler: @escaping (AVAudioPCMBuffer) -> Void) throws {
        let engine = AVAudioEngine()
        // The engine starts on the system default; only switch when asked for
        // something else.
        if deviceID != 0, deviceID != AudioDeviceManager.defaultInputDeviceID(),
           let unit = engine.inputNode.audioUnit {
            var dev = deviceID
            let err = AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
            if err != noErr {
                throw NSError(domain: "Scribe.Mic", code: Int(err), userInfo: [
                    NSLocalizedDescriptionKey: "Couldn't select the microphone (error \(err))."])
            }
        }

        // After switching devices the node's output format can still be the
        // previous device's (say 16 kHz buds), and a tap in a format that
        // doesn't match the hardware throws and kills the app. Use what the
        // hardware itself reports.
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "Scribe.Mic", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "The microphone isn't providing audio. Check microphone permission and that the device is connected."])
        }

        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            handler(buffer)
        }
        Log.write("mic: format \(format)")
        engine.prepare()
        try engine.start()
        self.engine = engine
        // The engine stops itself when the audio setup changes (buds
        // connecting, Meet switching devices). The call's watchdog restarts
        // it; this just records why.
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { _ in Log.write("mic: engine configuration changed, running=\(engine.isRunning)") }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }
}
