import Foundation
import AppKit

/// What to do when a call starts or ends. Stored in UserDefaults, so the
/// settings screen can bind to the same keys with @AppStorage.
enum CallSettings {
    enum OnStart: String, CaseIterable {
        case ask, record, nothing
    }
    enum OnEnd: String, CaseIterable {
        case stop, keep
    }

    static let onStartKey = "callOnStart"
    static let onEndKey = "callOnEnd"
    static let browsersKey = "callIncludeBrowsers"

    /// How long the "Stopping the recording" countdown runs.
    static let stopCountdown: TimeInterval = 10

    static var onStart: OnStart {
        UserDefaults.standard.string(forKey: onStartKey).flatMap(OnStart.init) ?? .ask
    }
    static var onEnd: OnEnd {
        UserDefaults.standard.string(forKey: onEndKey).flatMap(OnEnd.init) ?? .stop
    }
    static var includeBrowsers: Bool {
        UserDefaults.standard.object(forKey: browsersKey) as? Bool ?? true
    }
}

extension AppModel {
    func watchForCalls() {
        callDetector.includeBrowsers = { CallSettings.includeBrowsers }
        callDetector.onChange = { [weak self] app in
            if let app { self?.callStarted(in: app) } else { self?.callEnded() }
        }
        callDetector.start()
    }

    private func callStarted(in app: CallDetector.CallApp) {
        // Already recording, say started by hand before joining: this call
        // is the one being recorded, so its end can stop the recording.
        if isRecording {
            recordingCall = app
            return
        }
        switch CallSettings.onStart {
        case .nothing:
            return
        case .record:
            startCallRecording(app)
            CallOverlay.show(icon: app.icon, title: app.isBrowser ? "Recording the call in \(app.name)" : "Recording your \(app.name) call",
                             message: "Scribe noticed the call and started recording.",
                             actions: [.init(title: "Stop", isPrimary: false) { [weak self] in self?.stop() }],
                             hideAfter: 6)
        case .ask:
            CallOverlay.show(icon: app.icon, title: app.callName,
                             message: "Record it with Scribe?",
                             actions: [
                                .init(title: "Not Now", isPrimary: false) {},
                                .init(title: "Record", isPrimary: true) { [weak self] in
                                    self?.startCallRecording(app)
                                },
                             ])
        }
    }

    private func callEnded() {
        guard isRecording, let app = recordingCall else {
            // The call ended before anyone answered the question.
            CallOverlay.dismiss()
            return
        }
        recordingCall = nil
        guard CallSettings.onEnd == .stop else { return }
        let id = liveID
        CallOverlay.show(icon: app.icon, title: "\(app.callName) ended",
                         message: "Stopping the recording in {s}s",
                         actions: [
                            .init(title: "Keep Recording", isPrimary: false) {},
                            .init(title: "Stop Now", isPrimary: true) { [weak self] in self?.stop() },
                         ],
                         deadline: Date().addingTimeInterval(CallSettings.stopCountdown),
                         onDeadline: { [weak self] in
                            // Only the recording this countdown was about.
                            guard let self, self.liveID == id else { return }
                            self.stop()
                         })
    }

    private func startCallRecording(_ app: CallDetector.CallApp) {
        start(title: "\(app.callName), \(Self.titleDate(Date()))")
        if isRecording { recordingCall = app }
    }
}
