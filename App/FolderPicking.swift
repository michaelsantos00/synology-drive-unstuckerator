import AppKit
import Foundation

@MainActor
public enum FolderPicking {
    public static func pickFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose a Folder to Watch"
        panel.message = "Choose a folder inside Synology Drive. Nested folders are included."
        panel.prompt = "Watch Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = suggestedDirectory()
        // The panel keeps a weak reference; this local keeps the validator alive while it runs.
        let validator = CloudStorageValidator(root: cloudStorage.resolvingSymlinksInPath().path)
        panel.delegate = validator
        NSApp?.activate()
        let result = panel.runModal()
        panel.delegate = nil
        return result == .OK ? panel.url : nil
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

    static var cloudStorage: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/CloudStorage", isDirectory: true)
    }

    /// Opens on the Synology Drive folder when there is exactly one, so most people choose in one step.
    private static func suggestedDirectory() -> URL? {
        let root = cloudStorage
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return nil }
        let synology = names.filter { $0.hasPrefix("SynologyDrive") }.sorted()
        return synology.count == 1 ? root.appendingPathComponent(synology[0], isDirectory: true) : root
    }
}

/// Synology Drive's File Provider folders live under ~/Library/CloudStorage. Other folders are not
/// uploaded by Drive, so watching them would only produce provider errors.
private final class CloudStorageValidator: NSObject, NSOpenSavePanelDelegate {
    let root: String
    init(root: String) { self.root = root }

    func panel(_ sender: Any, validate url: URL) throws {
        let path = url.resolvingSymlinksInPath().path
        guard path.hasPrefix(root + "/") else { throw FolderChoiceError.outsideCloudStorage }
    }
}

private enum FolderChoiceError: LocalizedError {
    case outsideCloudStorage
    var errorDescription: String? { "Choose a folder inside Synology Drive." }
    var recoverySuggestion: String? {
        "Synology Drive folders are in Library/CloudStorage in your home folder. Folders elsewhere aren’t uploaded by Synology Drive, so they can’t have this upload problem."
    }
}

private enum DiagnosticExportError: LocalizedError {
    case syncedDestination
    var errorDescription: String? { "Choose an export location outside Library/CloudStorage." }
}
