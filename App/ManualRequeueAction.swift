import DriveMonitorCore
import Foundation

/// Manual Fix. Re-checks the provider before copying, and a later attempt verifies an already published sibling.
enum ManualRequeueAction {
    static func perform(id: UUID, repository: FindingRepository) async throws -> FindingSnapshot {
        let known = try await repository.findings(matching: nil)
        guard var finding = known.first(where: { $0.id == id }) else {
            throw MonitoringError.blocked(reason: "That finding is no longer available.")
        }
        let previousDisposition = finding.disposition
        let sourceURL = URL(fileURLWithPath: finding.canonicalPath)
        let live = try liveIdentity(sourceURL)
        let recorded = SourceVersionKey(
            canonicalPath: live.canonicalPath,
            inode: finding.inode ?? live.inode,
            fileSize: finding.fileSize,
            modificationTime: finding.modificationDate
        )
        let sameVersion = (finding.inode == nil || finding.inode == live.inode)
            && finding.fileSize == live.fileSize
            && abs(finding.modificationDate.timeIntervalSince(live.modificationTime)) < 1
        if finding.disposition == .requeueUploading, let retryPath = finding.retryPath {
            return try await resumeVerification(finding: finding, retryPath: retryPath, live: live, repository: repository)
        }
        switch try await currentClassification(of: finding.canonicalPath) {
        case .permanentFailure:
            break
        case .incompatible:
            return try await stop(finding, reason: RequeueExplanation.message(.incompatibleProviderOutput), repository: repository)
        default:
            return try await stop(
                finding,
                reason: "Synology no longer reports a permanent upload failure for this file. No copy was made.",
                repository: repository
            )
        }
        let writeProbe = probeOpenForWriting(sourceURL.path)
        if case .unknown(let reason) = writeProbe {
            return try await stop(finding, reason: reason, repository: repository)
        }
        let stagingRoot = try supportDirectory("Staging")
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        let targetDirectory = sourceURL.deletingLastPathComponent()
        let sameVolume = try volumeToken(sourceURL) == volumeToken(stagingRoot)
        let cloneValidated = sameVolume && probeClone(in: stagingRoot)
        let available = try sourceURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage ?? 0
        let context = RequeueContext(
            mode: .manual,
            operationID: UUID(),
            source: recorded,
            observedSource: sameVersion ? recorded : live,
            confirmed: true,
            isLocal: true,
            openForWriting: writeProbe == .open,
            retryAlreadyActive: false,
            attemptCount: finding.attemptCount,
            availableBytes: available,
            sameVolume: sameVolume,
            cloneValidated: cloneValidated,
            monitoringPaused: false,
            providerAvailable: true,
            providerCompatible: true,
            disposition: previousDisposition == .observing && finding.errorCode == -2005
                ? .existingNeedsReview
                : previousDisposition,
            baselineCompleted: false,
            automaticEnabled: false,
            stem: sourceURL.deletingPathExtension().lastPathComponent,
            fileExtension: sourceURL.pathExtension,
            now: Date(),
            takenNames: siblingNames(in: targetDirectory)
        )
        let decision = RequeuePlanner.decide(context)
        guard case .publish(let plan) = decision else {
            if case .blocked(let reason) = decision {
                finding.eligibilityBlockReason = RequeueExplanation.message(reason)
                finding.providerState = "Requeue stopped before copying"
                finding.lastCheckedAt = Date()
                try await repository.upsert(finding)
                try await repository.append(ActivityEvent(
                    id: UUID(), timestamp: Date(), kind: .requeueBlocked, findingID: finding.id,
                    summary: "\(finding.filename): requeue stopped before copying.",
                    details: finding.eligibilityBlockReason
                ))
            }
            return finding
        }
        let runner = ProcessCommandRunner()
        let publishedSnapshot = finding
        let report = await RequeueExecutor.publish(
            decision: decision,
            plan: plan,
            sourceURL: sourceURL,
            stagingRoot: stagingRoot,
            targetDirectory: targetDirectory,
            openForWriting: context.openForWriting,
            effects: .system(),
            evaluate: { path in
                try await evaluatedOutput(path, runner: runner)
            },
            maxPolls: 240,
            pollInterval: .seconds(15),
            onPublished: { path in
                var current = publishedSnapshot
                current.retryPath = path
                current.disposition = .requeueUploading
                current.providerState = "Waiting for Synology to report the retry uploaded"
                current.eligibilityBlockReason = "The complete retry copy is in the folder. The original file was not changed."
                try? await repository.upsert(current)
            }
        )
        return try await finish(
            finding,
            report: report,
            previousDisposition: previousDisposition,
            live: live,
            sourceURL: sourceURL,
            repository: repository
        )
    }

