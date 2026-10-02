import CryptoKit
import Darwin
import Foundation

public enum ExecutionOutcome: Equatable, Sendable {
    case uploaded(itemIdentifier: String?)
    case retryFailed(code: Int)
    case blocked(RequeueBlockReason)
    case verifying
    case verificationFailed(String)
    case recoveryRequired(String)
}

public struct ExecutionReport: Equatable, Sendable {
    public var outcome: ExecutionOutcome
    public var journals: [RequeueJournal]

    public init(outcome: ExecutionOutcome, journals: [RequeueJournal]) {
        self.outcome = outcome
        self.journals = journals
    }
}

public struct RequeueEffects: Sendable {
    public var sameVolume: @Sendable (URL, URL) throws -> Bool
    public var cloneFile: @Sendable (URL, URL) throws -> Bool
    public var copyFile: @Sendable (URL, URL) throws -> Void
    public var hashFile: @Sendable (URL) async throws -> String
    public var moveFile: @Sendable (URL, URL) throws -> Void
    public var fileExists: @Sendable (URL) -> Bool
    public var makeDirectory: @Sendable (URL) throws -> Void
    public var inode: @Sendable (URL) throws -> UInt64

    public init(
        sameVolume: @escaping @Sendable (URL, URL) throws -> Bool,
        cloneFile: @escaping @Sendable (URL, URL) throws -> Bool,
        copyFile: @escaping @Sendable (URL, URL) throws -> Void,
        hashFile: @escaping @Sendable (URL) async throws -> String,
        moveFile: @escaping @Sendable (URL, URL) throws -> Void,
        fileExists: @escaping @Sendable (URL) -> Bool,
        makeDirectory: @escaping @Sendable (URL) throws -> Void,
        inode: @escaping @Sendable (URL) throws -> UInt64
    ) {
        self.sameVolume = sameVolume
        self.cloneFile = cloneFile
        self.copyFile = copyFile
        self.hashFile = hashFile
        self.moveFile = moveFile
        self.fileExists = fileExists
        self.makeDirectory = makeDirectory
        self.inode = inode
    }

    public static func system() -> RequeueEffects {
        RequeueEffects(
            sameVolume: { source, destination in
                try FileIdentity.volumeToken(source) == FileIdentity.volumeToken(destination)
            },
            cloneFile: { source, destination in
                try FileIdentity.clone(source, to: destination)
            },
            copyFile: { source, destination in
                try FileManager.default.copyItem(at: source, to: destination)
            },
            hashFile: { url in
                try await FileIdentity.sha256(of: url)
            },
            moveFile: { source, destination in
                try FileIntegrity.moveExclusively(source, destination)
            },
            fileExists: { url in
                FileManager.default.fileExists(atPath: url.path)
            },
            makeDirectory: { url in
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            },
            inode: { url in
                try FileIdentity.inode(url)
            }
        )
    }
}

public enum RequeueIOError: Error, Equatable {
    case destinationExists(String)
    case cloneFailed
}

