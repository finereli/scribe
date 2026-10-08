import Foundation
import CoreAudio

/// A selectable audio input device.
struct AudioInputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
    let uid: String
}

/// Enumerates and tracks Core Audio input devices, and exposes the user's
/// current selection. Device selection is a first-class feature of the app,
/// so this is a top-level observable object shared across the UI.
final class AudioDeviceManager: ObservableObject {
    @Published private(set) var devices: [AudioInputDevice] = []
    @Published var selectedDeviceID: AudioDeviceID = 0

    private var listenerInstalled = false

    init() {
        refresh()
        // Default to the system's current default input device.
        if let def = Self.defaultInputDeviceID(), devices.contains(where: { $0.id == def }) {
            selectedDeviceID = def
        } else {
            selectedDeviceID = devices.first?.id ?? 0
        }
        installListener()
    }

    var selectedDevice: AudioInputDevice? {
        devices.first { $0.id == selectedDeviceID }
    }

    /// Re-scan the hardware for available input devices.
    func refresh() {
        let updated = Self.inputDevices()
        // Only publish when something actually changed to avoid UI churn.
        if updated != devices {
            devices = updated
        }
        // If the selected device disappeared (e.g. unplugged), fall back.
        if !devices.contains(where: { $0.id == selectedDeviceID }) {
            if let def = Self.defaultInputDeviceID(), devices.contains(where: { $0.id == def }) {
                selectedDeviceID = def
            } else {
                selectedDeviceID = devices.first?.id ?? 0
            }
        }
    }

    // MARK: - Core Audio queries

    private static func inputDevices() -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize)
        guard status == noErr else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &ids)
        guard status == noErr else { return [] }

        return ids.compactMap { id in
            guard inputChannelCount(id) > 0 else { return nil }
            let name = stringProperty(id, kAudioObjectPropertyName) ?? "Unknown Device"
            let uid = stringProperty(id, kAudioDevicePropertyDeviceUID) ?? ""
            return AudioInputDevice(id: id, name: name, uid: uid)
        }
    }

    private static func inputChannelCount(_ device: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0
        else { return 0 }

        let bufferList = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { bufferList.deallocate() }

        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, bufferList) == noErr
        else { return 0 }

        let abl = UnsafeMutableAudioBufferListPointer(
            bufferList.assumingMemoryBound(to: AudioBufferList.self))
        return abl.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(
        _ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        var size = UInt32(MemoryLayout<CFString?>.size)
        var cfStr: CFString? = nil
        let status = withUnsafeMutablePointer(to: &cfStr) { ptr -> OSStatus in
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, ptr)
        }
        guard status == noErr else { return nil }
        return cfStr as String?
    }

    static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    // MARK: - Hot-plug notifications

    private func installListener() {
        guard !listenerInstalled else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main
        ) { [weak self] _, _ in
            self?.refresh()
        }
        listenerInstalled = (status == noErr)
    }
}
