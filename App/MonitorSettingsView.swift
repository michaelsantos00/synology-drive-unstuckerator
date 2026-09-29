import DriveMonitorCore
import SwiftUI

public struct MonitorSettingsView: View {
    @Bindable var model: AppModel
    public init(model: AppModel) { self.model = model }

    public var body: some View {
        Form {
            Section("General") {
                LaunchAtLoginToggle(model: model)
                Toggle("Monitoring enabled", isOn: Binding(get: { model.monitoringEnabled }, set: { model.setMonitoringEnabled($0) }))
                    .disabled(model.needsRootConfirmation)
                Toggle("Automatic requeue enabled", isOn: .constant(false))
                    .disabled(true)
                    .accessibilityHint("Automatic requeue is not available in this build.")
                Text("Automatic requeue is not available in this build. Monitoring and detection are automatic; each repair starts when you press Fix.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Desktop notifications enabled", isOn: Binding(get: { model.desktopNotificationsEnabled }, set: { model.setNotificationsEnabled($0) }))
            }
            Section("Watched roots") {
                if model.watchedRoots.isEmpty { Text("No folder selected yet.") }
                ForEach($model.watchedRoots) { $root in
                    Toggle(isOn: $root.enabled) {
                        VStack(alignment: .leading) {
                            Text(root.displayName)
                            Text(model.pathText(root.path)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }
                Button("Choose Folder…") { model.chooseFolder() }
                Text("The selected folder is the top of the tree. Scans walk every nested subfolder and check eligible files modified in the last seven days. A file younger than the stability window is listed while the app waits to confirm it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("File formats") {
                ForEach(FileFormatCatalog.presets) { preset in
                    Toggle(isOn: Binding(
                        get: { model.enabledFormatPresets.contains(preset.id) },
                        set: { model.setFormatPreset(preset.id, enabled: $0) }
                    )) {
                        VStack(alignment: .leading) {
                            Text(preset.title)
                            Text(preset.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                TextField("Other extensions", text: Binding(
                    get: { model.customExtensionsText },
                    set: { model.setCustomExtensions($0) }
                ), prompt: Text("psd, ai, iso"))
                Text("Names containing _segment_ stay ignored, including temporary video pieces.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Monitoring rules") {
                TextField("Ignore patterns (comma separated globs)", text: $model.ignorePatternsText)
                TextField("Minimum stable age (seconds)", value: $model.minimumStableAge, format: .number)
                TextField("Low-disk warning threshold (GiB)", value: $model.lowDiskWarningThresholdGiB, format: .number)
                Text("Free space below 100 GiB always shows a warning. This setting does not enable publication.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Apply Monitoring Settings") { model.applyRootSettings() }
            }
            Section("Diagnostics") {
                Toggle("Show raw paths instead of redacted paths", isOn: $model.showRawPaths)
                Button("Export Diagnostic…") { model.exportDiagnostic() }
            }
            Section("Advanced — later lifecycle controls") {
                Text("Synology lifecycle controls will be available in a later version.")
                    .foregroundStyle(.secondary)
            }
            if let error = model.lastErrorText { Section("Status") { Text(error).foregroundStyle(.red).textSelection(.enabled) } }
        }
        .formStyle(.grouped)
        .frame(width: 640, height: 760)
        .sheet(isPresented: $model.needsRootConfirmation) { RootConfirmationView(model: model) }
    }
}
