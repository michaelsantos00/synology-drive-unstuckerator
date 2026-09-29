import Foundation

/// On-disk home for history, staging, and the undo cache. Lives outside CloudStorage.
public enum AppStorage {
    public static let folderName = "Synology Drive Unstuckerator"
    /// Newer name first, so a folder from the previous build is preferred over the original name.
    private static let legacyFolderNames = ["Unstuckerator", "Synology Drive Monitor"]

    /// The application-support folder. An existing folder from a previous name is moved once.
    public static func folderURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let current = base.appendingPathComponent(folderName, isDirectory: true)
        let files = FileManager.default
        if !files.fileExists(atPath: current.path) {
            for legacyName in legacyFolderNames {
                let legacy = base.appendingPathComponent(legacyName, isDirectory: true)
                if files.fileExists(atPath: legacy.path) {
                    try files.moveItem(at: legacy, to: current)
                    break
                }
            }
        }
        return current
    }
}
