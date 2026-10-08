import Foundation
import AVFoundation
import CoreAudio

/// Captures everything the Mac plays (the other side of the call) with a
/// Core Audio process tap. No virtual driver, no screen-recording permission:
/// macOS asks once for "System Audio Recording" and that's it.
///
/// The tap is wrapped in a private aggregate device with one real output
/// device as its clock. An aggregate holding only the tap runs only while
/// something else keeps the hardware awake, and went silent after the first
/// sound in testing.
///
/// The clock must not have a microphone. Using Bluetooth buds as the clock
/// would open their mic and drop them into low-quality call mode, even when
/// the call itself uses the Mac's built-in mic. So the clock is the current
/// output if it has no input, otherwise the built-in speakers (which play
/// nothing; drift compensation absorbs the clock difference). As a second
/// guard, the IO callback takes only the tap's buffers, which come after any
/// sub-device's.
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

        guard let outputUID = Self.clockDeviceUID() else {
            stop()
            throw Self.error("Couldn't find an audio output device to clock the capture.")
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

    /// The default output if it has no microphone, else a built-in output.
    private static func clockDeviceUID() -> String? {
        var candidates: [AudioDeviceID] = []
        if let def = defaultOutput() { candidates.append(def) }
        candidates += allDevices().filter {
            transportType($0) == kAudioDeviceTransportTypeBuiltIn && channels($0, kAudioObjectPropertyScopeOutput) > 0
        }
        guard let device = candidates.first(where: {
            channels($0, kAudioObjectPropertyScopeOutput) > 0 && channels($0, kAudioObjectPropertyScopeInput) == 0
        }) else { return nil }
        let uid = stringProperty(device, kAudioDevicePropertyDeviceUID)
        Log.write("System audio: clocked by \(stringProperty(device, kAudioObjectPropertyName) ?? "?")")
        return uid
    }

    private static func defaultOutput() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                         0, nil, &size, &device) == noErr, device != 0
        else { return nil }
        return device
    }

    private static func allDevices() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address,
                                             0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                         0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func transportType(_ device: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        return value
    }

    private static func channels(_ device: AudioDeviceID, _ scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0
        else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr
        else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(_ device: AudioDeviceID,
                                       _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
        }
        return status == noErr ? value as String? : nil
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
