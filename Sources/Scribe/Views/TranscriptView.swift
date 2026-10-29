import SwiftUI

/// The conversation, one paragraph per speaker change. Text still being
/// recognized is dimmed. While live, it follows the newest line.
struct TranscriptView: View {
    let session: Session
    let live: Bool
    var transcribing = false

    var body: some View {
        let groups = TurnGroup.make(from: session.sortedTurns)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if groups.isEmpty {
                        Text(live ? "Listening…" : transcribing ? "" : "Nothing was transcribed.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 40)
                    }
                    ForEach(groups) { group in
                        GroupRow(group: group)
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

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(group.speaker.label)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(group.speaker == .me ? Color.accentColor : Color.orange)
                Text(Format.duration(group.start))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .frame(width: 44, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
                    text(of: run)
                        .font(.system(size: 14))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .multilineTextAlignment(.leading)
                        .environment(\.layoutDirection, run.rtl ? .rightToLeft : .leftToRight)
                }
            }
        }
    }

    /// Sentences in a row that read the same way. A speaker who moves
    /// between Hebrew and English gets a new block at each switch, so each
    /// reads in its own direction with its punctuation on the right side.
    private struct Run {
        var rtl: Bool
        var pieces: [(text: String, isFinal: Bool)] = []
    }

    private var runs: [Run] {
        var runs: [Run] = []
        for turn in group.turns {
            for sentence in TextDirection.sentences(turn.text) {
                let rtl = TextDirection.direction(sentence) ?? runs.last?.rtl
                    ?? TextDirection.isRTL(group.text)
                if runs.last?.rtl != rtl { runs.append(Run(rtl: rtl)) }
                runs[runs.count - 1].pieces.append((sentence, turn.isFinal))
            }
        }
        return runs
    }

    /// Final turns in full color, the turn still forming dimmed.
    private func text(of run: Run) -> Text {
        run.pieces.enumerated().reduce(Text("")) { text, item in
            let (i, piece) = item
            return text + Text((i > 0 ? " " : "") + piece.text)
                .foregroundColor(piece.isFinal ? .primary : .secondary)
        }
    }
}
