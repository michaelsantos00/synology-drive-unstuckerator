import AppKit
import DriveMonitorCore
import ServiceManagement
import SwiftUI

public enum FindingQueue: String, CaseIterable, Identifiable {
    case attention = "Attention", checking = "Checking", repairing = "Repairing", recent = "Recent"
    public var id: String { rawValue }
    public func includes(_ finding: FindingSnapshot) -> Bool {
        switch self {
        case .attention: [.actionable, .existingNeedsReview, .requeueFailed, .recoveryRequired, .compatibilityBlocked].contains(finding.disposition)
            || finding.finalNameFailed
        case .checking: finding.disposition == .observing
        case .repairing: [.requeuePreparing, .requeueUploading].contains(finding.disposition)
        // Earlier versions are history, not outcomes; Activity lists them separately.
        case .recent: [.requeueSucceeded, .resolved].contains(finding.disposition) && !finding.finalNameFailed
        }
    }

    var emptyTitle: String {
        switch self {
        case .attention: "Nothing needs attention"
        case .checking: "Nothing is being checked"
        case .repairing: "No repairs running"
        case .recent: "No recent repairs"
        }
    }

    var emptySymbol: String {
        switch self {
        case .attention: "checkmark.circle"
        case .checking: "clock"
        case .repairing: "arrow.triangle.2.circlepath"
        case .recent: "tray"
        }
    }
}

