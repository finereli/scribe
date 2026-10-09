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
/// Which microphone counts as "me".
enum MicMode: String {
    /// Whatever input the call app (Meet in a browser, Zoom...) has open.
    case call
    /// The macOS default input.
    case system
    /// One specific device.
    case fixed
}

final class AudioDeviceManager: ObservableObject {
    @Published private(set) var devices: [AudioInputDevice] = []
    @Published private(set) var mode: MicMode = .call
    @Published private(set) var selectedDeviceID: AudioDeviceID = 0
    @Published private(set) var defaultInputID: AudioDeviceID = 0
    /// The input another app is using, sticky: kept when that app lets go
    /// of the mic (Meet on mute), so the recording doesn't hop devices.
    @Published private(set) var callDeviceID: AudioDeviceID = 0

    private var listenerInstalled = false
    private var poll: Timer?

    init() {
        refresh()
        if let uid = UserDefaults.standard.string(forKey: "micUID"),
           let saved = devices.first(where: { $0.uid == uid }) {
            mode = .fixed
            selectedDeviceID = saved.id
        } else if UserDefaults.standard.string(forKey: "micMode") == MicMode.system.rawValue {
            mode = .system
        }
        installListener()
        updateCallDevice()
        // Apps opening a mic don't notify anyone, so look every two seconds.
        poll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.updateCallDevice()
        }
    }

    /// The device a recording should use right now.
    var activeDeviceID: AudioDeviceID {
        let fallback = defaultInputID != 0 ? defaultInputID : (devices.first?.id ?? 0)
        switch mode {
        case .fixed where devices.contains { $0.id == selectedDeviceID }:
            return selectedDeviceID
        case .call where devices.contains { $0.id == callDeviceID }:
            return callDeviceID
        default:
            return fallback
        }
    }

    var activeDevice: AudioInputDevice? {
        devices.first { $0.id == activeDeviceID }
    }

    func name(of id: AudioDeviceID) -> String? {
        devices.first { $0.id == id }?.name
    }

    func choose(_ device: AudioInputDevice) {
        mode = .fixed
        selectedDeviceID = device.id
        UserDefaults.standard.set(device.uid, forKey: "micUID")
    }

    func use(_ newMode: MicMode) {
        mode = newMode
        UserDefaults.standard.removeObject(forKey: "micUID")
        UserDefaults.standard.set(newMode.rawValue, forKey: "micMode")
    }

    /// Re-scan the hardware for available input devices.
    func refresh() {
        let updated = Self.inputDevices()
        if updated != devices {
            devices = updated
        }
        let def = Self.defaultInputDeviceID() ?? 0
        if def != defaultInputID { defaultInputID = def }
        // A remembered device that comes back (re-plugged) is picked up again.
        if mode == .fixed, let uid = UserDefaults.standard.string(forKey: "micUID"),
           let saved = devices.first(where: { $0.uid == uid }) {
            selectedDeviceID = saved.id
        }
    }

    // MARK: - Which mic is the call using?

    private func updateCallDevice() {
        let inUse = Self.inputsUsedByOtherApps().filter { id in devices.contains { $0.id == id } }
        guard !inUse.isEmpty else { return }
        // A browser can hold the default input open as well as the mic picked
        // in the call, so an explicit non-default pick wins.
        let pick = inUse.first { $0 != defaultInputID } ?? inUse[0]
        if pick != callDeviceID {
            Log.write("call app inputs: \(inUse.compactMap(name(of:))), using \(name(of: pick) ?? "?")")
            callDeviceID = pick
        }
    }

    /// Input devices that some other process is recording from right now.
    private static func inputsUsedByOtherApps() -> [AudioDeviceID] {
        let me = getpid()
        var result: [AudioDeviceID] = []
        for process in objectList(AudioObjectID(kAudioObjectSystemObject),
                                  kAudioHardwarePropertyProcessObjectList,
                                  kAudioObjectPropertyScopeGlobal) {
            var pid: pid_t = 0
            var running: UInt32 = 0
            guard read(process, kAudioProcessPropertyPID, &pid), pid != me,
                  read(process, kAudioProcessPropertyIsRunningInput, &running), running != 0
            else { continue }
            for device in objectList(process, kAudioProcessPropertyDevices, kAudioObjectPropertyScopeInput)
            where !result.contains(device) {
                result.append(device)
            }
        }
        return result
    }

    private static func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                _ value: inout T) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0) == noErr
        }
    }

    private static func objectList(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                   _ scope: AudioObjectPropertyScope) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0
        else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids
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
        var defaultAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &defaultAddress, DispatchQueue.main
        ) { [weak self] _, _ in
            self?.refresh()
        }
        listenerInstalled = (status == noErr)
    }
}
