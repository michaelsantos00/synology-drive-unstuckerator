import DriveMonitorCore
import Foundation

/// Dependencies are explicit so integration tests never open the production store or run a provider command.
enum ManualRequeueAction {
    struct Environment: Sendable {
        var onProgress: @Sendable (FindingSnapshot) async -> Void = { _ in }
        var operations: RepairOperationStore
        var access: RepairAccess
        var stagingRoot: URL
        var undoRoot: URL
        var runner: any CommandRunning = ProcessCommandRunner()
        var effects: RequeueEffects = .system()
        var maxPolls = 240
        var pollInterval: Duration = .seconds(15)
        var writeProbe: @Sendable (String) async -> Bool? = { path in
            try? await SystemOpenWriteProbe().isOpenForWriting(path: path)
        }
        var availableBytes: @Sendable (URL) throws -> Int64 = {
            try $0.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
        }
    }

    static func perform(id: UUID, repository: FindingRepository, environment: Environment,
                        mode: RequeueMode = .manual,
                        automaticAllowed: @escaping @Sendable () async -> Bool = { false }) async throws -> FindingSnapshot {
        guard let finding = try await repository.finding(id: id) else {
            throw MonitoringError.blocked(reason: "That finding is no longer available.")
        }
        return try await environment.access.withAccess(to: finding.canonicalPath) {
            try await performLocked(id: id, repository: repository, environment: environment,
                                    mode: mode, automaticAllowed: automaticAllowed)
        }
    }

