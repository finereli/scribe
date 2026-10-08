import Foundation

/// Calls live in ~/Library/Application Support/Scribe/<id>/, each folder
/// holding mic.m4a, system.m4a and session.json.
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [Session] = []

    let directory: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        directory = base.appendingPathComponent("Scribe", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        load()
    }

    func folder(for id: Session.ID) -> URL {
        directory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func session(_ id: Session.ID) -> Session? {
        sessions.first { $0.id == id }
    }

    func add(_ session: Session) {
        try? FileManager.default.createDirectory(at: folder(for: session.id),
                                                 withIntermediateDirectories: true)
        sessions.insert(session, at: 0)
        save(session)
    }

    func update(_ session: Session, persist: Bool = true) {
        guard let idx = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        sessions[idx] = session
        if persist { save(session) }
    }

    func delete(_ session: Session) {
        try? FileManager.default.removeItem(at: folder(for: session.id))
        sessions.removeAll { $0.id == session.id }
    }

    // MARK: - Persistence

    func save(_ session: Session) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(session)
            try data.write(to: folder(for: session.id).appendingPathComponent("session.json"),
                           options: .atomic)
        } catch {
            NSLog("Scribe: failed to save session: \(error)")
        }
    }

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        sessions = folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("session.json"))
            else { return nil }
            return try? decoder.decode(Session.self, from: data)
        }
        .sorted { $0.createdAt > $1.createdAt }
    }
}
