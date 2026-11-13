import Foundation

public enum RecoveryChoice: Equatable, Sendable {
    case keepCurrentOriginal
    case restoreArchivedOriginal
}

/// Explicit recovery choices preserve every retained payload and release ownership durably.
public struct RepairRecovery: Sendable {
    public let operations: RepairOperationStore
    public let access: RepairAccess
    public let undoRoot: URL

    public init(operations: RepairOperationStore, access: RepairAccess, undoRoot: URL) {
        self.operations = operations; self.access = access; self.undoRoot = undoRoot
    }

    public func undo(_ finding: FindingSnapshot) async throws -> FindingSnapshot {
        try await access.withAccess(to: finding.canonicalPath) {
            guard try operations.pending(path: finding.canonicalPath).map({ $0.phase == .succeeded }) ?? true,
                  let archive = UndoArchive.restorableRecord(findingID: finding.id, root: undoRoot),
                  let operationID = archive.operationID,
                  var record = try operations.records().first(where: { $0.id == operationID && $0.phase == .succeeded }) else {
                throw MonitoringError.blocked(reason: "This archive needs recovery review before it can be restored.")
            }
            var intent = record
            intent.phase = .recoveryRequired; intent.message = "Undo started; review recovery if interrupted."
            let undoIntent = intent
            do {
                _ = try UndoArchive.restore(archive, root: undoRoot) { try operations.save(undoIntent) }
            } catch {
                if var interrupted = try operations.records().first(where: { $0.id == record.id && $0.phase == .recoveryRequired }) {
                    interrupted.message = error.localizedDescription
                    interrupted.finding = FindingRequeue.snapshot(for: interrupted, fallback: finding)
                    try operations.save(interrupted)
                }
                throw error
            }
            record.phase = .undone; record.message = "Original restored. Retained copies remain in Recovery."
            record.updatedAt = Date()
            var result = FindingRequeue.snapshot(for: record, fallback: finding)
            let restored = try FileIntegrity.identity(URL(fileURLWithPath: finding.canonicalPath))
            result.inode = restored.inode
            result.fileSize = restored.fileSize
            result.modificationDate = restored.modificationTime
            record.finding = result
            // The closed row keeps the repair evidence, which hides it from monitoring and Fix. As with
            // Keep Current Original, the restored file gets a fresh observation so it is checked again.
            record.nextFinding = FindingSnapshot(id: UUID(), canonicalPath: finding.canonicalPath, filename: finding.filename,
                rootIdentifier: finding.rootIdentifier, inode: restored.inode, fileSize: restored.fileSize,
                modificationDate: restored.modificationTime, firstDetectedAt: Date(), lastCheckedAt: Date(),
                providerState: "Original restored; awaiting a fresh provider check", confirmationCount: 0, attemptCount: 0,
                disposition: .observing)
            try operations.save(record)
            return result
        }
    }

    /// Closes a repair that stopped before publication. Its private staged copy, if any, moves into retained storage,
    /// and the operation is detached from rows. It never owned the path, so no row or newer operation changes.
    public func closeStopped(operationID: UUID) async throws {
        guard let record = try operations.records().first(where: { $0.id == operationID }), record.phase == .failed else {
            throw MonitoringError.blocked(reason: "Only a repair that stopped before publication can be closed this way.")
        }
        try await access.withAccess(to: record.source.canonicalPath) { try closeStopped(record) }
    }

    private func closeStopped(_ stopped: RequeueJournal) throws {
        var record = stopped
        if let staged = record.stagedPath, FileManager.default.fileExists(atPath: staged) {
            _ = try UndoArchive.store(file: URL(fileURLWithPath: staged), findingID: nil, root: undoRoot, operationID: record.id)
        }
        record.phase = .ignored
        record.message = "The stopped repair was reviewed. Any staged copy was moved to retained storage."
        record.updatedAt = Date()
        // Detached, so relaunch never restores this older snapshot over the row's current state.
        record.finding = nil
        try operations.save(record)
    }