    private static func performLocked(id: UUID, repository: FindingRepository, environment env: Environment,
                                      mode: RequeueMode,
                                      automaticAllowed: @escaping @Sendable () async -> Bool) async throws -> FindingSnapshot {
        guard var finding = try await repository.finding(id: id) else {
            throw MonitoringError.blocked(reason: "That finding is no longer available.")
        }
        let sourceURL = URL(fileURLWithPath: finding.canonicalPath)
        var automaticRoot: WatchedRootSnapshot?
        if mode == .automatic {
            automaticRoot = try await repository.roots().first { $0.id == finding.rootIdentifier }
            guard let root = automaticRoot, root.enabled, root.automaticRequeueEnabled,
                  let baseline = root.baselineCompletedAt, finding.firstDetectedAt >= baseline,
                  !AutomaticRepairCoordinator.predatesReview(finding, root: root),
                  sourceURL.path.hasPrefix(root.path + "/"), root.minimumStableAge.isFinite,
                  root.minimumStableAge >= 0, Date().timeIntervalSince(finding.modificationDate) >= root.minimumStableAge,
                  finding.disposition == .actionable, finding.confirmationCount >= 2,
                  finding.attemptCount == 0, !finding.hasRepairEvidence,
                  // Durable evidence outlives finding rows; unreadable records throw and block.
                  !AutomaticRepairCoordinator.hasOperation(for: finding, in: try env.operations.records()),
                  await automaticAllowed() else {
                throw MonitoringError.blocked(reason: "Auto-fix requires an enabled folder, a reviewed baseline, and a new confirmed failure while monitoring is running.")
            }
        }
        let initial = finding
        let persist: @Sendable (RequeueJournal) async throws -> Void = { incoming in
            let record = enriched(incoming, fallback: initial)
            try env.operations.save(record)
            if let snapshot = record.finding {
                try await repository.upsert(snapshot)
                await env.onProgress(snapshot)
            }
        }
        if let completed = try env.operations.records().first(where: { $0.finding?.id == finding.id && $0.phase == .succeeded }) {
            return try await verifyFinalPlacement(completed, fallback: finding, repository: repository, environment: env)
        }
        if let record = try env.operations.pending(path: finding.canonicalPath) {
            // A different row/version cannot take ownership of an existing operation.
            guard record.finding?.id == finding.id,
                  [.published, .verifying, .uploadAcknowledged].contains(record.phase) else {
                return try await recovery(finding, message: "An interrupted repair already owns this path. Review its retained files.", repository: repository)
            }
            let report = await RequeueExecutor.verify(record: record, effects: env.effects,
                evaluate: { try await evaluatedOutput($0, runner: env.runner) },
                maxPolls: env.maxPolls, pollInterval: env.pollInterval, persist: persist)
            return try await finish(finding, report: report, repository: repository, environment: env)
        }
        let known = try await repository.findings(at: finding.canonicalPath)
        guard !finding.hasRepairEvidence,
              !known.contains(where: { $0.canonicalPath == finding.canonicalPath && $0.id != id && $0.hasRepairEvidence && ![.requeueSucceeded, .resolved, .ignored].contains($0.disposition) }) else {
            return try await recovery(finding, message: "This retry was created without complete repair evidence. Review the existing files; no new copy was made.", repository: repository)
        }
        guard ManualRepairEligibility.canStart(finding) else {
            throw MonitoringError.blocked(reason: "This source version is not ready for a new repair.")
        }
        let live = try FileIntegrity.sourceVersion(sourceURL)
        guard finding.inode == live.inode, finding.fileSize == live.fileSize,
              abs(finding.modificationDate.timeIntervalSince(live.modificationTime)) < 1 else {
            return try await recovery(finding, message: "The original changed after confirmation. No copy was made.", repository: repository)
        }
        let output = try await evaluatedOutput(finding.canonicalPath, runner: env.runner)
        guard case .item(let item) = FileProviderParser.parse(output), FileProviderParser.isActionablePermanentFailure(item) else {
            throw MonitoringError.blocked(reason: "A local, downloaded file with a current permanent upload failure is required.")
        }
        guard let open = await env.writeProbe(sourceURL.path) else {
            throw MonitoringError.blocked(reason: "Could not safely determine whether the file is open for writing.")
        }
        try FileManager.default.createDirectory(at: env.stagingRoot, withIntermediateDirectories: true)
        let target = sourceURL.deletingLastPathComponent()
        let sameVolume = try volumeToken(sourceURL) == volumeToken(env.stagingRoot)
        let context = RequeueContext(mode: mode, operationID: UUID(), source: live,
            observedSource: try FileIntegrity.sourceVersion(sourceURL), confirmed: true, isLocal: item.isDownloaded == true,
            openForWriting: open, retryAlreadyActive: false, attemptCount: finding.attemptCount,
            availableBytes: try env.availableBytes(sourceURL), sameVolume: sameVolume,
            cloneValidated: sameVolume && probeClone(in: env.stagingRoot), monitoringPaused: false,
            providerAvailable: true, providerCompatible: true,
            disposition: finding.disposition == .observing ? .existingNeedsReview : finding.disposition,
            baselineCompleted: automaticRoot?.baselineCompletedAt != nil, automaticEnabled: automaticRoot?.automaticRequeueEnabled == true,
            stem: sourceURL.deletingPathExtension().lastPathComponent,
            fileExtension: sourceURL.pathExtension, now: Date(), takenNames: siblingNames(in: target))
        let decision = RequeuePlanner.decide(context)
        guard case .publish(let plan) = decision else {
            if case .blocked(let reason) = decision { finding.eligibilityBlockReason = RequeueExplanation.message(reason) }
            try await repository.upsert(finding)
            return finding
        }
        let report = await RequeueExecutor.publish(decision: decision, plan: plan, sourceURL: sourceURL,
            stagingRoot: env.stagingRoot, targetDirectory: target, openForWriting: open, effects: env.effects,
            evaluate: { try await evaluatedOutput($0, runner: env.runner) },
            authorizePublication: {
                guard await env.writeProbe(sourceURL.path) == false else {
                    throw MonitoringError.blocked(reason: "The file is open for writing or the writer check could not be completed.")
                }
                if mode == .automatic {
                    guard await automaticAllowed(),
                          try await repository.roots().contains(where: { $0.id == initial.rootIdentifier && $0.enabled && $0.automaticRequeueEnabled }) else {
                        throw MonitoringError.blocked(reason: "Auto-fix was turned off or monitoring paused before publication.")
                    }
                }
            },
            authorizeFullCopy: {
                let assessment = DiskSpacePolicy().assess(available: try env.availableBytes(sourceURL),
                    sourceSize: live.fileSize, sameVolume: sameVolume, cloneValidated: false)
                if case .allowed = assessment { return true }
                throw MonitoringError.blocked(reason: "The clone failed and a full copy does not have sufficient free space.")
            },
            maxPolls: env.maxPolls, pollInterval: env.pollInterval, persist: persist)
        return try await finish(finding, report: report, repository: repository, environment: env)
    }

    private static func enriched(_ journal: RequeueJournal, fallback: FindingSnapshot) -> RequeueJournal {
        var result = journal
        result.updatedAt = Date()
        result.finding = FindingRequeue.snapshot(for: result, fallback: fallback)
        return result
    }

