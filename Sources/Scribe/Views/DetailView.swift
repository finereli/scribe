import SwiftUI

/// Right pane: the selected call's transcript, live while it's recording.
struct DetailView: View {
    @EnvironmentObject var model: AppModel
    @State private var editingTitle = false
    @State private var titleDraft = ""

    var body: some View {
        Group {
            if let session = model.selected {
                VStack(spacing: 0) {
                    header(session)
                    Divider()
                    TranscriptView(session: session, live: session.id == model.liveID)
                    if let notice = model.notice, session.id == model.liveID {
                        noticeBar(notice)
                    }
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "waveform")
                        .font(.system(size: 44))
                        .foregroundStyle(.secondary)
                    Text("Press the red button when the call starts")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar {
            if let session = model.selected {
                ToolbarItemGroup {
                    Button { model.copyTranscript(session) } label: {
                        Image(systemName: "doc.on.doc")
                    }.help("Copy transcript")

                    Button { model.reveal(session) } label: {
                        Image(systemName: "folder")
                    }.help("Reveal recordings in Finder")

                    Button(role: .destructive) { model.delete(session) } label: {
                        Image(systemName: "trash")
                    }
                    .help("Delete")
                    .disabled(session.id == model.liveID)
                }
            }
        }
        .onChange(of: model.selection) { editingTitle = false }
    }

    private func header(_ session: Session) -> some View {
        HStack(spacing: 10) {
            if editingTitle {
                TextField("Title", text: $titleDraft, onCommit: {
                    model.rename(session, to: titleDraft)
                    editingTitle = false
                })
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 17, weight: .semibold))
                .frame(maxWidth: 360)
            } else {
                Text(session.title)
                    .font(.system(size: 17, weight: .semibold))
                    .iBeamCursor()
                    .onTapGesture {
                        titleDraft = session.title
                        editingTitle = true
                    }
                    .help("Click to rename")
            }
            Spacer()
            if session.id == model.liveID {
                HStack(spacing: 6) {
                    Circle().fill(.red).frame(width: 8, height: 8)
                    Text(Format.duration(model.elapsed)).monospacedDigit()
                }
                .font(.system(size: 13, weight: .medium))
            } else {
                Text("\(CallLanguage.name(for: session.languageCode)) · \(Format.duration(session.duration))")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    private func noticeBar(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text(text).font(.system(size: 12)).textSelection(.enabled)
            Spacer()
            Button { model.notice = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
        .background(Color.yellow.opacity(0.12))
    }
}