public enum RequeueExecutor {
    public static func publish(
        decision: RequeueDecision, plan: PublicationPlan, sourceURL: URL, stagingRoot: URL,
        targetDirectory: URL, openForWriting: Bool, effects: RequeueEffects,
        evaluate: @escaping @Sendable (String) async throws -> String,
        authorizePublication: @escaping @Sendable () async throws -> Void = {},
        authorizeFullCopy: (@Sendable () async throws -> Bool)? = nil,
        maxPolls: Int = 1, pollInterval: Duration = .zero,
        persist: @escaping @Sendable (RequeueJournal) async throws -> Void
    ) async -> ExecutionReport {
        var journals: [RequeueJournal] = []
        let stagingDirectory = stagingRoot.appendingPathComponent(plan.operationID.uuidString, isDirectory: true)
        let staged = stagingDirectory.appendingPathComponent(plan.retryFileName)
        let published = targetDirectory.appendingPathComponent(plan.retryFileName)
        var journal = RequeueJournal(id: plan.operationID, phase: .planned, source: plan.source, updatedAt: Date())
        func save(_ value: RequeueJournal) async throws {
            try await persist(value)
        }
        guard case .publish(let allowed) = decision, allowed == plan, !openForWriting else {
            return ExecutionReport(outcome: .blocked(openForWriting ? .openForWriting : .notConfirmed), journals: [])
        }
        do {
            try await save(journal); journals.append(journal)
            try Task.checkCancellation()
            let before = try FileIntegrity.identity(sourceURL)
            guard FileIntegrity.matches(before, source: plan.source) else {
                throw MonitoringError.blocked(reason: "The original changed before copying.")
            }
            journal.phase = .stagingPrepared; journal.stagedPath = staged.path
            try await save(journal); journals.append(journal)
            try effects.makeDirectory(stagingDirectory)
            guard effects.fileExists(targetDirectory) else { throw RequeueIOError.destinationExists(targetDirectory.path) }
            guard try effects.sameVolume(stagingDirectory, targetDirectory) else {
                journal.phase = .failed
                try await save(journal); journals.append(journal)
                return ExecutionReport(outcome: .blocked(.crossVolume), journals: journals)
            }
            if try !effects.cloneFile(sourceURL, staged) {
                if let authorizeFullCopy {
                    guard try await authorizeFullCopy() else { throw RequeueIOError.cloneFailed }
                } else if !plan.allowFullCopyFallback { throw RequeueIOError.cloneFailed }
                try effects.copyFile(sourceURL, staged)
            }
            journal.phase = .clonedOrCopied
            try await save(journal); journals.append(journal)
            let sourceHash = try await effects.hashFile(sourceURL)
            let stagedHash = try await effects.hashFile(staged)
            // Change time moves on metadata-only updates (the provider's own xattrs); bytes are proven by the hashes.
            guard sourceHash == stagedHash, try FileIntegrity.identity(sourceURL).sameContentMetadata(as: before) else {
                journal.phase = .failed
                try await save(journal); journals.append(journal)
                return ExecutionReport(outcome: .blocked(.hashMismatch), journals: journals)
            }
            journal.sourceSHA256 = sourceHash; journal.retrySHA256 = stagedHash
            journal.retryIdentity = try FileIntegrity.identity(staged)
            journal.phase = .hashed
            try await save(journal); journals.append(journal)
            try Task.checkCancellation()
            try await authorizePublication()
            guard !effects.fileExists(published) else { throw RequeueIOError.destinationExists(published.path) }
            journal.phase = .publishing; journal.publishedPath = published.path
            // Persist destination intent before the move, so a crash cannot lose the retry's path.
            try await save(journal); journals.append(journal)
            try effects.moveFile(staged, published)
            journal.retryIdentity = try FileIntegrity.identity(published)
            journal.phase = .published
            try await save(journal); journals.append(journal)
        } catch {
            let publishedOrUncertain = journal.phase == .publishing || journal.phase == .published
            let reason = "Repair stopped: \(error.localizedDescription). Retained files are available in Recovery."
            // Do not attempt another filesystem side effect after any persistence failure.
            journal.message = reason
            journal.phase = publishedOrUncertain ? .recoveryRequired : .failed
            do { try await save(journal) } catch { journal.message = reason + " The operation record could not be updated." }
            journals.append(journal)
            return ExecutionReport(outcome: publishedOrUncertain ? .recoveryRequired(journal.message ?? reason)
                : .blocked(.preparationFailed(reason: journal.message ?? reason)), journals: journals)
        }
        let verification = await verify(record: journal, effects: effects, evaluate: evaluate,
            maxPolls: maxPolls, pollInterval: pollInterval, persist: persist)
        return ExecutionReport(outcome: verification.outcome, journals: journals + verification.journals)
    }

