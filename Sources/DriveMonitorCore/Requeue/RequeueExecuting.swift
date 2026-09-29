import CryptoKit
import Darwin
import Foundation

public enum ExecutionOutcome: Equatable, Sendable {
    case uploaded(itemIdentifier: String?)
    case retryFailed(code: Int)
    case blocked(RequeueBlockReason)
    case verifying
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
                if FileManager.default.fileExists(atPath: destination.path) {
                    throw RequeueIOError.destinationExists(destination.path)
                }
                try FileManager.default.moveItem(at: source, to: destination)
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
        decision: RequeueDecision,
        plan: PublicationPlan,
        sourceURL: URL,
        stagingRoot: URL,
        targetDirectory: URL,
        openForWriting: Bool,
        effects: RequeueEffects,
        evaluate: @escaping @Sendable (String) async throws -> String,
        maxPolls: Int = 1,
        pollInterval: Duration = .zero,
        onPublished: (@Sendable (String) async -> Void)? = nil
    ) async -> ExecutionReport {
        var journals: [RequeueJournal] = []
        let stagingDirectory = stagingRoot.appendingPathComponent(plan.operationID.uuidString, isDirectory: true)
        let stagedFile = stagingDirectory.appendingPathComponent(plan.retryFileName)
        let publishedFile = targetDirectory.appendingPathComponent(plan.retryFileName)

        func record(_ phase: RequeuePhase, staged: String? = nil, published: String? = nil) {
            journals.append(
                RequeueJournal(
                    id: plan.operationID,
                    phase: phase,
                    source: plan.source,
                    stagedPath: staged,
                    publishedPath: published,
                    updatedAt: Date()
                )
            )
        }

        guard case .publish(let allowed) = decision, allowed == plan else {
            record(.failed)
            return ExecutionReport(outcome: .blocked(.notConfirmed), journals: journals)
        }
        if openForWriting {
            record(.failed)
            return ExecutionReport(outcome: .blocked(.openForWriting), journals: journals)
        }

        record(.planned)
        do {
            record(.stagingPrepared, staged: stagingDirectory.path)
            try effects.makeDirectory(stagingDirectory)
            // The destination is the user's Synology folder. Creating it would republish into a folder they removed.
            guard effects.fileExists(targetDirectory) else {
                record(.failed, staged: stagingDirectory.path)
                return ExecutionReport(outcome: .blocked(.publishFailed(stagedPath: stagingDirectory.path)), journals: journals)
            }
            // The move that must stay on one volume is staged file → destination, not the original → its parent.
            let sameVolume = try effects.sameVolume(stagingDirectory, targetDirectory)
            if !sameVolume {
                record(.failed, staged: stagingDirectory.path)
                return ExecutionReport(outcome: .blocked(.crossVolume), journals: journals)
            }
            let cloned = try effects.cloneFile(sourceURL, stagedFile)
            if !cloned {
                guard plan.allowFullCopyFallback else {
                    record(.failed, staged: stagingDirectory.path)
                    return ExecutionReport(outcome: .blocked(.crossVolume), journals: journals)
                }
                try effects.copyFile(sourceURL, stagedFile)
            }
            record(.clonedOrCopied, staged: stagedFile.path)

            let sourceHash = try await effects.hashFile(sourceURL)
            let stagedHash = try await effects.hashFile(stagedFile)
            if sourceHash != stagedHash {
                record(.failed, staged: stagedFile.path)
                return ExecutionReport(outcome: .blocked(.hashMismatch), journals: journals)
            }
            record(.hashed, staged: stagedFile.path)

            if effects.fileExists(publishedFile) {
                record(.failed, staged: stagedFile.path)
                return ExecutionReport(outcome: .blocked(.publishFailed(stagedPath: stagedFile.path)), journals: journals)
            }
            try effects.moveFile(stagedFile, publishedFile)
            record(.published, staged: stagedFile.path, published: publishedFile.path)
            if let onPublished {
                await onPublished(publishedFile.path)
            }

            record(.verifying, published: publishedFile.path)
            for attempt in 0..<max(maxPolls, 0) {
                if attempt > 0, pollInterval > .zero {
                    try await Task.sleep(for: pollInterval)
                }
                try Task.checkCancellation()
                let output = try await evaluate(publishedFile.path)
                let parsed = FileProviderParser.parse(output)
                switch EvaluationClassification.classify(parsed) {
                case .uploaded:
                    let identifier: String?
                    if case .item(let item) = parsed {
                        identifier = item.itemIdentifier
                    } else {
                        identifier = nil
                    }
                    record(.succeeded, published: publishedFile.path)
                    return ExecutionReport(outcome: .uploaded(itemIdentifier: identifier), journals: journals)
                case .permanentFailure(_, let code):
                    record(.failed, published: publishedFile.path)
                    return ExecutionReport(outcome: .retryFailed(code: code), journals: journals)
                case .incompatible:
                    record(.failed, published: publishedFile.path)
                    return ExecutionReport(outcome: .blocked(.incompatibleProviderOutput), journals: journals)
                case .excluded, .syncPaused, .uploading, .notUploaded, .missingItem:
                    continue
                }
            }
            return ExecutionReport(outcome: .verifying, journals: journals)
        } catch {
            let stagedPath = effects.fileExists(stagedFile) ? stagedFile.path : stagingDirectory.path
            record(.failed, staged: stagedPath)
            return ExecutionReport(outcome: .blocked(.publishFailed(stagedPath: stagedPath)), journals: journals)
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
