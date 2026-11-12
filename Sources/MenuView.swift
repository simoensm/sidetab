import SwiftUI

/// The panel that drops down from the menu bar, laid out like the
/// Control Center modules in macOS (Wi-Fi, Bluetooth, Displays).
struct MenuView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            MenuSeparator()
            deviceRow

            if model.problem == .screenRecording {
                permissionNotice
            }

            MenuSeparator()
            SectionTitle("Resolution")
            ForEach(ResolutionChoice.allCases) { choice in
                MenuRow(action: { model.resolution = choice }) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .opacity(model.resolution == choice ? 1 : 0)
                        .frame(width: 14)
                    Text(choice.title)
                    Spacer(minLength: 12)
                    Text(model.label(for: choice))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            MenuSeparator()
            SectionTitle("Video")
            SettingRow(title: "Frame Rate") {
                Picker("Frame Rate", selection: $model.frameRate) {
                    ForEach(FrameRate.allCases) { rate in
                        Text(rate.title).tag(rate)
                    }
                }
            }
            SettingRow(title: "Quality") {
                Picker("Quality", selection: $model.quality) {
                    ForEach(VideoQuality.allCases) { quality in
                        Text(quality.title).tag(quality)
                    }
                }
            }

            MenuSeparator()
            if model.tablet.isReady && model.isEnabled && model.viewerCount == 0 && model.activeGeometry != nil {
                MenuRow(action: model.openViewerOnTablet) {
                    Text("Open on \(model.deviceName)")
                    Spacer()
                }
            }
            MenuRow(action: model.openDisplaySettings) {
                Text("Displays Settings…")
                Spacer()
            }
            HStack {
                Text("Open at Login")
                Spacer()
                Toggle("Open at Login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.mini)
            }
            .padding(.horizontal, 14)
            .frame(height: 26)

            MenuSeparator()
            MenuRow(action: model.quit) {
                Text("Quit SideTab")
                Spacer()
            }
        }
        .font(.system(size: 13))
        .padding(.bottom, 6)
        .frame(width: 300)
    }

    private var header: some View {
        HStack {
            Text("SideTab")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Toggle("SideTab", isOn: $model.isEnabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.top, 11)
        .padding(.bottom, 4)
    }

    private var deviceRow: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(model.isConnected ? Color.accentColor : Color.primary.opacity(0.12))
                Image(systemName: "ipad.landscape")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(model.isConnected ? Color.white : Color.primary)
            }
            .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 1) {
                Text(model.deviceName)
                Text(model.statusLine)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
    }

    private var permissionNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Allow SideTab in Screen & System Audio Recording, then relaunch it.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Open Settings…", action: model.openScreenRecordingSettings)
                Button("Relaunch", action: model.relaunch)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}

/// A clickable row that highlights under the pointer, like a menu item.
struct MenuRow<Content: View>: View {
    private let action: () -> Void
    private let content: Content
    // A plain @State needs a compiler plugin the Command Line Tools don't ship.
    @StateObject private var hover = HoverState()

    init(action: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.action = action
        self.content = content()
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                content
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hover.isHovering ? Color.primary.opacity(0.1) : Color.clear))
        }
        .buttonStyle(.plain)
        .onHover { hover.isHovering = $0 }
        .padding(.horizontal, 6)
    }
}

final class HoverState: ObservableObject {
    @Published var isHovering = false
}

/// A label on the left and a compact segmented control on the right.
struct SettingRow<Control: View>: View {
    private let title: String
    private let control: Control

    init(title: String, @ViewBuilder control: () -> Control) {
        self.title = title
        self.control = control()
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer(minLength: 12)
            control
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
        }
        .padding(.horizontal, 14)
        .frame(height: 28)
    }
}

struct SectionTitle: View {
    private let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.top, 2)
            .padding(.bottom, 3)
    }
}

struct MenuSeparator: View {
    var body: some View {
        Divider()
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
    }
}
