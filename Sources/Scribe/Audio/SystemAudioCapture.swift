import Foundation
import AVFoundation
import CoreAudio

/// Captures everything the Mac plays (the other side of the call) with a
/// Core Audio process tap. No virtual driver, no screen-recording permission:
/// macOS asks once for "System Audio Recording" and that's it.
///
/// The tap is wrapped in a private aggregate device that contains only the
/// tap. Adding the output device as a sub-device would also pull in its
/// microphone when that device is a headset (AirPods), mixing the user's
/// voice into "Them".
final class SystemAudioCapture {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "com.finereli.scribe.systemtap", qos: .userInitiated)

    /// Start delivering buffers to `handler` on a private queue. Each buffer
    /// is only valid for the duration of the call.
    func start(handler: @escaping (AVAudioPCMBuffer) -> Void) throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.name = "Scribe"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        try check(AudioHardwareCreateProcessTap(description, &tapID), "create the system audio tap")

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        try check(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd), "read the tap format")
        guard let format = AVAudioFormat(streamDescription: &asbd) else {
            stop()
            throw Self.error("The system audio tap reported an unusable format.")
        }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Scribe System Audio",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [] as [Any],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID),
                  "create the capture device")

        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, input, _, _, _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input,
                                                deallocator: nil),
                  buffer.frameLength > 0 else { return }
            handler(buffer)
        }, "attach to the capture device")

        try check(AudioDeviceStart(aggregateID, procID), "start system audio capture")
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    private func check(_ status: OSStatus, _ what: String) throws {
        guard status != noErr else { return }
        stop()
        throw Self.error("Couldn't \(what) (error \(status)).")
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "Scribe.SystemAudio", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
