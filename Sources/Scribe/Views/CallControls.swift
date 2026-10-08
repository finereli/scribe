import SwiftUI

/// Language and microphone pickers plus a level meter per speaker, so you
/// can see both sides are coming through before the call gets going.
struct CallControls: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 8) {
            languageMenu
            micMenu
            VStack(spacing: 5) {
                meterRow("Me", level: model.micLevel)
                meterRow("Them", level: model.systemLevel)
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 16)
    }

    private func meterRow(_ label: String, level: Float) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .leading)
            LevelMeter(level: level, active: model.isRecording)
                .frame(height: 6)
        }
    }

    private var languageMenu: some View {
        Menu {
            ForEach(CallLanguage.all) { lang in
                Button {
                    model.languageCode = lang.id
                } label: {
                    if lang.id == model.languageCode {
                        Label(lang.name, systemImage: "checkmark")
                    } else {
                        Text(lang.name)
                    }
                }
            }
        } label: {
            pill(icon: "globe", text: CallLanguage.name(for: model.languageCode))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .frame(maxWidth: .infinity)
        .noFocusRing()
        .pointingHandCursor()
        .disabled(model.isRecording)
        .help(model.isRecording
              ? "Stop recording to change the language"
              : "The language of this call")
    }

    private var micMenu: some View {
        Menu {
            if model.devices.devices.isEmpty {
                Text("No input devices found")
            }
            ForEach(model.devices.devices) { device in
                Button {
                    model.devices.selectedDeviceID = device.id
                } label: {
                    if device.id == model.devices.selectedDeviceID {
                        Label(device.name, systemImage: "checkmark")
                    } else {
                        Text(device.name)
                    }
                }
            }
            Divider()
            Button {
                model.devices.refresh()
            } label: {
                Label("Rescan Devices", systemImage: "arrow.clockwise")
            }
        } label: {
            pill(icon: "mic.fill", text: (model.devices.selectedDevice?.name ?? "No Input")
                .trimmingCharacters(in: .whitespacesAndNewlines))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .frame(maxWidth: .infinity)
        .noFocusRing()
        .pointingHandCursor()
        .disabled(model.isRecording)
        .help(model.isRecording
              ? "Stop recording to change the microphone"
              : "Choose which microphone is you")
    }

    /// Icon pinned left, chevron pinned right, text centered.
    private func pill(icon: String, text: String) -> some View {
        ZStack {
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .padding(.horizontal, 22)
                .frame(maxWidth: .infinity)
            HStack {
                Image(systemName: icon).font(.system(size: 12))
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
            }
        }
        .foregroundStyle(model.isRecording ? .secondary : .primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
        .contentShape(Rectangle())
    }
}

/// A segmented horizontal level meter (green → yellow → red).
struct LevelMeter: View {
    var level: Float          // 0...1
    var active: Bool
    private let segments = 20

    var body: some View {
        GeometryReader { geo in
            let gap: CGFloat = 2
            let w = (geo.size.width - gap * CGFloat(segments - 1)) / CGFloat(segments)
            let lit = Int((Float(segments) * level).rounded())
            HStack(spacing: gap) {
                ForEach(0..<segments, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(color(for: i, lit: lit))
                        .frame(width: w)
                }
            }
        }
    }

    private func color(for index: Int, lit: Int) -> Color {
        guard active, index < lit else { return Color.secondary.opacity(0.18) }
        let frac = Double(index) / Double(segments)
        if frac > 0.85 { return .red }
        if frac > 0.65 { return .yellow }
        return .green
    }
}
