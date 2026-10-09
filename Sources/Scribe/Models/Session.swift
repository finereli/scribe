import Foundation

/// Who said it. The mic is always me; whatever the Mac plays is them.
enum Speaker: String, Codable, Hashable {
    case me, them

    var label: String { self == .me ? "Me" : "Them" }
}

/// One stretch of speech from one speaker, roughly a sentence or a breath
/// group. Times are seconds since the call started.
struct Turn: Identifiable, Codable, Hashable {
    var id: UUID
    var speaker: Speaker
    var start: TimeInterval
    var end: TimeInterval
    var text: String
    var isFinal: Bool
}

/// A recorded call: two audio tracks plus the live transcript.
struct Session: Identifiable, Codable, Hashable {
    var id: UUID
    var title: String
    var createdAt: Date
    var duration: TimeInterval
    var languageCode: String
    var turns: [Turn]
    /// Where each track's first sample sits on the call timeline, so the two
    /// files can be lined up again when re-transcribing.
    var micOffset: TimeInterval?
    var systemOffset: TimeInterval?

    static let micFile = "mic.m4a"
    static let systemFile = "system.m4a"

    var sortedTurns: [Turn] { turns.sorted { $0.start < $1.start } }

    /// Plain-text transcript, one line per speaker change.
    var transcriptText: String {
        TurnGroup.make(from: sortedTurns.filter { $0.isFinal })
            .map { "[\(Format.duration($0.start))] \($0.speaker.label): \($0.text)" }
            .joined(separator: "\n\n")
    }
}

/// Consecutive turns by the same speaker, shown as one paragraph.
struct TurnGroup: Identifiable {
    let id: UUID
    let speaker: Speaker
    let start: TimeInterval
    var turns: [Turn]

    var text: String { turns.map(\.text).joined(separator: " ") }

    static func make(from sorted: [Turn]) -> [TurnGroup] {
        var groups: [TurnGroup] = []
        for turn in sorted where !turn.text.isEmpty {
            if var last = groups.last, last.speaker == turn.speaker {
                last.turns.append(turn)
                groups[groups.count - 1] = last
            } else {
                groups.append(TurnGroup(id: turn.id, speaker: turn.speaker,
                                        start: turn.start, turns: [turn]))
            }
        }
        return groups
    }
}
