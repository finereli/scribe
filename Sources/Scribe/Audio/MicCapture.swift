import Foundation
import AVFoundation
import CoreAudio

/// Captures the chosen input device (your side of the call) with
/// AVAudioEngine. A fresh engine per call, so a device picked since the last
/// call is honored with its own format.
final class MicCapture {
    private var engine: AVAudioEngine?

    func start(deviceID: AudioDeviceID, handler: @escaping (AVAudioPCMBuffer) -> Void) throws {
        let engine = AVAudioEngine()
        if deviceID != 0, let unit = engine.inputNode.audioUnit {
            var dev = deviceID
            let err = AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
            if err != noErr {
                throw NSError(domain: "Scribe.Mic", code: Int(err), userInfo: [
                    NSLocalizedDescriptionKey: "Couldn't select the microphone (error \(err))."])
            }
        }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "Scribe.Mic", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "The microphone isn't providing audio. Check microphone permission and that the device is connected."])
        }

        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            handler(buffer)
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }
}
