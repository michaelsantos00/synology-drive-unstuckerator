import AppKit
import DriveMonitorCore
import ServiceManagement
import SwiftUI

public struct MonitorPopover: View {
    @Bindable var model: AppModel
    @Environment(\.openSettings) private var openSettings
    @State private var confirmReset = false

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            if let warning = model.lowDiskWarning {
                notice(warning, color: .orange)
            }
            if let error = model.lastErrorText {
                notice(error, color: .red)
            }

            ScrollView {
                fileList
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: max(160, menuHeightLimit - 200))
            .fixedSize(horizontal: false, vertical: true)

            if confirmReset {
                resetConfirmation
            } else {
                toolbar
            }
        }
        .padding(18)
        .frame(width: 500)
        .frame(maxHeight: menuHeightLimit, alignment: .top)
        .sheet(isPresented: Binding(
            get: { !model.isRestoring && model.needsRootConfirmation },
            set: { model.needsRootConfirmation = $0 }
        )) { RootConfirmationView(model: model) }
    }

    private var menuHeightLimit: CGFloat {
        let screen = NSScreen.main?.visibleFrame.height ?? 900
        return screen * 0.8
    }

    private var fileList: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.discoveredFindings.isEmpty {
                Text("No files discovered yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
            }
            ForEach(model.discoveredFindings) { finding in
                AttentionRow(
                    finding: finding,
                    location: model.fileLocation(finding.canonicalPath),
                    actionTitle: model.fileActionTitle(finding),
                    actionEnabled: model.canRequeue(finding),
                    action: { model.requeue(id: finding.id) },
                    undoEnabled: model.canUndo(finding),
                    undo: { model.undo(id: finding.id) },
                    modelCanDismiss: model.canDismiss(finding),
                    dismiss: { model.dismiss(id: finding.id) }
                )
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            DockMark(side: 44)
                .accessibilityLabel(model.status.accessibilityLabel)
            VStack(alignment: .leading, spacing: 2) {
                Text("Synology Drive Unstuckerator")
                    .font(.headline)
                Text(model.status.accessibilityLabel)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 12) {
            glassGroup {
                HStack(spacing: 8) {
                    toolbarButton("Scan Now", systemImage: "arrow.clockwise", kind: .action) { model.scanNow() }
                        .disabled(model.needsRootConfirmation || model.isScanning)
                    toolbarButton(model.isPaused ? "Resume" : "Pause", systemImage: model.isPaused ? "play.fill" : "pause.fill", kind: .neutral) {
                        model.togglePause()
                    }
                    .disabled(model.needsRootConfirmation)
                    toolbarButton("Reset", systemImage: "arrow.counterclockwise", kind: .destructive) { confirmReset = true }
                        .disabled(model.needsRootConfirmation)
                }
            }
            if model.baselineNeedsReview {
                Button("Acknowledge first-launch baseline") { model.acknowledgeBaseline() }
                    .disabled(model.acknowledgingBaseline)
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                glassGroup {
                    toolbarButton("Settings", systemImage: "gearshape", kind: .neutral) {
                        NSApp.activate()
                        openSettings()
                    }
                }
                Spacer()
                PowerButton()
            }
        }
    }

    private var resetConfirmation: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Clear discovered files?")
                .font(.headline)
            Text("This removes the list and activity history on this Mac. Files in Synology Drive stay where they are.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                glassTextButton("Cancel", kind: .neutral) { confirmReset = false }
                Spacer()
                glassTextButton("Reset Queue", kind: .destructive) {
                    confirmReset = false
                    model.resetQueue()
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 32, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 32, style: .continuous).stroke(Color.primary.opacity(0.22), lineWidth: 1))
    }

    private func toolbarButton(_ title: String, systemImage: String, kind: MenuButtonKind, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.body.weight(.semibold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(GlassButtonStyle(kind: kind))
    }

    private func glassTextButton(_ title: String, kind: MenuButtonKind, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .lineLimit(1)
        }
        .buttonStyle(GlassButtonStyle(kind: kind))
    }

    @ViewBuilder
    private func glassGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: 12) { content() }
        } else {
            content()
        }
    }

    private func notice(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(color)
            .textSelection(.enabled)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.18), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }
}

