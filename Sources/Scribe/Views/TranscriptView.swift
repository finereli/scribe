import SwiftUI

/// The conversation, one paragraph per speaker change. Text still being
/// recognized is dimmed. While live, it follows the newest line.
struct TranscriptView: View {
    let session: Session
    let live: Bool

    var body: some View {
        let groups = TurnGroup.make(from: session.sortedTurns)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if groups.isEmpty {
                        Text(live ? "Listening…" : "Nothing was transcribed.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 40)
                    }
                    ForEach(groups) { group in
                        GroupRow(group: group, label: session.label(for: group.speaker))
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }
            .onChange(of: session.turns) {
                guard live else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onAppear { if live { proxy.scrollTo("bottom", anchor: .bottom) } }
        }
    }
}

private struct GroupRow: View {
    let group: TurnGroup
    let label: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 12, weight: .bold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(group.speaker == .me ? Color.accentColor : Color.orange)
                Text(Format.duration(group.start))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .frame(width: 64, alignment: .leading)

            paragraph
                .font(.system(size: 14))
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
                .environment(\.layoutDirection,
                             TextDirection.isRTL(group.text) ? .rightToLeft : .leftToRight)
        }
    }

    /// Final turns in full color, the turn still forming dimmed.
    private var paragraph: Text {
        group.turns.enumerated().reduce(Text("")) { text, item in
            let (i, turn) = item
            let piece = Text((i > 0 ? " " : "") + turn.text)
                .foregroundColor(turn.isFinal ? .primary : .secondary)
            return text + piece
        }
    }
}
