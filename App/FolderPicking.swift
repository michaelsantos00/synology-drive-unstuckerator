import AppKit
import Foundation

@MainActor
public enum FolderPicking {
    public static func pickFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose a folder to monitor"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    public static func exportDiagnostic(_ text: String) throws {
        let panel = NSSavePanel()
        panel.title = "Export Diagnostic"
        panel.nameFieldStringValue = "Synology Drive Unstuckerator Diagnostic.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard !url.resolvingSymlinksInPath().pathComponents.contains("CloudStorage") else {
            throw DiagnosticExportError.syncedDestination
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}

private enum DiagnosticExportError: LocalizedError {
    case syncedDestination
    var errorDescription: String? { "Choose an export location outside Library/CloudStorage." }
}
