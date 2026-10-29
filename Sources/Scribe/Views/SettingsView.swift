import SwiftUI

/// Scribe ▸ Settings (⌘,). For now, just the OpenAI key.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var draft = ""
    @State private var saving = false
    @State private var message: (text: String, isError: Bool)?
    @State private var confirmRemove = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Status") { status }
                SecureField(APIKey.current == nil ? "API key" : "Replace key", text: $draft,
                            prompt: Text("sk-…"))
                    .onSubmit(save)
                    .disabled(saving)
                if let message {
                    Text(message.text)
                        .font(.callout)
                        .foregroundStyle(message.isError ? .red : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    if APIKey.current != nil {
                        Button("Remove Key…", role: .destructive) { confirmRemove = true }
                            .disabled(saving)
                    }
                    Spacer()
                    if saving { ProgressView().controlSize(.small) }
                    Button("Save", action: save)
                        .keyboardShortcut(.defaultAction)
                        .disabled(trimmed.isEmpty || saving)
                }
            } header: {
                Text("OpenAI")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Scribe records calls on your Mac and sends each stretch of speech to OpenAI to be written down, using your own OpenAI account. A one-hour call costs about 30 cents. The key stays on this Mac.")
                        .foregroundStyle(.secondary)
                    Link("Get a key at platform.openai.com", destination: OpenAI.keysURL)
                        .pointingHandCursor()
                }
                .font(.callout)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
        .confirmationDialog("Remove the OpenAI key?", isPresented: $confirmRemove) {
            Button("Remove Key", role: .destructive) {
                model.removeKey()
                message = nil
            }
        } message: {
            Text("Calls will still be recorded, but not transcribed until you add a key again.")
        }
    }

    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    @ViewBuilder private var status: some View {
        let masked = APIKey.current.map(APIKey.masked) ?? ""
        switch model.keyState {
        case .missing:
            Label("Not set", systemImage: "key.slash").foregroundStyle(.secondary)
        case .unchecked:
            Label("\(masked), not checked yet", systemImage: "questionmark.circle").foregroundStyle(.secondary)
        case .working:
            Label("\(masked), working", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .rejected:
            Label("\(masked), rejected by OpenAI", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
        case .noCredit:
            HStack(spacing: 8) {
                Label("\(masked), out of credit", systemImage: "creditcard.trianglebadge.exclamationmark")
                    .foregroundStyle(.orange)
                Link("Add credit", destination: OpenAI.billingURL)
            }
        }
    }

    private func save() {
        let key = trimmed
        guard !key.isEmpty, !saving else { return }
        guard key.hasPrefix("sk-") else {
            message = ("That doesn't look like an OpenAI key. They start with “sk-”.", true)
            return
        }
        saving = true
        message = nil
        Task {
            let result = await model.saveKey(key)
            saving = false
            switch result {
            case .saved:
                draft = ""
                message = ("Saved. Scribe is ready to transcribe.", false)
            case .savedNoCredit:
                draft = ""
                message = ("Saved, but the account has no credit. Add some, and transcription starts working.", true)
            case .savedUnchecked:
                draft = ""
                message = ("Saved, but Scribe couldn't reach OpenAI to check it. It'll be used on the next call.", false)
            case .refused(let reason):
                message = (reason, true)
            }
        }
    }
}
