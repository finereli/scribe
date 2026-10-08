import Foundation
import AVFoundation
import CoreAudio

/// Captures everything the Mac plays (the other side of the call) with a
/// Core Audio process tap. No virtual driver, no screen-recording permission:
/// macOS asks once for "System Audio Recording" and that's it.
///
/// The tap is wrapped in a private aggregate device whose main sub-device is
/// the current output device. The output device is what clocks the tap: an
/// aggregate holding only the tap runs only while something else keeps the
/// hardware awake, and went silent after the first sound in testing.
///
/// When the output device is a headset (AirPods), its microphone becomes one
/// of the aggregate's inputs too. The tap's streams come after the
/// sub-devices', so the IO callback takes only the last buffers, the ones
/// belonging to the tap, and the user's voice stays out of "Them".
final class SystemAudioCapture {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "com.finereli.scribe.systemtap", qos: .userInitiated)
    private var tapList: UnsafeMutableAudioBufferListPointer?

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

        guard let outputUID = Self.defaultOutputUID() else {
            stop()
            throw Self.error("Couldn't find the Mac's audio output device.")
        }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Scribe System Audio",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID),
                  "create the capture device")

        // The tap's share of the input: one buffer per channel when
        // non-interleaved, else one buffer.
        let tapBuffers = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
            ? Int(asbd.mChannelsPerFrame) : 1
        let tapList = AudioBufferList.allocate(maximumBuffers: tapBuffers)
        self.tapList = tapList
        var logged = false

        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, input, _, _, _ in
            let all = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            if !logged {
                logged = true
                Log.write("System audio: \(all.count) input buffers, tap uses the last \(tapBuffers) (\(format))")
            }
            guard all.count >= tapBuffers else { return }
            for i in 0..<tapBuffers { tapList[i] = all[all.count - tapBuffers + i] }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                                bufferListNoCopy: tapList.unsafePointer,
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
        tapList?.unsafeMutablePointer.deallocate()
        tapList = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    private static func defaultOutputUID() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                         0, nil, &size, &device) == noErr, device != 0
        else { return nil }

        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: CFString? = nil
        size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &uid) {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
        }
        guard status == noErr else { return nil }
        return uid as String?
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
