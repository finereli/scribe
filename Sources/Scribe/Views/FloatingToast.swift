import AppKit
import SwiftUI

/// A short message that floats above every app, like the system volume HUD.
/// Used after handing a transcript to Claude or ChatGPT: by the time it
/// shows, that app is in front and Scribe's own window is hidden behind it.
@MainActor
enum FloatingToast {
    private static var panel: NSPanel?
    private static var hideTask: Task<Void, Never>?

    static func show(_ message: String, logo: NSImage?, seconds: Double = 3.5) {
        panel?.orderOut(nil)
        let content = NSHostingView(rootView: ToastView(message: message, logo: logo))
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize

        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.contentView = content
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        // Top center of the screen with the mouse, below the menu bar.
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2,
                                         y: frame.maxY - size.height - 24))
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; panel.animator().alphaValue = 1 }
        self.panel = panel

        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; panel.animator().alphaValue = 0 },
                                                 completionHandler: { panel.orderOut(nil) })
        }
    }
}

private struct ToastView: View {
    let message: String
    let logo: NSImage?

    var body: some View {
        HStack(spacing: 10) {
            if let logo {
                Image(nsImage: logo)
                    .resizable()
                    .renderingMode(logo.isTemplate ? .template : .original)
                    .frame(width: 20, height: 20)
            }
            Text(message)
                .font(.system(size: 14, weight: .medium))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .padding(16)   // room for the shadow
        .fixedSize()
    }
}