struct AttentionRow: View {
    let finding: FindingSnapshot
    var location: String
    var actionTitle: String
    var actionEnabled: Bool
    var action: () -> Void
    var undoEnabled: Bool = false
    var undo: () -> Void = {}
    var modelCanDismiss: Bool = false
    var dismiss: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(finding.filename)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                Text(location)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                StatusBadge(finding: finding)
            }
            glassGroup {
                HStack(spacing: 8) {
                    rowButton("Reveal", kind: .neutral) {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: finding.canonicalPath)])
                    }
                    .accessibilityLabel("Reveal \(finding.filename) in Finder")
                    Spacer(minLength: 8)
                    if modelCanDismiss {
                        rowButton("Dismiss", kind: .neutral) { dismiss() }
                            .accessibilityLabel("Dismiss \(finding.filename)")
                    }
                    if undoEnabled {
                        rowButton("Undo", kind: .action) { undo() }
                            .accessibilityLabel("Undo the fix for \(finding.filename)")
                    }
                    if actionEnabled {
                        Button(action: action) {
                            HStack(spacing: 6) {
                                MenuBarMark(height: 15)
                                Text(actionTitle)
                            }
                            .font(.body.weight(.semibold))
                            .lineLimit(1)
                        }
                        .buttonStyle(GlassButtonStyle(kind: .action))
                        .help("Fix only \(finding.filename).")
                        .accessibilityLabel("\(actionTitle) \(finding.filename)")
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func rowButton(_ title: String, kind: MenuButtonKind, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.body.weight(.semibold))
                .lineLimit(1)
        }
        .buttonStyle(GlassButtonStyle(kind: kind))
    }

    @ViewBuilder
    private func glassGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: 12) { content() }
        } else {
            content()
        }
    }
}

private struct StatusBadge: View {
    @Environment(\.colorScheme) private var colorScheme
    let finding: FindingSnapshot

    var body: some View {
        Text(rowStatus(finding))
            .font(.caption.weight(.bold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(background, in: Capsule())
            .accessibilityLabel(rowStatus(finding))
    }

    private var foreground: Color {
        switch finding.disposition {
        case .requeueSucceeded, .resolved:
            colorScheme == .dark ? Color(red: 0.88, green: 1, blue: 0.9) : Color(red: 0.02, green: 0.24, blue: 0.08)
        case .requeueFailed, .compatibilityBlocked:
            colorScheme == .dark ? Color(red: 1, green: 0.9, blue: 0.9) : Color(red: 0.38, green: 0.02, blue: 0.02)
        case .actionable, .existingNeedsReview, .requeuePreparing, .requeueUploading:
            colorScheme == .dark ? Color(red: 1, green: 0.94, blue: 0.82) : Color(red: 0.32, green: 0.14, blue: 0)
        default:
            .primary
        }
    }

    private var background: Color {
        switch finding.disposition {
        case .requeueSucceeded, .resolved:
            colorScheme == .dark ? Color(red: 0.08, green: 0.38, blue: 0.18) : Color(red: 0.62, green: 0.9, blue: 0.68)
        case .requeueFailed, .compatibilityBlocked:
            colorScheme == .dark ? Color(red: 0.48, green: 0.08, blue: 0.08) : Color(red: 1, green: 0.72, blue: 0.72)
        case .actionable, .existingNeedsReview, .requeuePreparing, .requeueUploading:
            colorScheme == .dark ? Color(red: 0.55, green: 0.28, blue: 0) : Color(red: 1, green: 0.82, blue: 0.45)
        default:
            Color.primary.opacity(colorScheme == .dark ? 0.22 : 0.12)
        }
    }
}

struct LaunchAtLoginToggle: View {
    @Bindable var model: AppModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) })) {
                Label("Launch at login", systemImage: "power.circle")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            .toggleStyle(.switch)
            .disabled(model.changingLaunchAtLogin)
            .accessibilityHint("Opens Synology Drive Unstuckerator when you log in to this Mac.")
            Text(statusLine)
                .font(.caption.weight(.medium))
                .foregroundStyle(model.launchAtLoginNeedsApproval ? Color.orange : Color.primary.opacity(0.8))
            if model.launchAtLoginNeedsApproval {
                Button("Allow in System Settings") {
                    SMAppService.openSystemSettingsLoginItems()
                }
                .buttonStyle(ContrastButtonStyle())
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(colorScheme == .dark ? Color(white: 0.22) : Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.primary.opacity(0.28), lineWidth: 1))
        .onAppear { model.refreshLaunchAtLoginStatus() }
    }

    private var statusLine: String {
        if model.launchAtLoginNeedsApproval {
            return "macOS needs approval before this opens at login."
        }
        return model.launchAtLogin ? "Opens when you log in." : "Stays closed until you open it."
    }
}

private enum MenuButtonKind {
    case neutral
    case action
    case destructive

    fileprivate var tint: Color? {
        switch self {
        case .neutral: nil
        case .action: .blue
        case .destructive: .red
        }
    }
}

private struct GlassButtonStyle: ButtonStyle {
    var kind: MenuButtonKind = .neutral
    var circle: Bool = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let tone = GlassTone.resolve(kind.tint, scheme: colorScheme)
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(tone.label)
            .lineLimit(1)
            .padding(.horizontal, circle ? 11 : 16)
            .padding(.vertical, circle ? 11 : 8)
            .modifier(GlassWash(tint: tone.wash, circle: circle))
            .opacity(isEnabled ? 1 : 0.45)
            .opacity(configuration.isPressed ? 0.86 : 1)
    }
}

