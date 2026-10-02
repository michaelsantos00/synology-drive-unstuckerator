import Foundation

public enum RetryNormalization: Equatable, Sendable {
    case replaced(URL)
    case replacedWithWarning(URL, String)
    case leftInPlace(String)
    case originalRemoved(retryURL: URL, reason: String)
}

public struct RetryFileIdentity: Equatable, Codable, Sendable {
    public var exists: Bool
    public var inode: UInt64
    public var fileSize: Int64
    public var modificationTime: Date
    public var device: UInt64?
    public var changeTime: Date?

    public func sameContentMetadata(as other: RetryFileIdentity) -> Bool {
        exists == other.exists && inode == other.inode && fileSize == other.fileSize && device == other.device
            && abs(modificationTime.timeIntervalSince(other.modificationTime)) < 0.000001
    }

    public init(exists: Bool, inode: UInt64, fileSize: Int64, modificationTime: Date,
                device: UInt64? = nil, changeTime: Date? = nil) {
        self.exists = exists
        self.inode = inode
        self.fileSize = fileSize
        self.modificationTime = modificationTime
        self.device = device
        self.changeTime = changeTime
    }
}

/// No destructive default: every original is archived, with durable evidence before each move.
public struct RetryFinalizer: Sendable {
    public var armExpiry: @Sendable (UUID, URL) throws -> Void = { try UndoArchive.armExpiry(id: $0, root: $1) }
    public var move: @Sendable (URL, URL) throws -> Void = FileIntegrity.moveExclusively
    public init() {}
    public static func system() -> RetryFinalizer { RetryFinalizer() }

    public func finish(record: RequeueJournal, undoRoot: URL,
                       persist: @Sendable (RequeueJournal) throws -> Void) -> RetryNormalization {
        let original = URL(fileURLWithPath: record.source.canonicalPath)
        guard let retryPath = record.publishedPath,
              record.phase == .uploadAcknowledged, record.uploadVerifiedAt != nil,
              let sourceHash = record.sourceSHA256, let retryHash = record.retrySHA256,
              sourceHash == retryHash, let expectedRetry = record.retryIdentity else {
            return .leftInPlace("Repair evidence is incomplete. Review the retained files before continuing.")
        }
        let retry = URL(fileURLWithPath: retryPath)
        guard original.standardizedFileURL != retry.standardizedFileURL else {
            return .leftInPlace("The original and retry paths must be different.")
        }
        var journal = record
        do {
            return try FileIntegrity.coordinated(original: original, retry: retry) { original, retry in
                let sourceIdentity = try FileIntegrity.identity(original)
                guard FileIntegrity.matches(sourceIdentity, source: record.source),
                      try FileIntegrity.identity(retry).sameContentMetadata(as: expectedRetry),
                      sourceIdentity.inode != expectedRetry.inode,
                      try FileIntegrity.sha256(original) == sourceHash,
                      try FileIntegrity.sha256(retry) == retryHash,
                      try FileIntegrity.identity(original).sameContentMetadata(as: sourceIdentity),
                      try FileIntegrity.identity(retry).sameContentMetadata(as: expectedRetry) else {
                    return .leftInPlace("A file changed after publication or verification. Both versions were kept for review.")
                }
                let archiveID = UUID()
                journal.archiveID = archiveID
                journal.phase = .archiving
                journal.updatedAt = Date()
                try persist(journal)
                _ = try UndoArchive.store(file: original, findingID: record.finding?.id, root: undoRoot,
                    id: archiveID, operationID: record.id, expectedReplacementSHA256: retryHash,
                    archivedSHA256: sourceHash)
                journal.phase = .archived
                try persist(journal)
                // A crash here intentionally requires recovery; never infer permission from a missing path.
                guard !(try FileIntegrity.identity(original)).exists,
                      try FileIntegrity.identity(retry).sameContentMetadata(as: expectedRetry),
                      try FileIntegrity.sha256(retry) == retryHash else {
                    throw RetryFinalizerError.destinationOccupied(original.path)
                }
                journal.phase = .finalizing
                try persist(journal)
                try move(retry, original)
                guard try FileIntegrity.sha256(original) == retryHash else {
                    throw RetryFinalizerError.unreadable(original.path)
                }
                journal.phase = .succeeded
                journal.updatedAt = Date()
                try persist(journal)
                // New operations retain the original until the final filename is acknowledged.
                guard journal.finalPathVerificationRequired != true else { return .replaced(original) }
                do { try armExpiry(archiveID, undoRoot) }
                catch {
                    return .replacedWithWarning(original, "Placement completed. The Undo expiry update could not be confirmed; review retention in Activity → Recovery.")
                }
                return .replaced(original)
            }
        } catch {
            let reason = "Final placement stopped: \(error.localizedDescription). Review the original, retry, and recovery archive."
            if record.archiveID != nil || journal.archiveID != nil {
                return .originalRemoved(retryURL: retry, reason: reason)
            }
            return .leftInPlace(reason)
        }
    }
}

public enum RetryFinalizerError: Error, Equatable {
    case unreadable(String)
    case destinationOccupied(String)
}