    public func resolve(_ finding: FindingSnapshot, choice: RecoveryChoice) async throws -> FindingSnapshot {
        try await access.withAccess(to: finding.canonicalPath) {
            let original = URL(fileURLWithPath: finding.canonicalPath)
            let records = try operations.records()
            var record: RequeueJournal
            // A row can have more than one operation (a stopped attempt, then a later one). Resolve an interrupted one
            // first, otherwise the newest; an older stopped attempt is closed from its own row (closeStopped).
            let candidates = records.filter { $0.finding?.id == finding.id }
            if let existing = candidates.first(where: { $0.phase == .recoveryRequired }) ?? candidates.first {
                record = existing
            } else {
                // Legacy evidence is sufficient for an explicit keep-current choice, never automatic finalization.
                record = RequeueJournal(id: UUID(), phase: .recoveryRequired,
                    source: SourceVersionKey(canonicalPath: finding.canonicalPath, inode: finding.inode ?? 0,
                        fileSize: finding.fileSize, modificationTime: finding.modificationDate),
                    publishedPath: finding.retryPath, updatedAt: Date())
                record.finding = finding
            }
            // Recovery choices are for an operation that still needs a decision. A completed repair keeps its Undo; a
            // closed one has nothing left to resolve.
            guard ![.ignored, .undone].contains(record.phase), record.phase != .succeeded || record.requiresRecovery else {
                throw MonitoringError.blocked(reason: "This repair is complete or already closed; there is nothing to resolve.")
            }
            // A repair that stopped before publication never owned the path. Once its row has moved on (Check Again),
            // or the original is gone or no longer a file, there is nothing to keep or restore: close it alone.
            let originalIsFile = (try? FileIntegrity.identity(original))?.exists == true
            if record.phase == .failed, finding.disposition != .requeueFailed || !originalIsFile {
                guard choice == .keepCurrentOriginal else {
                    throw MonitoringError.blocked(reason: "This stopped repair has no archived original to restore.")
                }
                try closeStopped(record)
                return finding
            }
            guard !records.contains(where: { $0.id != record.id && $0.source.canonicalPath == finding.canonicalPath && $0.requiresRecovery }) else {
                throw MonitoringError.blocked(reason: "Another unresolved operation owns this path. Review that operation first.")
            }
            let archiveToRestore: UndoRecord?
            if choice == .restoreArchivedOriginal {
                guard !(try FileIntegrity.identity(original)).exists,
                      let archiveID = record.archiveID,
                      let archive = UndoArchive.records(in: undoRoot).first(where: { $0.id == archiveID && $0.operationID == record.id }),
                      let digest = record.sourceSHA256, archive.archivedSHA256 == digest,
                      try FileIntegrity.sha256(UndoArchive.payloadURL(archive, root: undoRoot)) == digest else {
                    throw MonitoringError.blocked(reason: "A verified archive and an empty original path are required. Reveal the files to review them manually.")
                }
                archiveToRestore = archive
            } else {
                guard (try FileIntegrity.identity(original)).exists else {
                    throw MonitoringError.blocked(reason: "The original path is empty. Restore the archived original or choose a file in Finder before resuming monitoring.")
                }
                archiveToRestore = nil
            }
            // An inapplicable choice above changes neither the phase nor Check upload eligibility.
            record.phase = .recoveryRequired
            record.message = "Recovery review started. Retained copies will be archived; none will be deleted."
            if let archiveToRestore {
                let intent = record
                _ = try UndoArchive.restore(archiveToRestore, root: undoRoot, requireEmptyDestination: true) { try operations.save(intent) }
            } else {
                try operations.save(record)
            }
            let paths = Set([record.publishedPath, record.stagedPath].compactMap { $0 })
            for path in paths where path != original.path {
                let retained = URL(fileURLWithPath: path)
                guard FileManager.default.fileExists(atPath: retained.path) else { continue }
                try FileIntegrity.coordinated(original: original, retry: retained) { original, retained in
                    guard (try FileIntegrity.identity(original)).exists else { throw RetryFinalizerError.unreadable(original.path) }
                    _ = try UndoArchive.store(file: retained, findingID: nil, root: undoRoot, operationID: record.id)
                }
            }
            // The user's current original remains in place; pending retry/staging payloads are now in recovery storage.
            record.phase = .ignored; record.updatedAt = Date()
            record.message = "Recovery reviewed. The current original was kept, retained copies were archived, and monitoring can continue."
            let closed = FindingRequeue.snapshot(for: record, fallback: finding)
            record.finding = closed
            let current = try FileIntegrity.sourceVersion(original)
            let result = FindingSnapshot(id: UUID(), canonicalPath: current.canonicalPath, filename: original.lastPathComponent,
                rootIdentifier: finding.rootIdentifier, inode: current.inode, fileSize: current.fileSize,
                modificationDate: current.modificationTime, firstDetectedAt: Date(), lastCheckedAt: Date(),
                providerState: "Recovery reviewed; awaiting a fresh provider check", confirmationCount: 0, attemptCount: 0,
                disposition: .observing)
            // Keep the new observation in the journal until its finding row has been durably created.
            record.nextFinding = result
            try operations.save(record)
            return result
        }
    }
}
