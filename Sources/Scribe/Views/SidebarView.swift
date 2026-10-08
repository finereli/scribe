import SwiftUI

/// Left column: past calls, then the record button, language, microphone
/// and the two level meters.
struct SidebarView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $model.selection) {
                Section("Calls") {
                    ForEach(model.store.sessions) { session in
                        SessionRow(session: session, live: session.id == model.liveID)
                            .tag(session.id)
                            .contextMenu {
                                Button("Copy Transcript") { model.copyTranscript(session) }
                                Button("Reveal in Finder") { model.reveal(session) }
                                Divider()
                                Button("Delete", role: .destructive) { model.delete(session) }
                                    .disabled(session.id == model.liveID)
                            }
                    }
                }
            }

            Divider()

            VStack(spacing: 12) {
                RecordButton()
                CallControls()
            }
            .padding(.vertical, 14)
        }
    }
}

struct SessionRow: View {
    @EnvironmentObject var model: AppModel
    let session: Session
    let live: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if live {
                    Circle().fill(.red).frame(width: 7, height: 7)
                }
                Text(session.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
            }
            HStack(spacing: 6) {
                Text(Format.time(session.createdAt))
                Text(CallLanguage.name(for: session.languageCode))
                Spacer()
                Text(Format.duration(live ? model.elapsed : session.duration))
                    .monospacedDigit()
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}

/// The red circular record / stop button, Voice-Memos style.
struct RecordButton: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Button {
            model.toggleRecording()
        } label: {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.5), lineWidth: 3)
                if model.isRecording {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.red)
                        .frame(width: 24, height: 24)
                } else {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 46, height: 46)
                }
            }
            .frame(width: 58, height: 58)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(model.isRecording ? "Stop recording (⌘R)" : "Start recording (⌘R)")
    }
}