    /// Also used after relaunch. The original commitment is never replaced with a fresh stat.
    public static func verify(record: RequeueJournal, effects: RequeueEffects,
        evaluate: @escaping @Sendable (String) async throws -> String,
        maxPolls: Int = 1, pollInterval: Duration = .zero,
        persist: @escaping @Sendable (RequeueJournal) async throws -> Void
    ) async -> ExecutionReport {
        var journal = record
        guard [.published, .verifying, .uploadAcknowledged].contains(record.phase),
              let path = record.publishedPath, var expected = record.retryIdentity,
              let hash = record.retrySHA256, hash == record.sourceSHA256 else {
            return ExecutionReport(outcome: .recoveryRequired("The saved retry evidence is incomplete. No new copy was made."), journals: [record])
        }
        let retry = URL(fileURLWithPath: path)
        do {
            let original = URL(fileURLWithPath: record.source.canonicalPath)
            let originalIdentity = try FileIntegrity.identity(original)
            guard FileIntegrity.matches(originalIdentity, source: record.source),
                  try await VerifiedDigests.shared.verify(original, identity: originalIdentity, digest: hash, effects: effects) else {
                journal.phase = .recoveryRequired
                journal.message = "The original changed or is missing. Both versions were kept for recovery."
                try await persist(journal)
                return ExecutionReport(outcome: .recoveryRequired(journal.message!), journals: [journal])
            }
            // Hash once before polling and again at acknowledgement. Waiting alone does not re-read GBs every 15 seconds,
            // and a later check of unchanged files reuses this process's earlier result.
            let retryIdentity = try FileIntegrity.identity(retry)
            guard retryIdentity.sameContentMetadata(as: expected),
                  try await VerifiedDigests.shared.verify(retry, identity: retryIdentity, digest: hash, effects: effects) else {
                journal.phase = .recoveryRequired
                journal.message = "The retry changed since publication. Review the retained versions."
                try await persist(journal)
                return ExecutionReport(outcome: .recoveryRequired(journal.message!), journals: [journal])
            }
            expected = try FileIntegrity.identity(retry)
            journal.retryIdentity = expected
            var lastUploadError: String?
            var consecutiveUploadErrors = 0
            polling: for attempt in 0..<max(0, maxPolls) {
                if attempt > 0, pollInterval > .zero { try await Task.sleep(for: pollInterval) }
                try Task.checkCancellation()
                let current = try FileIntegrity.identity(retry)
                guard current.sameContentMetadata(as: expected) else {
                    journal.phase = .recoveryRequired
                    journal.message = "The retry changed since publication. Review the retained versions."
                    try await persist(journal)
                    return ExecutionReport(outcome: .recoveryRequired(journal.message!), journals: [journal])
                }
                if current != expected {
                    guard try await effects.hashFile(retry) == hash,
                          try FileIntegrity.identity(retry).sameContentMetadata(as: current) else {
                        journal.phase = .recoveryRequired
                        journal.message = "The retry bytes changed. Review the retained versions."
                        try await persist(journal)
                        return ExecutionReport(outcome: .recoveryRequired(journal.message!), journals: [journal])
                    }
                    expected = try FileIntegrity.identity(retry)
                    journal.retryIdentity = expected
                    try await persist(journal)
                }
                let output = try await evaluate(path)
                let parsed = FileProviderParser.parse(output)
                switch EvaluationClassification.classify(parsed) {
                case .uploaded:
                    guard case .item(let item) = parsed,
                          item.documentSize == nil || item.documentSize == expected.fileSize,
                          try FileIntegrity.identity(retry).sameContentMetadata(as: expected),
                          try await effects.hashFile(retry) == hash,
                          try FileIntegrity.identity(retry).sameContentMetadata(as: expected) else {
                        throw MonitoringError.blocked(reason: "The upload response could not be bound to the committed retry version.")
                    }
                    journal.retryIdentity = try FileIntegrity.identity(retry)
                    journal.phase = .uploadAcknowledged; journal.uploadVerifiedAt = Date()
                    journal.retryItemIdentifier = item.itemIdentifier; journal.message = nil
                    try await persist(journal)
                    return ExecutionReport(outcome: .uploaded(itemIdentifier: item.itemIdentifier), journals: [journal])
                case .permanentFailure(_, let code):
                    journal.phase = .published; journal.message = "Synology reports the retry also failed. No additional copy was made."
                    try await persist(journal)
                    return ExecutionReport(outcome: .retryFailed(code: code), journals: [journal])
                case .incompatible:
                    throw MonitoringError.blocked(reason: "Provider output could not be interpreted safely.")
                case .uploadError(let domain, let code):
                    lastUploadError = "Synology reports upload error \(domain) \(code) for the retry. Waiting for it to clear; the original is still in place."
                    consecutiveUploadErrors += 1
                    // Offline or a full NAS can last hours. Stop holding this repair (which blocks others)
                    // and let the background checks, which back off, keep watching.
                    if consecutiveUploadErrors >= 4 { break polling }
                default:
                    lastUploadError = nil
                    consecutiveUploadErrors = 0
                }
            }
            journal.phase = .published; journal.message = lastUploadError
            try await persist(journal)
            return ExecutionReport(outcome: .verifying, journals: [journal])
        } catch {
            // Publication already happened. An evaluation or storage error never undoes that fact.
            if journal.phase != .recoveryRequired { journal.phase = .published }
            journal.message = "Upload verification is incomplete: \(error.localizedDescription)"
            do { try await persist(journal) } catch { journal.message! += " The operation record could not be updated." }
            return ExecutionReport(outcome: journal.phase == .recoveryRequired ? .recoveryRequired(journal.message!) : .verificationFailed(journal.message!), journals: [journal])
        }
    }
}

