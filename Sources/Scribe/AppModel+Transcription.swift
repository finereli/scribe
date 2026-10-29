import Foundation

/// What we know about the saved OpenAI key.
enum KeyState: Equatable {
    case missing
    /// Saved, but not confirmed yet (offline at launch, say). Treated as fine.
    case unchecked
    case working
    case rejected(String)
    case noCredit
}

struct TranscribeProgress: Equatable {
    var done = 0
    var total = 0
}

/// What happened when a key was saved, for the Settings window to show.
enum KeySaveResult {
    case saved
    case savedUnchecked(String)
    case savedNoCredit
    case refused(String)
}

extension AppModel {
    /// What the banner should say, if anything.
    var problem: TranscriptionProblem? {
        switch keyState {
        case .missing: return .noKey
        case .rejected(let message): return .rejected(message)
        case .noCredit: return .noCredit
        case .unchecked, .working: return offline ? .offline : nil
        }
    }

    // MARK: - The key

    /// Confirms the saved key still works, so a revoked key or an empty
    /// account shows up before a call rather than during one.
    func checkStoredKey() async {
        guard let key = APIKey.current else { keyState = .missing; return }
        let outcome = await OpenAI.check(key)
        guard APIKey.current == key else { return }   // changed meanwhile
        switch outcome {
        case .text: keyState = .working
        case .rejected(let message): keyState = .rejected(message)
        case .noCredit: keyState = .noCredit
        case .busy, .offline, .failed: keyState = .unchecked
        }
        Log.write("key check: \(keyState)")
    }

    /// Checks a key with OpenAI and saves it unless OpenAI turned it down.
    /// A key that can't be checked right now (offline) is saved anyway.
    func saveKey(_ raw: String) async -> KeySaveResult {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let outcome = await OpenAI.check(key)
        if case .rejected(let message) = outcome { return .refused(message) }
        do {
            try APIKey.save(key)
        } catch {
            return .refused("Couldn't save the key: \(error.localizedDescription)")
        }
        offline = false
        switch outcome {
        case .text:
            keyState = .working
            return .saved
        case .noCredit:
            keyState = .noCredit
            return .savedNoCredit
        case .busy(let reason), .offline(let reason), .failed(let reason):
            keyState = .unchecked
            return .savedUnchecked(reason)
        case .rejected:
            return .saved   // handled above
        }
    }

    func removeKey() {
        APIKey.remove()
        keyState = .missing
    }

    // MARK: - Live status

    /// A recognizer's report: nil when a turn went through.
    func transcriptionStatus(_ problem: TranscriptionProblem?) {
        switch problem {
        case nil:
            offline = false
            keyState = .working
        case .offline:
            offline = true
        case .noKey:
            keyState = .missing
        case .rejected(let message):
            keyState = .rejected(message)
        case .noCredit:
            keyState = .noCredit
        }
    }

    /// A turn that couldn't be transcribed: drop its placeholder and count
    /// it, so the call offers to be transcribed again.
    func markMissing(_ turn: Turn, in id: Session.ID) {
        guard var session = store.session(id) else { return }
        session.turns.removeAll { $0.id == turn.id }
        session.missingTurns = (session.missingTurns ?? 0) + 1
        store.update(session)
    }

    // MARK: - Transcribing a saved call

    func hasRecording(_ session: Session) -> Bool {
        let folder = store.folder(for: session.id)
        return [Session.micFile, Session.systemFile].contains {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
    }

    /// Rough cost of sending a call to OpenAI, in cents: both sides together
    /// hold about as much speech as the call is long.
    func transcribeCost(_ session: Session) -> Int {
        max(1, Int((session.duration / 60 * 0.45).rounded()))
    }

    func transcribe(_ session: Session) {
        guard session.id != liveID, transcribing[session.id] == nil else { return }
        guard problem != .noKey else {
            showToast("Add an OpenAI key in Settings first")
            return
        }
        let id = session.id
        let job = Retranscriber(folder: store.folder(for: id), session: session)
        retranscribers[id] = job
        transcribing[id] = TranscribeProgress()
        Log.write("transcribe: \(session.title)")

        job.recognition.onProgress = { [weak self] done, total in
            MainActor.assumeIsolated {
                guard self?.transcribing[id] != nil else { return }
                self?.transcribing[id] = TranscribeProgress(done: done, total: total)
            }
        }
        job.onStatus = { [weak self] problem in
            MainActor.assumeIsolated { self?.transcriptionStatus(problem) }
        }
        job.run { [weak self] result in
            MainActor.assumeIsolated { self?.finishTranscribing(id, result) }
        }
    }

    func cancelTranscribing(_ session: Session) {
        retranscribers.removeValue(forKey: session.id)?.cancel()
        transcribing[session.id] = nil
    }

    private func finishTranscribing(_ id: Session.ID, _ result: Retranscriber.Result) {
        // Gone means cancelled or deleted.
        guard retranscribers.removeValue(forKey: id) != nil else { return }
        transcribing[id] = nil
        if !isRecording { offline = false }
        guard var session = store.session(id) else { return }
        Log.write("transcribe done: \(result.turns.count) turns, \(result.missing) missing, problem \(String(describing: result.problem))")

        if result.unreadable {
            errorMessage = "This call's recording can't be read, so it can't be transcribed. This happens when Scribe was quit or crashed during the call."
            return
        }
        if result.problem != nil {
            showToast("Stopped. Check your OpenAI key in Settings", seconds: 3)
            return
        }
        if result.turns.isEmpty && result.missing == 0 {
            showToast("No speech found in this recording", seconds: 2.5)
            return
        }
        // Don't trade a complete transcript for a patchier one.
        let hadText = session.turns.contains { !$0.text.isEmpty }
        let oldMissing = session.missingTurns ?? 0
        guard result.missing == 0 || !hadText || result.missing < oldMissing else {
            errorMessage = "\(result.missing) parts couldn't be transcribed, so the old transcript was kept. Try again when you're online."
            return
        }
        session.turns = result.turns
        session.missingTurns = result.missing > 0 ? result.missing : nil
        store.update(session)
        showToast(result.missing > 0 ? "Transcribed, \(result.missing) parts missing" : "Transcribed")
    }
}