    /// A later Fix of a file that already has a published sibling only checks that sibling.
    private static func resumeVerification(
        finding: FindingSnapshot,
        retryPath: String,
        live: SourceVersionKey,
        repository: FindingRepository
    ) async throws -> FindingSnapshot {
        guard FileManager.default.fileExists(atPath: retryPath) else {
            return try await stop(
                finding,
                reason: "The published retry is no longer at the recorded path. No new copy was made.",
                repository: repository,
                disposition: .requeueFailed
            )
        }
        let runner = ProcessCommandRunner()
        var outcome: ExecutionOutcome = .verifying
        var identifier: String?
        for attempt in 0..<240 {
            if attempt > 0 { try await Task.sleep(for: .seconds(15)) }
            let output = try await evaluatedOutput(retryPath, runner: runner)
            switch EvaluationClassification.classify(FileProviderParser.parse(output)) {
            case .uploaded:
                if case .item(let item) = FileProviderParser.parse(output) { identifier = item.itemIdentifier }
                outcome = .uploaded(itemIdentifier: identifier)
            case .permanentFailure(_, let code):
                outcome = .retryFailed(code: code)
            case .incompatible:
                outcome = .blocked(.incompatibleProviderOutput)
            case .excluded, .syncPaused, .uploading, .notUploaded, .missingItem:
                continue
            }
            if case .verifying = outcome { continue }
            break
        }
        let report = ExecutionReport(
            outcome: outcome,
            journals: [RequeueJournal(
                id: UUID(),
                phase: outcome == .verifying ? .verifying : .succeeded,
                source: live,
                stagedPath: nil,
                publishedPath: retryPath,
                updatedAt: Date()
            )]
        )
        return try await finish(finding, report: report, previousDisposition: finding.disposition, live: live, sourceURL: URL(fileURLWithPath: finding.canonicalPath), repository: repository)
    }

    private static func currentClassification(of path: String) async throws -> EvaluationClassification {
        let output = try await evaluatedOutput(path, runner: ProcessCommandRunner())
        return EvaluationClassification.classify(FileProviderParser.parse(output))
    }

