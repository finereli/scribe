import SwiftUI

/// Across the top of the window when transcription can't happen, saying
/// why and what to do. Recording carries on regardless.
struct StatusBanner: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openSettings) private var openSettings
    let problem: TranscriptionProblem

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            switch problem {
            case .offline:
                EmptyView()
            case .noCredit:
                Link("Add Credit", destination: OpenAI.billingURL)
                settingsButton("Settings…")
            case .noKey:
                settingsButton("Add Key…")
            case .rejected:
                settingsButton("Fix Key…")
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12))
    }

    private func settingsButton(_ title: String) -> some View {
        Button(title) {
            openSettings()
            NSApp.activate(ignoringOtherApps: true)
        }
        .controlSize(.small)
    }

    private var recordingNote: String {
        model.isRecording ? " The call is still being recorded; you can transcribe it afterwards." : ""
    }

    private var title: String {
        switch problem {
        case .noKey: return "Add your OpenAI key to transcribe calls"
        case .rejected: return "OpenAI rejected your API key"
        case .noCredit: return "Your OpenAI account is out of credit"
        case .offline: return "Can't reach OpenAI"
        }
    }

    private var detail: String {
        switch problem {
        case .noKey:
            return "Scribe uses your own OpenAI account to write down what's said." + recordingNote
        case .rejected(let message):
            return message + recordingNote
        case .noCredit:
            return "Add credit to your OpenAI account to keep transcribing." + recordingNote
        case .offline:
            return "Transcription will catch up when the connection is back."
        }
    }

    private var icon: String {
        switch problem {
        case .noKey: return "key.fill"
        case .rejected: return "xmark.octagon.fill"
        case .noCredit: return "creditcard.trianglebadge.exclamationmark"
        case .offline: return "wifi.exclamationmark"
        }
    }

    private var tint: Color {
        switch problem {
        case .noKey, .offline: return .yellow
        case .rejected: return .red
        case .noCredit: return .orange
        }
    }
}
