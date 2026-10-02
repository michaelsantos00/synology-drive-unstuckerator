import AppKit
import DriveMonitorCore
import SwiftUI

public enum MonitorSettingsSection: Hashable { case general, folders, diagnostics }

public struct MonitorSettingsView: View {
    @Bindable var model: AppModel
    @State private var section: MonitorSettingsSection
    @State private var diagnosticPreview = false
    @State private var discardChanges = false
    @State private var pendingFolderID: UUID?
    @State private var pendingAdd = false
    @State private var pendingDrop: URL?
    @State private var confirmRemoval = false

    // The requested section seeds a newly opened Settings view.
    public init(model: AppModel, section: MonitorSettingsSection = .general) {
        self.model = model
        _section = State(initialValue: section)
    }

    private var busy: Bool {
        model.savingConfiguration || model.savingAutomaticSetting || model.changingMonitoring || model.isRestoring
    }
    private var selectedRoot: WatchedRootSnapshot? { model.watchedRoots.first { $0.id == model.editingRootID } }

    public var body: some View {
        TabView(selection: $section) {
            general.tabItem { Label("General", systemImage: "gearshape") }.tag(MonitorSettingsSection.general)
            folders.tabItem { Label("Folders", systemImage: "folder") }.tag(MonitorSettingsSection.folders)
            diagnostics.tabItem { Label("Diagnostics", systemImage: "stethoscope") }.tag(MonitorSettingsSection.diagnostics)
        }
        .task { await model.refreshNotificationStatus() }
        .onChange(of: model.watchedRoots.map(\.id), initial: true) {
            if selectedRoot == nil, let first = model.watchedRoots.first { model.selectSettingsRoot(first.id) }
        }
        .confirmationDialog("Discard unsaved folder rules?", isPresented: $discardChanges) {
            Button("Discard Changes", role: .destructive) {
                if let id = model.editingRootID { model.selectSettingsRoot(id) }
                if let url = pendingDrop { model.addRoot(url) }
                else if pendingAdd { model.addFolder() }
                else if let id = pendingFolderID { model.selectSettingsRoot(id) }
                clearPending()
            }
            Button("Keep Editing", role: .cancel) { clearPending() }
        } message: { Text("Apply your folder rules first to keep these edits.") }
        .confirmationDialog("Stop watching \(selectedRoot?.displayName ?? "this folder")?", isPresented: $confirmRemoval) {
            Button("Remove Folder", role: .destructive) {
                if let id = model.editingRootID { model.removeRoot(id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Monitoring and new automatic repairs stop for this folder. Its files, history, and recovery copies stay where they are.") }
        .sheet(isPresented: $diagnosticPreview) { diagnosticSheet }
    }

    // MARK: General

    private var general: some View {
        Form {
            Section("Startup") {
                LaunchAtLoginToggle(model: model)
            }
            Section("Notifications") {
                Toggle(isOn: Binding(get: { model.desktopNotificationsEnabled }, set: { model.setNotificationsEnabled($0) })) {
                    Text("Notify me about files")
                    Text("When a file needs a decision, or a repair finishes or stops.")
                }
                if model.desktopNotificationsEnabled || model.notificationAuthorization == .denied {
                    LabeledContent("Permission") {
                        HStack {
                            Text(model.notificationStatusText).foregroundStyle(.secondary)
                            if model.notificationAuthorization == .denied {
                                Button("Open System Settings…") { NSWorkspace.shared.open(SystemSettingsLinks.notifications) }
                            }
                        }
                    }
                }
            }
            Section("Monitoring") {
                Toggle(isOn: Binding(get: { model.monitoringEnabled }, set: { model.setMonitoringEnabled($0) })) {
                    Text("Monitor watched folders")
                    Text("Pausing stops scans and new repairs. Copies already published keep verifying.")
                }
                .disabled(model.needsRootConfirmation)
                LabeledContent("Watched folders") {
                    HStack {
                        Text("\(model.watchedRoots.filter(\.enabled).count) of \(model.watchedRoots.count) on").foregroundStyle(.secondary)
                        Button("Manage…") { section = .folders }
                    }
                }
            }
            Section("Auto-fix") {
                LabeledContent {
                    Text(automaticFolders.isEmpty ? "Off in all folders" : "On for " + ListFormatter.localizedString(byJoining: automaticFolders))
                } label: {
                    Text("Auto-fix")
                    Text("Turn it on for each folder in Folders. New folders start with it off, and files found when a folder is added always need a manual Fix.")
                }
                Button("Turn Off Auto-fix in All Folders") { model.setAutomaticRequeueEnabled(false) }
                    .disabled(!model.automaticRequeueEnabled)
            }
            Section("Disk Space") {
                LabeledContent {
                    HStack(spacing: 4) {
                        TextField("Warning threshold", value: threshold, format: .number)
                            .labelsHidden().multilineTextAlignment(.trailing).frame(width: 64)
                            .accessibilityLabel("Warn when free space is below, in GiB")
                        Stepper("Warning threshold", value: threshold, in: 100...100_000, step: 50).labelsHidden()
                            .accessibilityLabel("Warn when free space is below, in GiB")
                        Text("GiB")
                    }
                } label: {
                    Text("Warn when free space is below")
                    Text("Below 100 GiB a warning always shows. It is only a warning: each repair checks the space it needs before copying.")
                }
            }
        }
        .formStyle(.grouped)
        .disabled(busy)
        .safeAreaInset(edge: .bottom, spacing: 0) { errorBanner }
        .frame(width: 600, height: 690)
    }

    private var automaticFolders: [String] {
        guard model.automaticControlsAvailable else { return [] }
        return model.watchedRoots.filter { $0.enabled && $0.automaticRequeueEnabled }.map(\.displayName)
    }

    private var threshold: Binding<Double> {
        Binding(get: { max(100, model.lowDiskWarningThresholdGiB) }, set: { model.setLowDiskWarningThreshold(max(100, $0)) })
    }

    // MARK: Folders

    private var folders: some View {
        HStack(spacing: 0) {
            folderList.frame(width: 250)
            Divider()
            Group {
                if let root = selectedRoot {
                    folderEditor(root)
                } else {
                    ContentUnavailableView {
                        Label("No Watched Folders", systemImage: "folder.badge.plus")
                    } description: {
                        Text("Add a Synology Drive folder, or drag one here.")
                    } actions: {
                        Button("Add Folder…") { requestAdd() }.disabled(busy)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { errorBanner }
        .frame(width: 880, height: 640)
    }

    private var folderList: some View {
        VStack(spacing: 0) {
            List(selection: Binding(get: { model.editingRootID }, set: { requestSelection($0) })) {
                ForEach(model.watchedRoots) { root in
                    HStack(spacing: 8) {
                        Image(systemName: root.enabled ? "folder.fill" : "folder")
                            .foregroundStyle(root.enabled ? Color.accentColor : .secondary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(root.displayName).fontWeight(.medium).lineLimit(1)
                            Text(folderState(root)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .padding(.vertical, 3)
                    .help(model.pathText(root.path))
                    .tag(root.id)
                }
            }
            .listStyle(.sidebar)
            Divider()
            HStack(spacing: 0) {
                Button { requestAdd() } label: { Label("Add Folder…", systemImage: "plus").frame(width: 26, height: 22) }
                    .help("Add a folder to watch")
                Divider().frame(height: 14)
                Button { confirmRemoval = true } label: { Label("Remove Folder…", systemImage: "minus").frame(width: 26, height: 22) }
                    .disabled(selectedRoot == nil || model.watchedRoots.count <= 1 || busy)
                    .help(model.watchedRoots.count <= 1 ? "Add another folder before removing the last one" : "Stop watching the selected folder; its files are kept")
                Spacer()
            }
            .labelStyle(.iconOnly).buttonStyle(.borderless).disabled(busy)
            .padding(.horizontal, 6).padding(.vertical, 3)
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, url.hasDirectoryPath || (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  !busy else { return false }
            if model.hasPendingFolderSettings { pendingDrop = url; discardChanges = true } else { model.addRoot(url) }
            return true
        }
    }

    private func folderEditor(_ root: WatchedRootSnapshot) -> some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    LabeledContent {
                        Button("Reveal in Finder") { Finder.reveal(root.path) }
                    } label: {
                        Text(root.displayName).font(.headline)
                        Text(model.pathText(root.path)).textSelection(.enabled)
                    }
                    Toggle(isOn: Binding(get: { root.enabled }, set: { model.setRootEnabled(root.id, enabled: $0) })) {
                        Text("Monitor this folder")
                        Text("Nested folders are included. Saves immediately.")
                    }
                    if model.unavailableRootIDs.contains(root.id) {
                        Label {
                            Text("Waiting for folder access. Monitoring will retry.")
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                    }
                }
                Section("Auto-fix") {
                    Toggle(isOn: Binding(
                        get: { root.automaticRequeueEnabled && model.automaticControlsAvailable },
                        set: { model.setAutomaticRequeueEnabled($0, rootID: root.id) })) {
                        Text("Auto-fix new failures")
                        Text("Repairs one newly confirmed failure at a time, after the stability wait and two checks. Saves immediately.")
                    }
                    .disabled(!root.enabled || (root.baselineCompletedAt == nil && !root.automaticRequeueEnabled))
                    if let reviewed = root.baselineCompletedAt {
                        Label("Setup reviewed \(reviewed.formatted(date: .abbreviated, time: .omitted))", systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Before auto-fix can be turned on, review the files found when this folder was added. Those files always need a manual Fix.")
                                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            HStack {
                                Button("Review in Activity…") { model.showActivity(filter: .existing) }
                                Button("Mark Setup as Reviewed") { model.acknowledgeBaseline(rootID: root.id) }
                                    .disabled(!root.enabled || model.acknowledgingBaseline || model.isScanning)
                            }
                        }
                    }
                }
                Section("File Types") {
                    ForEach(FileFormatCatalog.presets) { preset in
                        Toggle(isOn: Binding(get: { model.enabledFormatPresets.contains(preset.id) },
                            set: { model.setFormatPreset(preset.id, enabled: $0) })) {
                            Text(preset.title)
                            Text(preset.detail)
                        }
                    }
                    TextField("Other extensions", text: Binding(get: { model.customExtensionsText }, set: { model.setCustomExtensions($0) }),
                              prompt: Text("psd, ai, iso"))
                }
                Section("Rules") {
                    TextField("Ignore names matching", text: $model.ignorePatternsText)
                    Picker("Check a file after it stops changing for", selection: $model.minimumStableAge) {
                        ForEach(stableAgeOptions, id: \.self) { seconds in
                            Text(Self.durationText(seconds)).tag(seconds)
                        }
                    }
                    Text("Separate patterns with commas. Temporary _segment_ files are always ignored. Files changed in the last 7 days are discovered; known failures stay tracked.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if model.hasPendingFolderSettings {
                    Label {
                        Text("File types and rules have unapplied changes")
                    } icon: {
                        Image(systemName: "circle.fill").foregroundStyle(.orange).imageScale(.small)
                    }
                    .font(.caption)
                } else {
                    Text("File types and rules are applied").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Revert") { model.selectSettingsRoot(root.id) }.disabled(!model.hasPendingFolderSettings)
                Button("Apply Rules") { model.applyRootSettings() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.hasPendingFolderSettings)
            }
            .padding(12)
        }
        .disabled(busy)
    }

    /// Common waits, plus the folder's current value so a custom setting is never hidden.
    private var stableAgeOptions: [Double] {
        let presets: [Double] = [60, 120, 300, 600, 900, 1800, 3600, 7200]
        return presets.contains(model.minimumStableAge) ? presets : (presets + [model.minimumStableAge]).sorted()
    }

    static func durationText(_ seconds: Double) -> String {
        Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
    }

    // MARK: Diagnostics

    private var diagnostics: some View {
        Form {
            Section("Privacy") {
                Toggle(isOn: $model.showRawPaths) {
                    Text("Show full paths and provider identifiers")
                    Text("When off, the app shows file names only and hides identifying details, including in diagnostic reports.")
                }
            }
            Section("Support") {
                LabeledContent {
                    Button("Preview and Export…") { diagnosticPreview = true }
                } label: {
                    Text("Diagnostic report")
                    Text("Review exactly what is included before you save it.")
                }
                LabeledContent {
                    Button("Show in Finder") {
                        if let folder = try? AppStorage.folderURL() { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                    }
                } label: {
                    Text("App data")
                    Text("History, staging, Undo copies, and repair records. Delete it only when you no longer need Undo.")
                }
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom, spacing: 0) { errorBanner }
        .frame(width: 600, height: 400)
    }

    private var diagnosticSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Diagnostic Preview").font(.title2.bold()).accessibilityAddTraits(.isHeader)
            Toggle("Include full paths and provider identifiers", isOn: $model.showRawPaths)
            ScrollView {
                Text(model.diagnosticSummary()).font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
            HStack {
                Button("Cancel") { diagnosticPreview = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Export…") { model.exportDiagnostic(); diagnosticPreview = false }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 620, height: 620)
    }

    @ViewBuilder private var errorBanner: some View {
        if let error = model.lastErrorText {
            NoticeView(symbol: "exclamationmark.triangle.fill", tint: .red, text: model.diagnosticText(error), lineLimit: 4) {
                Button { model.dismissError() } label: {
                    Label("Dismiss Error", systemImage: "xmark").frame(minWidth: 22, minHeight: 22).contentShape(Rectangle())
                }
                .labelStyle(.iconOnly).buttonStyle(.borderless).help("Dismiss")
            }
            .padding(10)
            .background(.bar)
        }
    }

    // MARK: Folder selection

    private func clearPending() { pendingAdd = false; pendingFolderID = nil; pendingDrop = nil }

    private func requestAdd() {
        if model.hasPendingFolderSettings { clearPending(); pendingAdd = true; discardChanges = true }
        else { model.addFolder() }
    }
    private func requestSelection(_ id: UUID?) {
        guard let id, id != model.editingRootID, !busy else { return }
        if model.hasPendingFolderSettings { clearPending(); pendingFolderID = id; discardChanges = true }
        else { model.selectSettingsRoot(id) }
    }
    private func folderState(_ root: WatchedRootSnapshot) -> String {
        if !root.enabled { return "Off" }
        if model.unavailableRootIDs.contains(root.id) { return "Waiting for access" }
        return root.automaticRequeueEnabled && model.automaticControlsAvailable ? "Watching · Auto-fix on" : "Watching"
    }
}

enum SystemSettingsLinks {
    static var notifications: URL {
        URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier ?? "")")!
    }
}
