import AppKit

/// The AI chat apps a transcript can be handed to. Scribe doesn't talk to
/// them: it copies the transcript with a line of context and opens the app
/// (or its website), and you paste.
enum Assistant: CaseIterable {
    case claude, chatgpt

    var name: String { self == .claude ? "Claude" : "ChatGPT" }

    private var bundleID: String {
        self == .claude ? "com.anthropic.claudefordesktop" : "com.openai.chat"
    }

    private var webURL: URL {
        URL(string: self == .claude ? "https://claude.ai/new" : "https://chatgpt.com/")!
    }

    /// The brand mark, from the app bundle. ChatGPT's is black, so it's a
    /// template image that follows light and dark mode; Claude's keeps its
    /// orange.
    var logo: NSImage? {
        guard let url = Bundle.main.url(forResource: self == .claude ? "claude" : "chatgpt",
                                        withExtension: "pdf"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = self == .chatgpt
        return image
    }

    /// Open the desktop app if it's installed, else the website.
    func open() {
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(webURL)
        }
    }
}
