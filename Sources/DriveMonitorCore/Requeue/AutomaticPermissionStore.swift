import Foundation

/// A separate, fsynced revocation barrier. Configuration/engine failures must not
/// restore permission after the user has disabled automatic publication.
public struct AutomaticPermissionStore: Sendable {
    public let file: URL
    public init(root: URL) throws {
        let directory = root.standardizedFileURL.resolvingSymlinksInPath()
        guard !directory.pathComponents.contains("CloudStorage") else {
            throw MonitoringError.blocked(reason: "Automatic permission must be stored outside synced folders.")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = directory.appendingPathComponent("AutomaticPermission.json")
    }
    public func isRevoked() throws -> Bool {
        guard FileManager.default.fileExists(atPath: file.path) else { return false }
        return try JSONDecoder().decode(Bool.self, from: Data(contentsOf: file))
    }
    public func saveRevocation(_ revoked: Bool) throws {
        try DurableFile.write(JSONEncoder().encode(revoked), to: file)
    }
}
