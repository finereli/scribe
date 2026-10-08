import SwiftUI

@main
struct ScribeApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 820, minHeight: 520)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Start / Stop Recording") { model.toggleRecording() }
                    .keyboardShortcut("r", modifiers: [.command])
            }
        }
    }
}

/// Shared formatting helpers.
enum Format {
    static func duration(_ t: TimeInterval) -> String {
        let total = Int(t.rounded(.down))
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func time(_ date: Date) -> String {
        let cal = Calendar.current
        let formatter = DateFormatter()
        if cal.isDateInToday(date) {
            formatter.dateFormat = "HH:mm"
        } else if cal.isDateInYesterday(date) {
            formatter.dateFormat = "'Yesterday' HH:mm"
        } else {
            formatter.dateFormat = "MMM d"
        }
        return formatter.string(from: date)
    }
}
