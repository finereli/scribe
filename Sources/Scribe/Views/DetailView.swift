import SwiftUI

/// Right pane: the selected call's transcript, live while it's recording.
struct DetailView: View {
    @EnvironmentObject var model: AppModel
    @State private var editingTitle = false
    @State private var titleDraft = ""
    @FocusState private var titleFocused: Bool
    @State private var confirmTranscribe: Session?

    var body: some View {
        VStack(spacing: 0) {
            if let problem = model.problem {
                StatusBanner(problem: problem)
                Divider()
            }
            content
        }
        .confirmationDialog("Transcribe this call again?",
                            isPresented: Binding(get: { confirmTranscribe != nil },
                                                 set: { if !$0 { confirmTranscribe = nil } }),
                            presenting: confirmTranscribe) { session in
            Button("Transcribe") { model.transcribe(session) }
        } message: { session in
            Text("Scribe will send the recording to OpenAI and replace the current transcript. A call this long costs about \(model.transcribeCost(session))¢.")
        }
    }

    private var content: some View {
        Group {
            if let session = model.selected {
                VStack(spacing: 0) {
                    header(session)
                    Divider()
                    transcribeBar(session)
                    TranscriptView(session: session, live: session.id == model.liveID,
                                   transcribing: model.transcribing[session.id] != nil)
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
                    ForEach(Assistant.allCases, id: \.self) { assistant in
                        Button { model.send(session, to: assistant) } label: {
                            AssistantLabel(assistant: assistant)
                        }
                        .help("Copy the transcript and open \(assistant.name)")
                    }
                }
                ToolbarItemGroup {
                    Button { requestTranscribe(session) } label: {
                        Image(systemName: "text.badge.checkmark")
                    }
                    .help("Transcribe this call again")
                    .disabled(session.id == model.liveID || model.transcribing[session.id] != nil
                              || !model.hasRecording(session))

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
                TextField("Title", text: $titleDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 17, weight: .semibold))
                    .frame(maxWidth: 360)
                    .focused($titleFocused)
                    .onSubmit { commitTitle(session) }
                    .onExitCommand { editingTitle = false }
                    // Clicking elsewhere saves, like Finder.
                    .onChange(of: titleFocused) {
                        if !titleFocused && editingTitle { commitTitle(session) }
                    }
                    .onAppear {
                        // Focus once the field exists, then select the old
                        // title so typing replaces it.
                        DispatchQueue.main.async {
                            titleFocused = true
                            DispatchQueue.main.async {
                                NSApp.sendAction(#selector(NSResponder.selectAll(_:)), to: nil, from: nil)
                            }
                        }
                    }
                Button("Save") { commitTitle(session) }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.small)
                Button("Cancel") { editingTitle = false }
                    .controlSize(.small)
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
                Text(Format.duration(session.duration))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    private func commitTitle(_ session: Session) {
        model.rename(session, to: titleDraft.trimmingCharacters(in: .whitespaces))
        editingTitle = false
    }

    private func requestTranscribe(_ session: Session) {
        if session.turns.contains(where: { !$0.text.isEmpty }) {
            confirmTranscribe = session
        } else {
            model.transcribe(session)
        }
    }

    /// Progress while a saved call is being transcribed, or an offer to
    /// transcribe one that's missing text.
    @ViewBuilder
    private func transcribeBar(_ session: Session) -> some View {
        if let progress = model.transcribing[session.id] {
            HStack(spacing: 10) {
                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                    .frame(maxWidth: 220)
                Text(progress.total == 0 ? "Transcribing…" : "Transcribing… \(progress.done) of \(progress.total)")
                    .font(.system(size: 12))
                    .monospacedDigit()
                Spacer()
                Button("Cancel") { model.cancelTranscribing(session) }
                    .controlSize(.small)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.04))
            Divider()
        } else if session.id != model.liveID, model.hasRecording(session),
                  let text = missingText(session) {
            HStack(spacing: 10) {
                Image(systemName: "text.badge.xmark").foregroundStyle(.secondary)
                Text(text).font(.system(size: 12))
                Spacer()
                Button("Transcribe") { model.transcribe(session) }
                    .controlSize(.small)
                    .disabled(model.problem == .noKey)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
            .background(Color.yellow.opacity(0.10))
            Divider()
        }
    }

    private func missingText(_ session: Session) -> String? {
        let hasText = session.turns.contains { !$0.text.isEmpty }
        let missing = session.missingTurns ?? 0
        if !hasText && session.duration > 0 { return "This call hasn't been transcribed." }
        if missing == 1 { return "One part of this call wasn't transcribed." }
        if missing > 1 { return "\(missing) parts of this call weren't transcribed." }
        return nil
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

/// The assistant's brand mark, or its name if the mark is missing.
private struct AssistantLabel: View {
    let assistant: Assistant

    var body: some View {
        Group {
            if let logo = assistant.logo {
                Image(nsImage: logo)
                    .resizable()
                    .renderingMode(logo.isTemplate ? .template : .original)
                    .frame(width: 16, height: 16)
            } else {
                Text(assistant.name).font(.system(size: 12, weight: .medium))
            }
        }
    }
}