/// The menu-bar panel: state at a glance, the few files that need a decision, and a way into Activity.
public struct MonitorPopover: View {
    @Bindable var model: AppModel
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @State private var selectedGroup: FindingQueue = .attention
    private static let rowLimit = 3
    public init(model: AppModel) { self.model = model }
    private var visible: [FindingSnapshot] { model.queueFindings(selectedGroup) }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 12)
            Group {
                if model.isRestoring {
                    // The header already shows progress; keep the panel short while saved state loads.
                    EmptyView()
                } else if model.needsRootConfirmation {
                    setupCard
                } else {
                    content
                }
            }
            .padding(.horizontal, 14).padding(.bottom, 12)
            Divider()
            bottomBar.padding(.horizontal, 10).padding(.vertical, 8)
        }
        .frame(width: 400)
        // The menu-bar label installs this at launch; the panel installs it too in case the label did not.
        .onAppear { if model.windowPresenter == nil { model.windowPresenter = { openWindow(id: $0.rawValue) } } }
    }

    /// An app-modal alert: a dialog attached to the menu-bar panel can close with the panel when it takes focus.
    private func confirmClearHistory() {
        let alert = NSAlert()
        alert.messageText = "Clear unprotected history?"
        alert.informativeText = "Active repairs, recovery files, and Undo records stay available. Ignored files and files found at setup keep their status."
        alert.addButton(withTitle: "Clear History").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn { model.resetQueue() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            DockMark(side: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text("Synology Drive Unstuckerator").font(.headline).accessibilityAddTraits(.isHeader)
                HStack(spacing: 5) {
                    if model.isScanning || model.isRestoring {
                        ProgressView().controlSize(.mini)
                    } else if model.needsRootConfirmation {
                        Image(systemName: "folder.badge.plus").foregroundStyle(.tint)
                    } else if model.status == .healthy && model.lastScanDate == nil {
                        Image(systemName: "clock").foregroundStyle(.secondary)
                    } else {
                        Image(systemName: model.status.filledSymbolName).foregroundStyle(model.status.tint)
                    }
                    Text(model.statusTitle)
                }
                .font(.subheadline)
                .accessibilityElement(children: .combine)
                if !model.needsRootConfirmation && !model.isRestoring {
                    TimelineView(.everyMinute) { _ in
                        Text(contextLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .help(model.automaticScopeText)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var contextLine: String {
        let checked = model.lastScanDate.map { "Checked " + $0.formatted(.relative(presentation: .named)) } ?? "Not checked yet"
        return [model.watchedFolderSummary, checked, model.automaticSummary].joined(separator: " · ")
    }

    @ViewBuilder private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            notices
            Picker("Show", selection: $selectedGroup) {
                ForEach(FindingQueue.allCases) { group in
                    Text("\(group.rawValue) \(model.queueFindings(group).count)").tag(group)
                }
            }
            .pickerStyle(.segmented).labelsHidden()
            if visible.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: selectedGroup.emptySymbol).font(.title2).foregroundStyle(.secondary)
                    Text(selectedGroup.emptyTitle).font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 18)
                .accessibilityElement(children: .combine)
            } else {
                VStack(spacing: 2) {
                    ForEach(Array(visible.prefix(Self.rowLimit))) { finding in
                        QueueRow(model: model, finding: finding)
                    }
                }
            }
            Button(visible.count > Self.rowLimit ? "Show All \(visible.count) in Activity" : "Open Activity") {
                model.showActivity(filter: ActivityFilter(queue: selectedGroup))
            }
            .buttonStyle(.link).font(.callout)
        }
    }

    @ViewBuilder private var notices: some View {
        if !model.unreadableOperationFiles.isEmpty {
            NoticeView(symbol: "lock.trianglebadge.exclamationmark", tint: .red,
                       text: "Repair is blocked by unreadable operation records. Monitoring continues.") {
                Button("Review") { model.showActivity(filter: .recovery) }.controlSize(.small)
            }
        }
        if let text = model.rootAvailabilityText {
            NoticeView(symbol: "externaldrive.badge.exclamationmark", tint: .orange, text: text)
        }
        if let warning = model.lowDiskWarning {
            NoticeView(symbol: "internaldrive", tint: .orange, text: warning)
        }
        if let error = model.lastErrorText {
            NoticeView(symbol: "exclamationmark.octagon.fill", tint: .red, text: model.diagnosticText(error), lineLimit: 4) {
                Button { model.dismissError() } label: {
                    Label("Dismiss Error", systemImage: "xmark").frame(minWidth: 22, minHeight: 22).contentShape(Rectangle())
                }
                .labelStyle(.iconOnly).buttonStyle(.borderless).help("Dismiss")
            }
        }
    }

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pick a folder inside Synology Drive. Nested folders are included, and auto-fix starts off.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = model.lastErrorText {
                NoticeView(symbol: "exclamationmark.octagon.fill", tint: .red, text: error, lineLimit: 4)
            }
            Button("Choose Folder…") { model.present(.welcome) }
                .buttonStyle(.borderedProminent)
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 8) {
            if model.needsRootConfirmation || model.isRestoring {
                // Scanning and pausing mean nothing until a folder is watched.
            } else {
                // One button whose title and action switch, so keyboard and VoiceOver focus survive the change.
                Button { model.isScanning ? model.cancelScan() : model.scanNow() } label: {
                    Label(model.isScanning ? "Stop Scan" : "Scan Now", systemImage: model.isScanning ? "stop.fill" : "arrow.clockwise")
                }
                .keyboardShortcut(model.isScanning ? "." : "r", modifiers: .command)
                .disabled(!model.isScanning && model.savingConfiguration)
                .help(model.isScanning ? "Stop the scan in progress (⌘.)" : "Check watched folders now (⌘R)")
            }
            if !model.needsRootConfirmation && !model.isRestoring {
                Button { model.togglePause() } label: {
                    Label(model.isPaused ? "Resume" : "Pause", systemImage: model.isPaused ? "play.fill" : "pause.fill")
                }
                .disabled(model.changingMonitoring || model.savingConfiguration || model.savingAutomaticSetting)
                .help(model.isPaused ? "Resume scans and repairs" : "Pause scans and new repairs")
            }
            Spacer()
            Button { model.showActivity() } label: { Label("Activity", systemImage: "list.bullet.rectangle") }
                .labelStyle(.iconOnly).buttonStyle(.borderless).help("Activity and Recovery")
            Button { NSApp.activate(); openSettings() } label: { Label("Settings…", systemImage: "gearshape") }
                .labelStyle(.iconOnly).buttonStyle(.borderless).help("Settings (⌘,)")
                .keyboardShortcut(",", modifiers: .command)
            Menu {
                Button("About Synology Drive Unstuckerator") {
                    NSApp.activate()
                    NSApp.orderFrontStandardAboutPanel(nil)
                }
                Button("Check for Updates on GitHub…") { NSWorkspace.shared.open(AppLinks.releases) }
                Divider()
                Button("Clear Unprotected History…") { confirmClearHistory() }
                Divider()
                Button("Quit Synology Drive Unstuckerator") { NSApp.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command)
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .menuStyle(.button).buttonStyle(.borderless).menuIndicator(.hidden).labelStyle(.iconOnly).fixedSize()
            .help("More")
        }
        .buttonStyle(.bordered)
    }
}

enum AppLinks {
    static let releases = URL(string: "https://github.com/michaelsantos00/synology-drive-unstuckerator/releases")!
}