enum FileIdentity {
    static func volumeToken(_ url: URL) throws -> String {
        let values = try url.resourceValues(forKeys: [.volumeIdentifierKey])
        if let identifier = values.volumeIdentifier {
            return String(describing: identifier)
        }
        return url.path
    }

    static func clone(_ source: URL, to destination: URL) throws -> Bool {
        let result = source.withUnsafeFileSystemRepresentation { sourcePath in
            destination.withUnsafeFileSystemRepresentation { destinationPath in
                guard let sourcePath, let destinationPath else { return Int32(-1) }
                // CLONE_FORCE fails instead of silently copying. A full copy is a separate step, and only when the plan allows it.
        let flags = copyfile_flags_t(COPYFILE_CLONE | COPYFILE_CLONE_FORCE | COPYFILE_NOFOLLOW)
        return copyfile(sourcePath, destinationPath, nil, flags)
            }
        }
        return result == 0
    }

    static func sha256(of url: URL) async throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if chunk.isEmpty {
                break
            }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Stable file identity. `hashValue` is not an inode; it changes every process launch.
    static func inode(_ url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let number = attributes[.systemFileNumber] as? NSNumber else {
            throw RequeueIOError.cloneFailed
        }
        return number.uint64Value
    }
}

/// Digests already confirmed in this process, keyed by full identity including change time.
/// The kernel moves change time on every write and a writer cannot set it, so an identical
/// identity means the bytes were not rewritten. Only repeat pre-checks use this: acknowledgement,
/// finalization, and publication always read the bytes again.
final class VerifiedDigests: @unchecked Sendable {
    static let shared = VerifiedDigests()
    private let lock = NSLock()
    private var entries: [String: (identity: RetryFileIdentity, digest: String)] = [:]

    func verify(_ url: URL, identity: RetryFileIdentity, digest: String, effects: RequeueEffects) async throws -> Bool {
        let key = url.standardizedFileURL.path
        if identity.changeTime != nil, lock.withLock({ entries[key] }).map({ $0.identity == identity && $0.digest == digest }) == true {
            return true
        }
        guard try await effects.hashFile(url) == digest else {
            _ = lock.withLock { entries.removeValue(forKey: key) }
            return false
        }
        // Remember only an identity that held still while it was read.
        if identity.changeTime != nil, try FileIntegrity.identity(url) == identity {
            lock.withLock {
                if entries.count > 256 { entries.removeAll() }
                entries[key] = (identity, digest)
            }
        }
        return true
    }
}
