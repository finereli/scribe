import Foundation
import AppKit
import AVFoundation
import Combine
import Speech

/// The languages Scribe offers. One per call; the built-in recognizer can't
/// switch mid-stream.
struct CallLanguage: Identifiable, Hashable {
    let id: String
    let name: String

    static let all = [
        CallLanguage(id: "en-US", name: "English"),
        CallLanguage(id: "he-IL", name: "Hebrew"),
        CallLanguage(id: "ru-RU", name: "Russian"),
    ]

    static func name(for code: String) -> String {
        all.first { $0.id == code }?.name ?? code
    }
}

@MainActor
final class AppModel: ObservableObject {
    let store = SessionStore()
    let devices = AudioDeviceManager()

    @Published var selection: Session.ID?
    @Published var errorMessage: String? {
        didSet { if let errorMessage { Log.write("error: \(errorMessage)") } }
    }
    /// Non-fatal trouble during a call, shown under the transcript.
    @Published var notice: String?

    @Published private(set) var liveID: Session.ID?
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var systemLevel: Float = 0

    @Published var languageCode: String {
        didSet { UserDefaults.standard.set(languageCode, forKey: "languageCode") }
    }

    private var recorder: CallRecorder?
    private var liveStart: Date?
    private var timer: Timer?
    private var activity: NSObjectProtocol?
    private var cancellables = Set<AnyCancellable>()

    init() {
        languageCode = UserDefaults.standard.string(forKey: "languageCode") ?? "en-US"
        selection = store.sessions.first?.id
        SFSpeechRecognizer.requestAuthorization { _ in }
        AVCaptureDevice.requestAccess(for: .audio) { _ in }

        for child in [store.objectWillChange, devices.objectWillChange] {
            child.sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &cancellables)
        }

        // `--autostart <seconds>` records for that long and quits. Used to
        // smoke-test capture and recognition without clicking.
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "--autostart"), i + 1 < args.count,
           let seconds = Double(args[i + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.start() }
            $liveID.compactMap { $0 }.first().sink { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                    self?.stop()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { NSApp.terminate(nil) }
                }
            }.store(in: &cancellables)
        }
    }

    var isRecording: Bool { liveID != nil }

    var selected: Session? { selection.flatMap { store.session($0) } }

    // MARK: - Recording

    func toggleRecording() {
        isRecording ? stop() : start()
    }

    func start() {
        guard !isRecording else { return }
        Log.write("start: mic=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue) speech=\(SFSpeechRecognizer.authorizationStatus().rawValue) device=\(devices.activeDevice?.name ?? "none") follows=\(devices.followsDefault) lang=\(languageCode)")
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .denied, .restricted:
            errorMessage = "Microphone access is off. Turn it on in System Settings ▸ Privacy & Security ▸ Microphone."
            return
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                DispatchQueue.main.async { self?.start() }
            }
            return
        default: break
        }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: break
        case .notDetermined:
            SFSpeechRecognizer.requestAuthorization { [weak self] _ in
                DispatchQueue.main.async { self?.start() }
            }
            return
        default:
            errorMessage = "Speech recognition is off. Turn it on in System Settings ▸ Privacy & Security ▸ Speech Recognition."
            return
        }

        let now = Date()
        let session = Session(id: UUID(), title: Self.defaultTitle(now), createdAt: now,
                              duration: 0, languageCode: languageCode, turns: [])
        store.add(session)

        let recorder = CallRecorder(folder: store.folder(for: session.id),
                                    languageCode: languageCode, start: now)
        // These callbacks all arrive on the main queue.
        recorder.recognition.onUpdate = { [weak self] turn in
            MainActor.assumeIsolated { self?.apply(turn, to: session.id) }
        }
        recorder.recognition.onError = { [weak self] message in
            MainActor.assumeIsolated { self?.notice = message }
        }
        recorder.micStream.onLevel = { [weak self] level in
            MainActor.assumeIsolated { self?.micLevel = level }
        }
        recorder.systemStream.onLevel = { [weak self] level in
            MainActor.assumeIsolated { self?.systemLevel = level }
        }

        self.recorder = recorder
        liveID = session.id
        liveStart = now
        selection = session.id
        notice = nil
        elapsed = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.liveStart else { return }
                self.elapsed = Date().timeIntervalSince(start)
            }
        }
        // Keep App Nap from throttling us while the window is in the background.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: "Recording a call")

        let problems = recorder.start(micDevice: { [weak self] in
            MainActor.assumeIsolated { self?.devices.activeDeviceID ?? 0 }
        })
        if !problems.isEmpty {
            notice = problems.joined(separator: "\n")
            Log.write("start problems: \(problems)")
        }
    }

    func stop() {
        guard let recorder, let id = liveID, let start = liveStart else { return }
        timer?.invalidate()
        timer = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        self.recorder = nil
        liveID = nil
        liveStart = nil
        micLevel = 0
        systemLevel = 0

        let duration = Date().timeIntervalSince(start)
        recorder.stop { [weak self] in
            MainActor.assumeIsolated {
                guard let self, var session = self.store.session(id) else { return }
                session.duration = duration
                session.micOffset = recorder.micStream.startOffset
                session.systemOffset = recorder.systemStream.startOffset
                self.store.update(session)
            }
        }
    }

    /// Upsert a partial or final turn. Finals are saved as they land, so a
    /// crash mid-call loses at most the sentence in progress.
    private func apply(_ turn: Turn, to id: Session.ID) {
        if turn.isFinal { Log.write("turn \(turn.speaker.label) \(Format.duration(turn.start)): \(turn.text)") }
        guard var session = store.session(id) else { return }
        if let idx = session.turns.firstIndex(where: { $0.id == turn.id }) {
            if turn.isFinal && turn.text.isEmpty {
                session.turns.remove(at: idx)
            } else {
                session.turns[idx] = turn
            }
        } else if !turn.text.isEmpty {
            session.turns.append(turn)
        } else {
            return
        }
        store.update(session, persist: turn.isFinal)
    }

    private static func defaultTitle(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d, HH:mm"
        return "Call \(f.string(from: date))"
    }

    // MARK: - Editing

    func rename(_ session: Session, to title: String) {
        guard var s = store.session(session.id), !title.isEmpty else { return }
        s.title = title
        store.update(s)
    }

    func delete(_ session: Session) {
        guard session.id != liveID else { return }
        let list = store.sessions
        let idx = list.firstIndex { $0.id == session.id }
        store.delete(session)
        if selection == session.id {
            let remaining = store.sessions
            selection = idx.flatMap { remaining.indices.contains($0) ? remaining[$0].id : remaining.last?.id }
        }
    }

    func copyTranscript(_ session: Session) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(session.transcriptText, forType: .string)
    }

    func reveal(_ session: Session) {
        NSWorkspace.shared.activateFileViewerSelecting([store.folder(for: session.id)])
    }
}