    private static func evaluatedOutput(_ path: String, runner: ProcessCommandRunner) async throws -> String {
        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/fileproviderctl"),
            arguments: ["evaluate", path]
        )
        guard result.exitCode == 0 else {
            throw MonitoringError.blocked(reason: "Provider evaluation failed (exit \(result.exitCode)).")
        }
        return result.standardOutput
    }

    private static func stop(
        _ finding: FindingSnapshot,
        reason: String,
        repository: FindingRepository,
        disposition: FindingDisposition? = nil
    ) async throws -> FindingSnapshot {
        var finding = finding
        if let disposition { finding.disposition = disposition }
        finding.eligibilityBlockReason = reason
        finding.providerState = "Requeue stopped before copying"
        finding.lastCheckedAt = Date()
        try await repository.upsert(finding)
        try await repository.append(ActivityEvent(
            id: UUID(), timestamp: Date(), kind: .requeueBlocked, findingID: finding.id,
            summary: "\(finding.filename): requeue stopped before copying.",
            details: reason
        ))
        return finding
    }

    private static func finish(
        _ finding: FindingSnapshot,
        report: ExecutionReport,
        previousDisposition: FindingDisposition,
        live: SourceVersionKey,
        sourceURL: URL,
        repository: FindingRepository
    ) async throws -> FindingSnapshot {
        var finding = finding
        let finished = Date()
        FindingRequeue.apply(report, to: &finding, previousDisposition: previousDisposition, now: finished)
        if case .uploaded = report.outcome, let retryPath = finding.retryPath {
            let undoRoot = try UndoArchive.supportRoot()
            var finalizer = RetryFinalizer.system()
            let findingID = finding.id
            finalizer.remove = { url in
                _ = try UndoArchive.store(file: url, findingID: findingID, root: undoRoot)
            }
            let normalization = finalizer.finish(
                original: sourceURL,
                retry: URL(fileURLWithPath: retryPath),
                expectedInode: live.inode,
                expectedSize: live.fileSize,
                expectedModified: live.modificationTime
            )
            switch normalization {
            case .replaced(let finalURL):
                finding.canonicalPath = finalURL.path
                finding.filename = finalURL.lastPathComponent
                finding.retryPath = finalURL.path
                finding.providerState = "Synology reports the replacement uploaded"
                finding.eligibilityBlockReason = "The uploaded copy uses the original name. Undo can restore the previous file for 6 hours."
            case .leftInPlace(let reason):
                finding.eligibilityBlockReason = reason
            case .originalRemoved(let retryURL, let reason):
                finding.retryPath = retryURL.path
                finding.providerState = "Uploaded copy kept under the retry name"
                finding.eligibilityBlockReason = reason
            }
        }
        try await repository.upsert(finding)
        try await repository.append(ActivityEvent(
            id: UUID(), timestamp: finished, kind: activityKind(report.outcome), findingID: finding.id,
            summary: "\(finding.filename): \(finding.providerState)",
            details: finding.eligibilityBlockReason,
            result: finding.disposition.rawValue
        ))
        return finding
    }

    private static func liveIdentity(_ url: URL) throws -> SourceVersionKey {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard values.isRegularFile == true,
              let size = values.fileSize,
              let modified = values.contentModificationDate,
              let inode = attributes[.systemFileNumber] as? NSNumber else {
            throw MonitoringError.blocked(reason: "The original file is not a local regular file.")
        }
        return SourceVersionKey(
            canonicalPath: url.resolvingSymlinksInPath().path,
            inode: inode.uint64Value,
            fileSize: Int64(size),
            modificationTime: modified
        )
    }

    private static func supportDirectory(_ name: String) throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent(AppStorage.folderName, isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }

    private static func volumeToken(_ url: URL) throws -> String {
        let values = try url.resourceValues(forKeys: [.volumeIdentifierKey])
        if let identifier = values.volumeIdentifier {
            return String(describing: identifier)
        }
        return url.path
    }

    private static func probeClone(in directory: URL) -> Bool {
        let effects = RequeueEffects.system()
        let source = directory.appendingPathComponent(".clone-probe-\(UUID().uuidString)")
        let destination = directory.appendingPathComponent(".clone-probe-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }
        do {
            try Data([0]).write(to: source)
            return try effects.cloneFile(source, destination)
        } catch {
            return false
        }
    }

    private static func siblingNames(in directory: URL) -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return Set(names)
    }

    private enum WriteProbe: Equatable {
        case closed
        case open
        case unknown(String)
    }

    /// Reads lsof output before waiting, so a full pipe cannot deadlock the probe.
    /// An unreadable result blocks Fix. It is not treated as "nothing has the file open."
    private static func probeOpenForWriting(_ path: String) -> WriteProbe {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-F", "a", "--", path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do { try process.run() }
        catch { return .unknown("Could not check whether the file is open for writing.") }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else {
            return .unknown("Could not read the open-file check.")
        }
        if process.terminationStatus != 0 && text.isEmpty { return .closed }
        for line in text.split(separator: "\n") where line.hasPrefix("a") {
            let mode = line.dropFirst()
            if mode.contains("w") || mode.contains("u") { return .open }
        }
        return .closed
    }

    private static func activityKind(_ outcome: ExecutionOutcome) -> ActivityKind {
        switch outcome {
        case .uploaded: .requeueSucceeded
        case .retryFailed, .blocked: .requeueFailed
        case .verifying: .requeueStarted
        }
    }
}
