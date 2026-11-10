import AppKit
import SwiftUI

/// The small panel in the top-right corner that asks about a call: "Record
/// this Zoom call?" when one starts, "Stopping the recording in 10s" when it
/// ends. It floats above every app, including full-screen ones, and clicking
/// it doesn't bring Scribe's window forward, so the call stays in front.
@MainActor
enum CallOverlay {
    struct Action {
        let title: String
        let isPrimary: Bool
        let run: () -> Void
    }

    private static var panel: NSPanel?
    private static var task: Task<Void, Never>?

    /// Show the overlay, replacing any that's up. With `deadline`, a bar
    /// drains until then and `onDeadline` runs when it's empty. With
    /// `hideAfter`, the overlay fades out on its own.
    static func show(icon: NSImage, title: String, message: String, actions: [Action],
                     deadline: Date? = nil, onDeadline: (() -> Void)? = nil,
                     hideAfter: Double? = nil) {
        dismiss(animated: false)

        // Every button also closes the overlay.
        let wrapped = actions.map { action in
            Action(title: action.title, isPrimary: action.isPrimary) {
                dismiss()
                action.run()
            }
        }
        let view = OverlayView(icon: icon, title: title, message: message, actions: wrapped,
                               start: Date(), deadline: deadline)
        let content = ClickThroughHostingView(rootView: view)
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
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        // Top right of the screen with the mouse, where notifications go.
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.maxX - size.width - 4,
                                         y: frame.maxY - size.height - 4))
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; panel.animator().alphaValue = 1 }
        self.panel = panel

        let wait = deadline.map { $0.timeIntervalSinceNow } ?? hideAfter
        if let wait {
            task = Task {
                try? await Task.sleep(for: .seconds(max(0, wait)))
                guard !Task.isCancelled else { return }
                dismiss()
                if deadline != nil { onDeadline?() }
            }
        }
    }

    static func dismiss(animated: Bool = true) {
        task?.cancel()
        task = nil
        guard let panel else { return }
        self.panel = nil
        if animated {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; panel.animator().alphaValue = 0 },
                                                 completionHandler: { panel.orderOut(nil) })
        } else {
            panel.orderOut(nil)
        }
    }
}

/// Buttons work on the first click, even though the panel never becomes
/// the key window.
private final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct OverlayView: View {
    let icon: NSImage
    let title: String
    let message: String
    let actions: [CallOverlay.Action]
    let start: Date
    let deadline: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                    messageText
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                ForEach(actions.indices, id: \.self) { i in
                    let action = actions[i]
                    Button(action.title, action: action.run)
                        .buttonStyle(OverlayButtonStyle(isPrimary: action.isPrimary))
                }
            }
        }
        .padding(14)
        .frame(width: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(alignment: .bottom) { countdownBar }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.2), radius: 14, y: 5)
        .padding(16)   // room for the shadow
        .fixedSize()
    }

    /// The message, with "{s}" replaced by the seconds left before the
    /// deadline, kept current.
    @ViewBuilder private var messageText: some View {
        if let deadline, message.contains("{s}") {
            TimelineView(.periodic(from: start, by: 1)) { context in
                let left = max(0, Int(deadline.timeIntervalSince(context.date).rounded(.up)))
                Text(message.replacingOccurrences(of: "{s}", with: "\(left)"))
                    .monospacedDigit()
            }
        } else {
            Text(message)
        }
    }

    /// A line along the bottom edge that drains as the deadline nears.
    @ViewBuilder private var countdownBar: some View {
        if let deadline {
            TimelineView(.animation) { context in
                let total = deadline.timeIntervalSince(start)
                let left = max(0, deadline.timeIntervalSince(context.date))
                GeometryReader { geo in
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: geo.size.width * (total > 0 ? left / total : 0))
                }
                .frame(height: 3)
            }
        }
    }
}

/// The panel is never the key window, and macOS greys out the standard
/// prominent button in windows that aren't. This one keeps its color.
private struct OverlayButtonStyle: ButtonStyle {
    let isPrimary: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: isPrimary ? .semibold : .regular))
            .foregroundStyle(isPrimary ? Color.white : Color.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(isPrimary ? Color.accentColor : Color.primary.opacity(0.1),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Rectangle())
    }
}