/// One file in the menu. The row opens its details in Activity; Fix and Undo stay one click away.
struct QueueRow: View {
    @Bindable var model: AppModel
    let finding: FindingSnapshot
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Button { model.showActivity(selecting: finding.id) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: finding.statusSymbol).foregroundStyle(finding.statusTint).frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(finding.filename).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                        Text("\(model.fileLocation(finding.canonicalPath)) · \(finding.sizeText)")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Text(statusLine).font(.caption).lineLimit(2)
                        if let blockReason {
                            // Primary color: this is the only visible reason Fix is unavailable.
                            Text(blockReason).font(.caption).lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("\(finding.filename)\n\(model.pathText(finding.canonicalPath))\nClick to show details in Activity.")
            .accessibilityHint("Shows this file’s details in the Activity window.")
            // The context menu's actions, reachable without a pointer.
            .accessibilityActions { FindingActions(model: model, finding: finding) }
            actions
        }
        .padding(.vertical, 6).padding(.horizontal, 6)
        .background(hovering ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Show Details") { model.showActivity(selecting: finding.id) }
            FindingActions(model: model, finding: finding)
        }
    }

    private var statusLine: String {
        finding.disposition == .observing && finding.errorCode == -2005
            ? "\(finding.statusText) · check \(finding.confirmationCount) of 2" : finding.statusText
    }

    /// Why Fix is unavailable, shown where the row offers Fix but cannot run it.
    private var blockReason: String? {
        guard !model.canRequeue(finding),
              [.observing, .actionable, .existingNeedsReview, .compatibilityBlocked].contains(finding.disposition) else { return nil }
        return model.repairBlockReason(finding)
    }

    private var offersFix: Bool {
        model.canRequeue(finding) || [.observing, .actionable, .existingNeedsReview, .requeuePreparing, .compatibilityBlocked].contains(finding.disposition)
    }

    @ViewBuilder private var actions: some View {
        if model.canUndo(finding) {
            Button("Undo") { model.undo(id: finding.id) }
                .controlSize(.small)
                .help("Restore the original and keep the replacement in Recovery")
                .accessibilityLabel("Undo replacement of \(finding.filename)")
        }
        if offersFix {
            Button(model.fileActionTitle(finding)) { model.requeue(id: finding.id) }
                .buttonStyle(.borderedProminent).controlSize(.small)
                .disabled(!model.canRequeue(finding))
                .help(model.repairBlockReason(finding) ?? "Publish one verified copy for Synology to upload; the original is kept")
                .accessibilityLabel("\(model.fileActionTitle(finding)) \(finding.filename)")
        }
    }
}

/// Every file action in one place, so menus, rows, and the inspector stay consistent.
struct FindingActions: View {
    @Bindable var model: AppModel
    let finding: FindingSnapshot

    var body: some View {
        if model.canRequeue(finding) {
            Button(model.fileActionTitle(finding)) { model.requeue(id: finding.id) }
        }
        if model.canUndo(finding) {
            Button("Undo Replacement") { model.undo(id: finding.id) }
        }
        if ![.requeueUploading, .requeueSucceeded].contains(finding.disposition) {
            Button("Check Again") { model.recheck(id: finding.id) }
        }
        Divider()
        Button("Reveal in Finder") { Finder.reveal(finding) }
        Button("Copy Diagnostic") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(model.copyDiagnostic(id: finding.id), forType: .string)
        }
        if !finding.hasRepairEvidence && !model.requeueInFlight.contains(finding.id) {
            Divider()
            if finding.disposition != .ignored {
                Button("Ignore This Version") { model.ignore(id: finding.id) }
            }
            if finding.disposition != .resolved {
                Button("Mark as Resolved") { model.markResolved(id: finding.id) }
            }
        }
    }
}

struct LaunchAtLoginToggle: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) })) {
                Text("Open at login")
                Text(statusLine)
            }
            .disabled(model.changingLaunchAtLogin)
            .accessibilityHint("Opens Synology Drive Unstuckerator when you log in to this Mac.")
            if model.launchAtLoginNeedsApproval {
                Button("Allow in System Settings…") {
                    SMAppService.openSystemSettingsLoginItems()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { model.refreshLaunchAtLoginStatus() }
    }

    private var statusLine: String {
        if model.launchAtLoginNeedsApproval {
            return "macOS needs your approval before this opens at login."
        }
        return model.launchAtLogin ? "Opens when you log in, so folders are watched without starting it yourself."
            : "Stays closed until you open it."
    }
}

#Preview { MonitorPopover(model: AppModel.preview()) }