    private static func finish(_ initial: FindingSnapshot, report: ExecutionReport,
                               repository: FindingRepository, environment env: Environment) async throws -> FindingSnapshot {
        var finding = initial
        FindingRequeue.apply(report, to: &finding, previousDisposition: initial.disposition, now: Date())
        if case .uploaded = report.outcome, let last = report.journals.last {
            var record = enriched(last, fallback: initial)
            record.finalPathVerificationRequired = true
            guard await env.writeProbe(initial.canonicalPath) == false else {
                record.message = "Final placement waits until the original is closed for writing and the writer check succeeds."
                record = enriched(record, fallback: initial)
                try env.operations.save(record)
                let deferred = record.finding ?? finding
                try await repository.upsert(deferred)
                await env.onProgress(deferred)
                return deferred
            }
            let normalization = RetryFinalizer.system().finish(record: record, undoRoot: env.undoRoot) { journal in
                try env.operations.save(enriched(journal, fallback: initial))
            }
            switch normalization {
            case .replaced, .replacedWithWarning:
                guard let completed = try env.operations.records().first(where: { $0.id == record.id }), completed.phase == .succeeded else {
                    throw MonitoringError.blocked(reason: "Final placement could not be committed. Review Recovery.")
                }
                finding = try await verifyFinalPlacement(completed, fallback: initial, repository: repository, environment: env)
                if case .replacedWithWarning(_, let warning) = normalization { finding.eligibilityBlockReason = warning }
            case .leftInPlace(let reason), .originalRemoved(_, let reason):
                var recovery = try env.operations.records().first(where: { $0.id == record.id }) ?? record
                recovery.phase = .recoveryRequired; recovery.message = reason
                recovery = enriched(recovery, fallback: initial)
                try env.operations.save(recovery)
                finding = recovery.finding ?? finding
            }
        }
        try await repository.upsert(finding)
        // Background verification runs every few minutes; record outcomes, not each unchanged check.
        if finding.disposition != initial.disposition || finding.providerState != initial.providerState {
            try await repository.append(ActivityEvent(id: UUID(), timestamp: Date(),
                kind: finding.disposition == .requeueSucceeded ? .requeueSucceeded : .recovery,
                findingID: finding.id, summary: "\(finding.filename): \(finding.providerState)",
                details: finding.eligibilityBlockReason, result: finding.disposition.rawValue))
        }
        return finding
    }

    private static func verifyFinalPlacement(_ record: RequeueJournal, fallback: FindingSnapshot,
                                              repository: FindingRepository, environment env: Environment) async throws -> FindingSnapshot {
        var record = record
        if record.finalPathVerifiedAt == nil {
            do {
                let path = URL(fileURLWithPath: record.source.canonicalPath)
                let before = try FileIntegrity.identity(path)
                let output = try await evaluatedOutput(path.path, runner: env.runner)
                let parsed = FileProviderParser.parse(output)
                let classification = EvaluationClassification.classify(parsed)
                if case .permanentFailure(let domain, let code) = classification {
                    // The replacement is in place but stuck under its final name. No further copy is made;
                    // the original stays archived for Undo, and later checks may still see it upload.
                    record.finalPathError = "\(domain) \(code)"
                    throw FinalNameFailure()
                }
                // Only a healthy upload state clears the failure; a missing or paused item says nothing new.
                if [.uploaded, .uploading, .notUploaded].contains(classification) { record.finalPathError = nil }
                guard case .item(let item) = parsed,
                      classification == .uploaded,
                      item.documentSize == nil || item.documentSize == before.fileSize,
                      let digest = record.retrySHA256,
                      try await env.effects.hashFile(path) == digest,
                      try FileIntegrity.identity(path).sameContentMetadata(as: before) else {
                    throw MonitoringError.blocked(reason: "The final filename has not acknowledged the verified replacement uploaded.")
                }
                record.finalPathVerifiedAt = Date()
                record.finalPathError = nil
                record.message = nil
                record.updatedAt = Date()
                record = enriched(record, fallback: fallback)
                try env.operations.save(record)
            } catch {
                if let failure = record.finalPathError {
                    record.message = "Synology reports the final filename failed to upload (\(failure)). No further copy was made; the original is kept for Undo."
                        + (error is FinalNameFailure ? "" : " The latest check did not finish: \(error.localizedDescription)")
                } else {
                    record.message = "Local placement completed. Final-name verification is pending: \(error.localizedDescription)"
                }
                record.updatedAt = Date()
                record = enriched(record, fallback: fallback)
                try env.operations.save(record)
            }
        }
        if record.finalPathVerifiedAt != nil, let archive = record.archiveID,
           UndoArchive.records(in: env.undoRoot).first(where: { $0.id == archive })?.purgeAllowed != true {
            do { try UndoArchive.armExpiry(id: archive, root: env.undoRoot) }
            catch {
                record.message = "Final filename reports uploaded. The retention update could not be confirmed; review the archive in Recovery."
                record = enriched(record, fallback: fallback)
                try env.operations.save(record)
            }
        }
        let result = FindingRequeue.snapshot(for: record, fallback: fallback)
        try await repository.upsert(result)
        await env.onProgress(result)
        return result
    }

    private static func recovery(_ initial: FindingSnapshot, message: String, repository: FindingRepository) async throws -> FindingSnapshot {
        var finding = initial
        finding.disposition = .recoveryRequired
        finding.providerState = "Recovery review required"
        finding.eligibilityBlockReason = message
        try await repository.upsert(finding)
        return finding
    }

    private static func evaluatedOutput(_ path: String, runner: any CommandRunning) async throws -> String {
        let result = try await runner.run(executable: URL(fileURLWithPath: "/usr/bin/fileproviderctl"), arguments: ["evaluate", path])
        guard result.exitCode == 0 else { throw MonitoringError.blocked(reason: "Provider evaluation failed (exit \(result.exitCode)).") }
        return result.standardOutput
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

}

/// Thrown when the final filename reports the permanent failure; its message is built from the record.
private struct FinalNameFailure: Error {}