private struct GlassWash: ViewModifier {
    var tint: Color?
    var circle: Bool

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            if let tint {
                if circle {
                    content.glassEffect(.regular.tint(tint).interactive(), in: .circle)
                } else {
                    content.glassEffect(.regular.tint(tint).interactive(), in: .capsule)
                }
            } else if circle {
                content.glassEffect(.regular.interactive(), in: .circle)
            } else {
                content.glassEffect(.regular.interactive(), in: .capsule)
            }
        } else if let tint {
            if circle {
                content.background(tint, in: Circle())
            } else {
                content.background(tint, in: Capsule())
            }
        } else if circle {
            content.background(Color.primary.opacity(0.08), in: Circle())
        } else {
            content.background(Color.primary.opacity(0.08), in: Capsule())
        }
    }
}

/// Turns a requested hue into a light glass wash, then picks label ink from that wash.
private enum GlassTone {
    static func resolve(_ tint: Color?, scheme: ColorScheme) -> (wash: Color?, label: Color) {
        guard let tint else {
            return (nil, .primary)
        }
        let ns = NSColor(tint).usingColorSpace(.sRGB) ?? .systemBlue
        var red = ns.redComponent
        var green = ns.greenComponent
        var blue = ns.blueComponent
        if scheme == .dark {
            red = red * 0.42 + 0.10
            green = green * 0.42 + 0.10
            blue = blue * 0.42 + 0.12
        } else {
            red = red * 0.40 + 0.60
            green = green * 0.40 + 0.60
            blue = blue * 0.40 + 0.60
        }
        let wash = Color(red: red, green: green, blue: blue)
        let luminance = 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        let label: Color = luminance > 0.42
            ? Color(red: red * 0.20, green: green * 0.20, blue: blue * 0.16)
            : .white
        return (wash, label)
    }

    private static func linear(_ channel: CGFloat) -> CGFloat {
        channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }
}

private struct PowerButton: View {
    var body: some View {
        Button {
            NSApp.terminate(nil)
        } label: {
            Image(systemName: "power")
                .font(.body.weight(.bold))
        }
        .buttonStyle(GlassButtonStyle(kind: .destructive, circle: true))
        .keyboardShortcut("q", modifiers: .command)
        .accessibilityLabel("Quit Synology Drive Unstuckerator")
        .help("Quit Synology Drive Unstuckerator")
    }
}

private struct ContrastButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        HoverChrome(reduceMotion: reduceMotion, pressed: configuration.isPressed) {
            configuration.label
                .font(.body.weight(.semibold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(fill, in: Capsule())
                .overlay(Capsule().strokeBorder(stroke, lineWidth: 1.5))
        }
        .opacity(isEnabled ? 1 : 0.45)
    }

    private var fill: Color {
        colorScheme == .dark ? Color(white: 0.38) : Color.white
    }

    private var stroke: Color {
        colorScheme == .dark ? Color.white.opacity(0.72) : Color.black.opacity(0.55)
    }
}

private struct HoverChrome<Content: View>: View {
    var reduceMotion: Bool
    var pressed: Bool
    @State private var hovering = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .scaleEffect(reduceMotion ? 1 : (pressed ? 0.96 : hovering ? 1.045 : 1))
            .brightness(hovering && !pressed && !reduceMotion ? 0.05 : 0)
            .onHover { hovering = $0 }
            .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.7), value: hovering)
            .animation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.8), value: pressed)
    }
}

private func outcomeColor(_ finding: FindingSnapshot) -> Color {
    switch finding.disposition {
    case .requeueSucceeded, .resolved: .green
    case .requeueFailed, .compatibilityBlocked: .red
    case .actionable, .existingNeedsReview, .requeuePreparing, .requeueUploading: .orange
    case .observing, .sourceChanged, .ignored: .secondary
    }
}

private func rowStatus(_ finding: FindingSnapshot) -> String {
    switch finding.disposition {
    case .requeueSucceeded:
        return "Fixed · Synology reported the replacement uploaded"
    case .requeueFailed:
        return finding.eligibilityBlockReason ?? "Failed · the retry did not upload"
    case .requeuePreparing, .requeueUploading:
        return "Fixing this file"
    case .observing where finding.errorCode == nil:
        return finding.providerState
    case .observing, .actionable, .existingNeedsReview:
        return finding.errorCode == -2005 ? "Needs attention · permanent upload failure -2005" : finding.providerState
    default:
        return finding.providerState
    }
}

struct RootConfirmationView: View {
    @Bindable var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose the folder to monitor").font(.title2.bold())
            Text("Monitoring starts only after you choose a folder. Existing failures will be collected for review. Nested folders are included.")
            if let error = model.lastErrorText { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Choose Folder…") { model.chooseFolder() }.buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 490)
        .interactiveDismissDisabled()
    }
}

#Preview { MonitorPopover(model: AppModel.preview()) }
