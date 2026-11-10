import Foundation
import AppKit
import CoreAudio

/// Notices calls by watching which apps have the microphone open. Core Audio
/// lists every process that uses audio (macOS 14.2+), with its bundle ID and
/// whether it's recording right now, and reading that needs no permission.
///
/// A call starts when a known call app has held the mic for a few seconds,
/// which filters out quick blips like a device check. It ends when no call
/// app has had the mic for a few seconds, which rides out the brief release
/// some apps do when you switch headsets. Scribe's own mic use doesn't count.
@MainActor
final class CallDetector {
    struct CallApp: Equatable {
        /// What we call it in the overlay: "Zoom", "Brave".
        let name: String
        /// The app to take the icon from. For a helper process or a system
        /// daemon this is the app people know, not the process itself.
        let bundleID: String
        let isBrowser: Bool

        /// "Zoom call", or "Call in Brave", since a browser could be Meet or
        /// anything else.
        var callName: String { isBrowser ? "Call in \(name)" : "\(name) call" }

        @MainActor var icon: NSImage {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                return NSWorkspace.shared.icon(forFile: url.path)
            }
            return NSApp.applicationIconImage
        }
    }

    /// Called when the call app holding the mic changes: an app when a call
    /// starts, nil when it ends.
    var onChange: ((CallApp?) -> Void)?
    /// Read on every check, so the setting applies straight away.
    var includeBrowsers: () -> Bool = { true }

    private(set) var current: CallApp?
    private var candidate: CallApp?
    private var candidateSince = Date()
    private var lastSeen = Date()
    private var timer: Timer?

    private let startDelay: TimeInterval = 3
    private let endDelay: TimeInterval = 5

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        check()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func check() {
        let using = Self.callAppsUsingMic(includeBrowsers: includeBrowsers())
        let now = Date()

        // During a call only that app matters. Another app with the mic, say
        // a browser tab that keeps it open, doesn't take the call over.
        if let current {
            if using.contains(current) {
                lastSeen = now
            } else if now.timeIntervalSince(lastSeen) >= endDelay {
                Log.write("call: \(current.name) let go of the mic")
                self.current = nil
                onChange?(nil)
            }
            return
        }

        // A real call app beats a browser when both have the mic.
        guard let found = using.first(where: { !$0.isBrowser }) ?? using.first else {
            candidate = nil
            return
        }
        if candidate != found {
            candidate = found
            candidateSince = now
        } else if now.timeIntervalSince(candidateSince) >= startDelay {
            Log.write("call: \(found.name) has the mic")
            current = found
            lastSeen = now
            candidate = nil
            onChange?(found)
        }
    }

    // MARK: - Core Audio

    /// The call apps recording from the mic right now.
    private static func callAppsUsingMic(includeBrowsers: Bool) -> [CallApp] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var apps: [CallApp] = []
        for process in processObjects() where isRunningInput(process) {
            guard pid(of: process) != ownPID,
                  let bundle = bundleID(of: process),
                  let app = callApp(for: bundle),
                  includeBrowsers || !app.isBrowser,
                  !apps.contains(app) else { continue }
            apps.append(app)
        }
        return apps
    }

    private static func callApp(for bundle: String) -> CallApp? {
        for entry in known where bundle == entry.prefix || bundle.hasPrefix(entry.prefix + ".") {
            return CallApp(name: entry.name, bundleID: entry.app ?? entry.prefix, isBrowser: entry.browser)
        }
        return nil
    }

    /// Bundle ID prefixes, so helper processes ("com.google.Chrome.helper")
    /// and web apps ("com.brave.Browser.app.…") count as their browser.
    private static let known: [(prefix: String, name: String, app: String?, browser: Bool)] = [
        ("us.zoom.xos", "Zoom", nil, false),
        ("com.microsoft.teams2", "Teams", nil, false),
        ("com.microsoft.teams", "Teams", nil, false),
        ("net.whatsapp.WhatsApp", "WhatsApp", nil, false),
        ("desktop.WhatsApp", "WhatsApp", nil, false),
        ("com.apple.FaceTime", "FaceTime", nil, false),
        // FaceTime and iPhone calls on the Mac run their audio here.
        ("com.apple.avconferenced", "FaceTime", "com.apple.FaceTime", false),
        ("com.tinyspeck.slackmacgap", "Slack", nil, false),
        ("com.hnc.Discord", "Discord", nil, false),
        ("com.cisco.webexmeetingsapp", "Webex", nil, false),
        ("Cisco-Systems.Spark", "Webex", nil, false),
        ("com.skype.skype", "Skype", nil, false),
        ("ru.keepcoder.Telegram", "Telegram", nil, false),
        ("org.telegram.desktop", "Telegram", nil, false),
        ("org.whispersystems.signal-desktop", "Signal", nil, false),
        ("com.google.Chrome", "Chrome", nil, true),
        ("com.brave.Browser", "Brave", nil, true),
        ("company.thebrowser.Browser", "Arc", nil, true),
        ("com.microsoft.edgemac", "Edge", nil, true),
        ("org.mozilla.firefox", "Firefox", nil, true),
        ("com.vivaldi.Vivaldi", "Vivaldi", nil, true),
        ("com.operasoftware.Opera", "Opera", nil, true),
        ("com.apple.Safari", "Safari", nil, true),
        // Safari's mic capture runs in WebKit's GPU process.
        ("com.apple.WebKit.GPU", "Safari", "com.apple.Safari", true),
    ]

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func processObjects() -> [AudioObjectID] {
        var address = address(kAudioHardwarePropertyProcessObjectList)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func isRunningInput(_ process: AudioObjectID) -> Bool {
        var address = address(kAudioProcessPropertyIsRunningInput)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(process, &address, 0, nil, &size, &running) == noErr && running != 0
    }

    private static func pid(of process: AudioObjectID) -> pid_t {
        var address = address(kAudioProcessPropertyPID)
        var pid: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        AudioObjectGetPropertyData(process, &address, 0, nil, &size, &pid)
        return pid
    }

    private static func bundleID(of process: AudioObjectID) -> String? {
        var address = address(kAudioProcessPropertyBundleID)
        var ref: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &ref) == noErr,
              let value = ref?.takeRetainedValue() as String?, !value.isEmpty else { return nil }
        return value
    }
}
