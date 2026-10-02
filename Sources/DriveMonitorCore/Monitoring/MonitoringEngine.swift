import Foundation
import Darwin

public struct EvaluationInterpreting: Sendable {
    public var parse: @Sendable (String) -> EvaluationParseResult
    public var classify: @Sendable (EvaluationParseResult) -> EvaluationClassification
    public var isActionablePermanentFailure: @Sendable (FileProviderItemState) -> Bool
    public var candidate: @Sendable (String, TimeInterval) -> CandidateDecision
    public var confirm: @Sendable (ConfirmationState?, ConfirmationObservation?, ConfirmationObservation, Bool) -> ConfirmationState

    public init(
        parse: @escaping @Sendable (String) -> EvaluationParseResult,
        classify: @escaping @Sendable (EvaluationParseResult) -> EvaluationClassification,
        isActionablePermanentFailure: @escaping @Sendable (FileProviderItemState) -> Bool,
        candidate: @escaping @Sendable (String, TimeInterval) -> CandidateDecision,
        confirm: @escaping @Sendable (ConfirmationState?, ConfirmationObservation?, ConfirmationObservation, Bool) -> ConfirmationState
    ) {
        self.parse = parse
        self.classify = classify
        self.isActionablePermanentFailure = isActionablePermanentFailure
        self.candidate = candidate
        self.confirm = confirm
    }
}

public enum MonitoringDecision: Equatable, Sendable {
    case evaluated
    case rejected(reason: String)
    case blocked(reason: String)
}

public enum MonitoringError: Error, LocalizedError, Sendable {
    case blocked(reason: String)
    public var errorDescription: String? {
        switch self { case .blocked(let reason): reason }
    }
}

public actor MonitoringEngine {
    public private(set) var isPaused = false
    public private(set) var lastScanAt: Date?
    public private(set) var lastError: String?
    public private(set) var unavailableRootIDs: Set<UUID> = []

    private let repairAccess: RepairAccess
    private let pendingRepair: @Sendable (String) throws -> Bool
    private let store: any FindingStoring
    private let saveRoot: @Sendable (WatchedRootSnapshot) async throws -> Void
    private let saveBaseline: (@Sendable (UUID, Date) async throws -> Void)?
    private let runner: any CommandRunning
    private let interpreting: EvaluationInterpreting
    private let watcherFactory: @Sendable () -> any DirectoryWatching
    private let debounce: Duration
    private let reconciliationInterval: Duration
    private let schedulesReconciliation: Bool
    private let now: @Sendable () -> Date
    private var roots: [WatchedRootSnapshot] = []
    private var watchingRootIDs: Set<UUID> = []
    private var watchers: [UUID: any DirectoryWatching] = [:]
    private var pending: [String: (id: UUID, task: Task<Void, Never>)] = [:]
    private var reconciliationTask: Task<Void, Never>?
    private var scanning = false
    private var evaluating: Set<String> = []
    private var followUps: [String: (id: UUID, task: Task<Void, Never>)] = [:]
    private var onPathChange: @Sendable (String) async -> Void = { _ in }
    private var onStoreChange: @Sendable () async -> Void = {}
    private var started = false
    private var generation = UUID()

    public init(
        store: any FindingStoring,
        repairAccess: RepairAccess = RepairAccess(),
        pendingRepair: @escaping @Sendable (String) throws -> Bool = { _ in false },
        saveRoot: @escaping @Sendable (WatchedRootSnapshot) async throws -> Void,
        saveBaseline: (@Sendable (UUID, Date) async throws -> Void)? = nil,
        runner: any CommandRunning,
        interpreting: EvaluationInterpreting,
        watcherFactory: @escaping @Sendable () -> any DirectoryWatching = { FSEventsDirectoryWatcher() },
        debounce: Duration = .seconds(2),
        reconciliationInterval: Duration = .seconds(300),
        schedulesReconciliation: Bool = true,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.repairAccess = repairAccess
        self.pendingRepair = pendingRepair
        self.store = store
        self.saveRoot = saveRoot
        self.saveBaseline = saveBaseline
        self.runner = runner
        self.interpreting = interpreting
        self.watcherFactory = watcherFactory
        self.debounce = max(debounce, .zero)
        self.reconciliationInterval = max(reconciliationInterval, .seconds(1))
        self.schedulesReconciliation = schedulesReconciliation
        self.now = now
    }

    public func cancelPendingFollowUps() {
        for work in followUps.values { work.task.cancel() }
        followUps.removeAll()
    }

    public func setPathChangeHandler(_ handler: @escaping @Sendable (String) async -> Void) { onPathChange = handler }

    public func setStoreChangeHandler(_ handler: @escaping @Sendable () async -> Void) {
        onStoreChange = handler
    }

    public static func validateConfiguration(_ roots: [WatchedRootSnapshot], allowUnavailable: Bool = false) throws {
        guard Set(roots.map(\.id)).count == roots.count else {
            throw MonitoringError.blocked(reason: "Watched root identifiers must be unique.")
        }
        for root in roots where root.enabled {
            do { try validateRoot(root) }
            catch let error as CocoaError where allowUnavailable {
                // Saved roots may be temporarily offline; explicit new settings remain strict.
                guard root.path.hasPrefix("/"), root.minimumStableAge.isFinite, root.minimumStableAge >= 0 else { throw error }
            }
        }
    }

    public func start(roots: [WatchedRootSnapshot], paused: Bool = false, persist: Bool = true, allowUnavailable: Bool = false) async throws {
        try Self.validateConfiguration(roots, allowUnavailable: allowUnavailable)
        stop()
        let startGeneration = generation
        guard Set(roots.map(\.id)).count == roots.count else {
            throw MonitoringError.blocked(reason: "Watched root identifiers must be unique.")
        }
        for root in roots where persist {
            try await saveRoot(root)
            guard generation == startGeneration else {
                throw MonitoringError.blocked(reason: "Monitoring configuration changed while roots were being saved.")
            }
        }
        self.roots = roots
        started = true
        isPaused = paused
        guard !paused else { return }
        do { try installWatchers(); scheduleReconciliation() }
        catch { stop(); throw error }
    }

    public func stop() {
        cancelScheduledWork()
        started = false
    }

    public func pause() {
        isPaused = true
        cancelScheduledWork()
    }

    public func resume() throws {
        guard started else { throw MonitoringError.blocked(reason: "Choose and confirm a watched folder first.") }
        guard isPaused else { return }
        try Self.validateConfiguration(roots, allowUnavailable: true)
        isPaused = false
        do { try installWatchers(); scheduleReconciliation(); Task { await scheduledReconcile() } }
        catch { pause(); throw error }
    }

    public func acknowledgeBaseline(rootID: UUID) async throws {
        guard var root = roots.first(where: { $0.id == rootID }) else {
            throw MonitoringError.blocked(reason: "The watched root is unavailable.")
        }
        guard root.baselineCompletedAt == nil else { return }
        root.baselineCompletedAt = now()
        // Persist before allowing any later evaluation to see an acknowledged baseline. Saving only the
        // date keeps a rules change made during this await from being overwritten by this older copy.
        if let saveBaseline, let date = root.baselineCompletedAt { try await saveBaseline(rootID, date) }
        else { try await saveRoot(root) }
        guard let index = roots.firstIndex(where: { $0.id == rootID && $0.path == root.path }) else {
            throw MonitoringError.blocked(reason: "The watched root changed during baseline acknowledgement.")
        }
        roots[index].baselineCompletedAt = root.baselineCompletedAt
        try await record(.baseline, summary: "First-launch baseline acknowledged.")
    }

    public func note(path: String) {
        guard started, !isPaused else { return }
        let path = URL(fileURLWithPath: path).standardizedFileURL.path
        pending[path]?.task.cancel()
        let id = UUID()
        let generation = generation
        let delay = debounce
        let task = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            await self?.consume(path: path, id: id, generation: generation)
        }
        pending[path] = (id, task)
    }

    @discardableResult
    public func handle(path: String) async throws -> MonitoringDecision {
        try await evaluate(path: path, manual: false)
    }

    @discardableResult
    public func evaluateFile(_ path: String) async throws -> MonitoringDecision {
        try await evaluate(path: path, manual: true)
    }

    @discardableResult
    public func evaluateFile(_ url: URL) async throws -> MonitoringDecision {
        try await evaluateFile(url.path)
    }

    public func reconcile() async throws {
        guard started, !isPaused else { return }
        try installWatchers()
        let checked = try await scanRecentFiles(manual: false)
        try await recheckKnownFailures(excluding: checked, manual: false)
    }

    public func scanNow() async throws {
        guard started else { throw MonitoringError.blocked(reason: "Choose and confirm a watched folder first.") }
        if !isPaused { try installWatchers() }
        let scanned = try await scanRecentFiles(manual: true)
        try await recheckKnownFailures(excluding: scanned, manual: true)
    }

    private func recheckKnownFailures(excluding scanned: Set<String>, manual: Bool) async throws {
        let scanGeneration = generation
        let unresolved = try await store.findings(matching: nil).filter { Self.isUnresolved($0.disposition) }
        var checked = scanned
        for finding in unresolved where !checked.contains(finding.canonicalPath) && !unavailableRootIDs.contains(finding.rootIdentifier) {
            guard started, !Task.isCancelled, manual || (!isPaused && generation == scanGeneration) else { break }
            checked.insert(finding.canonicalPath)
            _ = try await evaluate(path: finding.canonicalPath, manual: manual)
        }
    }

    /// Metadata walk of each watched tree. Only eligible files modified in the last seven days are evaluated.
    /// File contents are not opened, and older files are not sent to fileproviderctl.
    private func scanRecentFiles(manual: Bool) async throws -> Set<String> {
        guard !scanning else { throw MonitoringError.blocked(reason: "A scan is already running.") }
        scanning = true
        defer { scanning = false }
        let scanGeneration = generation
        let scanDate = now()
        let cutoff = scanDate.addingTimeInterval(-7 * 24 * 60 * 60)
        var evaluated: Set<String> = []
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey, .contentModificationDateKey]
        for root in roots where root.enabled {
            guard started, manual || (!isPaused && generation == scanGeneration) else { break }
            let discovery = CandidateDiscovery(root: root, cutoff: cutoff, scanDate: scanDate, keys: keys)
            do {
                while let candidates = try await discovery.nextBatch() {
                    guard started, !Task.isCancelled, manual || (!isPaused && generation == scanGeneration) else { break }
                    for url in candidates {
                        guard started, !Task.isCancelled, manual || (!isPaused && generation == scanGeneration) else { break }
                        let path = url.standardizedFileURL.path
                        guard evaluated.insert(path).inserted else { continue }
                        _ = try await evaluate(path: path, manual: manual)
                    }
                }
            } catch is CancellationError { throw CancellationError() }
            catch {
                unavailableRootIDs.insert(root.id)
                watchingRootIDs.remove(root.id)
                watchers.removeValue(forKey: root.id)?.stop()
                lastError = error.localizedDescription
                try await record(.compatibility, summary: "Watched folder scan unavailable.", details: lastError)
            }
        }

        guard started, generation == scanGeneration, !Task.isCancelled else { throw CancellationError() }
        lastScanAt = scanDate
        try await record(.scan, summary: "Recent-file scan completed.", details: "Seven-day window; \(evaluated.count) candidate paths inspected.")
        await onStoreChange()
        return evaluated
    }

    private func evaluate(path: String, manual: Bool) async throws -> MonitoringDecision {
        // Path rules need no lease. Checking them first keeps temporary and ineligible files from
        // leaving a lock file behind, and from triggering store refreshes, on every file event.
        if let rejection = pathRuleRejection(path) { return rejection }
        do {
            let decision = try await repairAccess.withAccess(to: path) {
                try await self.evaluateLocked(path: path, manual: manual)
            }
            // Consumers may start a repair in response; release the scan's path lease first.
            await onPathChange(path)
            await onStoreChange()
            return decision
        } catch RepairAccessError.busy {
            return .blocked(reason: "A check or repair already owns this path; the rest of the scan can continue.")
        }
    }

    /// The same path-only rules `evaluateLocked` applies, without touching the lease or the store.
    private func pathRuleRejection(_ path: String) -> MonitoringDecision? {
        guard path.hasPrefix("/") else { return .blocked(reason: "An absolute file path is required.") }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let canonical = url.resolvingSymlinksInPath().path
        guard let root = matchingRoot(path: canonical) else { return .blocked(reason: "The path is outside enabled watched roots.") }
        if case .reject(let reason) = interpreting.candidate(canonical, root.minimumStableAge) { return .rejected(reason: reason) }
        guard Self.extensionIsEligible(url, root: root), !Self.isIgnored(url, root: root) else {
            return .rejected(reason: "The extension or ignore rules exclude this path.")
        }
        return nil
    }

    private func evaluateLocked(path: String, manual: Bool) async throws -> MonitoringDecision {
        guard path.hasPrefix("/") else { return .blocked(reason: "An absolute file path is required.") }
        guard started, manual || !isPaused else { return .blocked(reason: "Monitoring is stopped or paused.") }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let canonical = url.resolvingSymlinksInPath().path
        guard let root = matchingRoot(path: canonical) else { return .blocked(reason: "The path is outside enabled watched roots.") }
        // Consult the injected candidate policy before even inspecting file metadata or running a command.
        if case .reject(let reason) = interpreting.candidate(canonical, root.minimumStableAge) {
            return .rejected(reason: reason)
        }
        guard Self.extensionIsEligible(url, root: root), !Self.isIgnored(url, root: root) else {
            return .rejected(reason: "The extension or ignore rules exclude this path.")
        }
        guard evaluating.insert(canonical).inserted else { return .blocked(reason: "An evaluation of this path is already in progress.") }
        defer { evaluating.remove(canonical) }
        let workGeneration = generation
        let all = try await store.findings(at: canonical)
        let previous = all.filter { $0.canonicalPath == canonical && $0.rootIdentifier == root.id }
            .sorted { $0.lastCheckedAt > $1.lastCheckedAt }
        guard !Task.isCancelled else { return .blocked(reason: "Evaluation canceled.") }
        guard try !pendingRepair(canonical), !previous.contains(where: {
            $0.hasRepairEvidence && ![.requeueSucceeded, .resolved, .ignored].contains($0.disposition)
        }) else { return .blocked(reason: "A repair owns this path. Use Check upload or Recovery.") }
        let metadata: FileMetadata
        do { metadata = try Self.metadata(url) }
        catch {
            if !FileManager.default.fileExists(atPath: canonical) {
                return try await retireMissing(path: canonical, root: root, previous: previous)
            }
            return try await block(path: canonical, root: root, metadata: nil, previous: previous.first,
                                   reason: "Source metadata cannot be verified: \(error.localizedDescription)", raw: nil)
        }
        guard metadata.canonicalPath == canonical else {
            return .blocked(reason: "The source path changed while its metadata was inspected.")
        }
        var existing = previous.first { metadata.matches($0) }
        // An export's unconfirmed observation follows the file as it grows. Repair evidence
        // and confirmed versions keep their identity and history instead of being rewritten.
        if existing == nil, let growing = previous.first(where: {
            $0.inode == metadata.inode && $0.disposition == .observing && !$0.hasRepairEvidence
                && $0.attemptCount == 0 && $0.confirmationCount == 0 && $0.errorCode == nil
        }) {
            var refreshed = metadata.finding(root: root, at: now())
            refreshed.id = growing.id
            refreshed.firstDetectedAt = growing.firstDetectedAt
            existing = refreshed
        }
        // Also reconcile duplicates saved by earlier builds, including while the file is
        // still young. Preserve those snapshots as history; never touch their media files.
        for var older in previous where older.id != existing?.id
            && Self.isUnresolved(older.disposition) && !older.hasRepairEvidence {
            older.disposition = .sourceChanged
            older.eligibilityBlockReason = "A newer observation tracks this path; this snapshot is retained as history."
            try await store.upsert(older)
        }
        if !manual, let existing, [.ignored, .resolved, .requeueSucceeded].contains(existing.disposition) {
            return .rejected(reason: "This source version has already been ignored or resolved.")
        }
        let age = now().timeIntervalSince(metadata.modified)
        if age < root.minimumStableAge {
            let reason = "This file is \(Int(age)) seconds old. Confirmation waits until it is \(Int(root.minimumStableAge)) seconds old so a file still being written is not treated as a failed upload."
            var finding = existing ?? metadata.finding(root: root, at: now())
            finding.lastCheckedAt = now()
            finding.providerState = "Waiting for a stable file"
            finding.eligibilityBlockReason = reason
            finding.disposition = .observing
            finding.confirmationCount = 0
            finding.lastConfirmedAt = nil
            finding.errorDomain = nil
            finding.errorCode = nil
            try await store.upsert(finding)
            scheduleFollowUp(path: canonical, after: .seconds(max(1, root.minimumStableAge - age + 1)))
            return .rejected(reason: reason)
        }
        guard started, manual || (!isPaused && generation == workGeneration), !Task.isCancelled else {
            return .blocked(reason: "Monitoring changed before evaluation could start.")
        }
        guard started, generation == workGeneration, !Task.isCancelled else {
            return .blocked(reason: "Monitoring changed before evaluation could start.")
        }
        let result: CommandResult
        do {
            result = try await runner.run(executable: URL(fileURLWithPath: "/usr/bin/fileproviderctl"),
                                          arguments: ["evaluate", canonical])
        } catch {
            guard started, generation == workGeneration, !Task.isCancelled else {
                return .blocked(reason: "Monitoring changed while evaluation was in progress.")
            }
            return try await block(path: canonical, root: root, metadata: metadata, previous: existing,
                                   reason: "Provider evaluation failed: \(error.localizedDescription)", raw: nil)
        }
        guard started, generation == workGeneration, !Task.isCancelled else {
            return .blocked(reason: "Monitoring changed while evaluation was in progress.")
        }
        guard let current = try? Self.metadata(url), current == metadata else {
            return try await block(path: canonical, root: root, metadata: metadata, previous: existing,
                                   reason: "The source version changed during evaluation.", raw: result.standardOutput)
        }
        guard result.exitCode == 0, !result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return try await block(path: canonical, root: root, metadata: metadata, previous: existing,
                                   reason: "Provider output is unreadable or the command failed (exit \(result.exitCode)).",
                                   raw: result.standardOutput + "\n" + result.standardError)
        }
        let parsed = interpreting.parse(result.standardOutput)
        let classification = interpreting.classify(parsed)
        if case .incompatible(let reason) = parsed {
            return try await block(path: canonical, root: root, metadata: metadata, previous: existing, reason: reason, raw: result.standardOutput)
        }
        if case .incompatible(let reason) = classification {
            return try await block(path: canonical, root: root, metadata: metadata, previous: existing, reason: reason, raw: result.standardOutput)
        }
        guard case .item(let item) = parsed else {
            return try await block(path: canonical, root: root, metadata: metadata, previous: existing,
                                   reason: "No provider item is available to verify this source.", raw: result.standardOutput)
        }
        // Respect local Ignore/Resolve changes made while the command was running.
        if let refreshed = try await store.findings(matching: nil).first(where: {
            $0.rootIdentifier == root.id && metadata.matches($0)
        }) { existing = refreshed }
        guard started, generation == workGeneration, !Task.isCancelled else {
            return .blocked(reason: "Monitoring changed while evaluation was in progress.")
        }
        let checkedAt = now()
        var finding = existing ?? metadata.finding(root: root, at: checkedAt)
        finding.lastCheckedAt = checkedAt
        finding.fileProviderItemIdentifier = item.itemIdentifier
        finding.rawDiagnostic = result.standardOutput
        finding.errorDomain = item.uploadingErrorDomain
        finding.errorCode = item.uploadingErrorCode
        let locallyClosed = [.ignored, .resolved, .requeueSucceeded].contains(finding.disposition)

        switch classification {
        case .uploaded:
            guard item.isUploaded == true, item.uploadingErrorDomain == nil,
                  item.uploadingErrorCode == nil, item.uploadingErrorRaw == nil else {
                return try await block(path: canonical, root: root, metadata: metadata, previous: existing,
                                       reason: "Uploaded status conflicts with the provider item or its upload error.", raw: result.standardOutput)
            }
            guard existing != nil else { return .evaluated }
            finding.providerState = "Synology reports uploaded"
            finding.uploadVerifiedAt = checkedAt
            finding.eligibilityBlockReason = nil
            if !locallyClosed { finding.disposition = .resolved }

        case .permanentFailure(let domain, let code):
            finding.providerState = "Permanent upload failure"
            guard domain == "NSFileProviderErrorDomain", code == -2005,
                  item.uploadingErrorDomain == domain, item.uploadingErrorCode == code,
                  item.isUploaded == false, item.isDownloaded == true,
                  item.isExcludedFromSync != true, item.isSyncPaused != true,
                  interpreting.isActionablePermanentFailure(item) else {
                finding.eligibilityBlockReason = "Permanent failure eligibility is blocked: the error, local download, or provider state could not be verified."
                finding.confirmationCount = 0
                finding.lastConfirmedAt = nil
                if !locallyClosed && finding.disposition != .existingNeedsReview { finding.disposition = .observing }
                try await store.upsert(finding)
                try await record(.requeueBlocked, findingID: finding.id, summary: "Failure confirmation blocked.", details: finding.eligibilityBlockReason)
                return .blocked(reason: finding.eligibilityBlockReason!)
            }
            let priorObservation = existing.flatMap { metadata.observation(from: $0) }
            let observation = ConfirmationObservation(path: canonical, inode: metadata.inode, fileSize: metadata.size,
                modificationTime: metadata.modified, classification: classification, checkedAt: checkedAt)
            let priorState = existing.map { ConfirmationState(disposition: $0.disposition, confirmationCount: $0.confirmationCount) }
            let baselineDate = roots.first(where: { $0.id == root.id })?.baselineCompletedAt
            let baselineComplete = baselineDate != nil
            // A temporary compatibility block must not erase a source version's baseline history.
            let predatesBaseline = existing.map { finding in
                baselineDate.map { finding.firstDetectedAt < $0 } ?? true
            } ?? false
            let proposed = interpreting.confirm(priorState, priorObservation, observation, baselineComplete)
            guard locallyClosed || [.observing, .existingNeedsReview, .actionable].contains(proposed.disposition) else {
                return try await block(path: canonical, root: root, metadata: metadata, previous: existing,
                    reason: "The confirmation policy returned an unsupported monitoring disposition.", raw: result.standardOutput)
            }
            let separated = priorObservation.map { checkedAt.timeIntervalSince($0.checkedAt) >= 60 } ?? false
            let safeCount = priorObservation == nil ? 1 : max(1, existing?.confirmationCount ?? 0) + (separated ? 1 : 0)
            finding.confirmationCount = min(max(0, proposed.confirmationCount), safeCount)
            if priorObservation == nil || separated { finding.lastConfirmedAt = checkedAt }
            if !locallyClosed {
                if finding.confirmationCount >= 2,
                   [.actionable, .existingNeedsReview].contains(proposed.disposition) {
                    finding.disposition = (existing?.disposition == .existingNeedsReview || predatesBaseline || !baselineComplete)
                        ? .existingNeedsReview : .actionable
                    finding.eligibilityBlockReason = finding.disposition == .existingNeedsReview
                        ? "This file was already failing when monitoring started. Fix publishes one verified copy."
                        : "Two confirmations agree. Fix publishes one verified copy."
                } else if let existing, existing.disposition == .actionable || existing.disposition == .existingNeedsReview {
                    finding.disposition = existing.disposition
                    finding.confirmationCount = max(finding.confirmationCount, existing.confirmationCount, 2)
                } else {
                    finding.disposition = .observing
                    finding.eligibilityBlockReason = "Two unchanged-source confirmations at least 60 seconds apart are required."
                }
            }
            if finding.disposition == .observing && finding.confirmationCount < 2 {
                scheduleFollowUp(path: canonical, after: .seconds(61))
            }

        case .uploading, .notUploaded, .excluded, .syncPaused, .missingItem, .uploadError:
            guard existing != nil else { return .evaluated }
            finding.providerState = Self.description(classification)
            finding.confirmationCount = 0
            finding.lastConfirmedAt = nil
            if case .uploadError = classification {
                finding.eligibilityBlockReason = "Synology reports a different upload error, often temporary (offline, storage full, or sign-in). It is not the stuck-upload failure Fix repairs; the file is checked again later."
            } else {
                finding.eligibilityBlockReason = "A current actionable permanent upload failure has not been confirmed."
            }
            if !locallyClosed && finding.disposition != .existingNeedsReview { finding.disposition = .observing }

        case .incompatible:
            return .blocked(reason: "Provider output is incompatible.")
        }
        try await store.upsert(finding)
        if existing == nil || existing?.disposition != finding.disposition || existing?.confirmationCount != finding.confirmationCount {
            try await record(existing == nil ? .findingDetected : .findingConfirmed, findingID: finding.id,
                             summary: "\(finding.filename): \(finding.providerState)", details: finding.eligibilityBlockReason,
                             result: finding.disposition.rawValue)
        }
        return .evaluated
    }

    /// Provider state of an observation retired because its file left the path.
    public static let movedOrDeletedState = "Moved or deleted"

    /// A moved or deleted file is not a provider problem. Blocking it would leave a permanent
    /// "cannot read" alert that is re-logged on every reconcile, so its observation becomes history.
    private func retireMissing(path: String, root: WatchedRootSnapshot, previous: [FindingSnapshot]) async throws -> MonitoringDecision {
        // An offline watched folder makes every file look missing; leave its rows alone.
        guard FileManager.default.fileExists(atPath: root.path) else {
            return .blocked(reason: "The watched folder is unavailable.")
        }
        // Repair evidence and ignore decisions keep their rows; other states describe a file that is gone.
        for var finding in previous where !finding.hasRepairEvidence
            && [.observing, .compatibilityBlocked, .actionable, .existingNeedsReview].contains(finding.disposition) {
            finding.disposition = .sourceChanged
            finding.lastCheckedAt = now()
            finding.providerState = Self.movedOrDeletedState
            finding.eligibilityBlockReason = "The file is no longer at this path. This observation is kept as history."
            try await store.upsert(finding)
            try await record(.lifecycle, findingID: finding.id, summary: "\(finding.filename): moved or deleted; kept as history.",
                             result: finding.disposition.rawValue)
        }
        return .rejected(reason: "The file is no longer at this path.")
    }

    private func block(path: String, root: WatchedRootSnapshot, metadata: FileMetadata?, previous: FindingSnapshot?, reason: String, raw: String?) async throws -> MonitoringDecision {
        var finding = previous ?? metadata?.finding(root: root, at: now()) ?? FindingSnapshot(
            id: UUID(), canonicalPath: path, filename: URL(fileURLWithPath: path).lastPathComponent,
            rootIdentifier: root.id, fileSize: 0, modificationDate: .distantPast, firstDetectedAt: now(),
            lastCheckedAt: now(), providerState: "Source metadata unavailable", confirmationCount: 0,
            attemptCount: 0, disposition: .compatibilityBlocked)
        if ![.ignored, .resolved, .requeueSucceeded].contains(finding.disposition) { finding.disposition = .compatibilityBlocked }
        finding.lastCheckedAt = now()
        finding.providerState = "Verification blocked"
        finding.eligibilityBlockReason = reason.isEmpty ? "Provider output cannot be interpreted safely." : reason
        finding.errorDomain = nil
        finding.errorCode = nil
        finding.confirmationCount = 0
        finding.lastConfirmedAt = nil
        finding.rawDiagnostic = raw
        try await store.upsert(finding)
        try await record(.compatibility, findingID: finding.id, summary: "Verification blocked for \(finding.filename).", details: finding.eligibilityBlockReason)
        return .blocked(reason: finding.eligibilityBlockReason!)
    }

    private func scheduleFollowUp(path: String, after delay: Duration) {
        followUps[path]?.task.cancel()
        let id = UUID()
        let generation = generation
        let task = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            await self?.runFollowUp(path: path, id: id, generation: generation)
        }
        followUps[path] = (id, task)
    }

    private func runFollowUp(path: String, id: UUID, generation: UUID) async {
        guard followUps[path]?.id == id else { return }
        followUps[path] = nil
        guard started, !isPaused, !Task.isCancelled, self.generation == generation else { return }
        do { _ = try await handle(path: path) }
        catch { await reportBackgroundFailure(error, path: path) }
    }

    /// Event-driven checks have no caller to show an error to; Activity is where it can be seen.
    private func reportBackgroundFailure(_ error: Error, path: String) async {
        guard !(error is CancellationError) else { return }
        lastError = error.localizedDescription
        try? await record(.compatibility, summary: "A background check of \(URL(fileURLWithPath: path).lastPathComponent) did not finish.",
                          details: error.localizedDescription)
        await onStoreChange()
    }

    private func matchingRoot(path: String) -> WatchedRootSnapshot? {
        roots.filter { $0.enabled && path.hasPrefix(URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path + "/") }
            .max { $0.path.count < $1.path.count }
    }

    private func record(_ kind: ActivityKind, findingID: UUID? = nil, summary: String, details: String? = nil, result: String? = nil) async throws {
        try await store.append(ActivityEvent(id: UUID(), timestamp: now(), kind: kind, findingID: findingID,
                                             summary: summary, details: details, result: result))
    }

    private func consume(path: String, id: UUID, generation: UUID) async {
        guard started, !isPaused, self.generation == generation, pending[path]?.id == id else { return }
        pending[path] = nil
        do { _ = try await handle(path: path) }
        catch { await reportBackgroundFailure(error, path: path) }
    }

    private func installWatchers() throws {
        let generation = generation
        for root in roots where root.enabled && !watchingRootIDs.contains(root.id) {
            do { try Self.validateRoot(root) }
            catch let error as CocoaError {
                unavailableRootIDs.insert(root.id)
                lastError = "Watched folder unavailable: \(root.displayName). \(error.localizedDescription)"
                continue
            }
            let watcher = watcherFactory()
            do {
                try watcher.start(root: URL(fileURLWithPath: root.path)) { [weak self] path in
                    Task { await self?.acceptEvent(path: path, generation: generation) }
                }
            } catch {
                watcher.stop()
                unavailableRootIDs.insert(root.id)
                lastError = "Watched folder events unavailable: \(root.displayName). \(error.localizedDescription)"
                continue
            }
            unavailableRootIDs.remove(root.id)
            watchingRootIDs.insert(root.id)
            watchers[root.id] = watcher
        }
    }

    private func acceptEvent(path: String, generation: UUID) {
        guard self.generation == generation else { return }
        if roots.contains(where: { $0.path == path }) { requestReconciliation() }
        else { note(path: path) }
    }

    private var eventReconcileTask: Task<Void, Never>?
    public func requestReconciliation() {
        guard started, !isPaused, eventReconcileTask == nil else { return }
        let expected = generation
        eventReconcileTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            await self?.reconcileEvent(expected)
        }
    }
    private func reconcileEvent(_ expected: UUID) async {
        defer { eventReconcileTask = nil }
        guard generation == expected, !Task.isCancelled else { return }
        await scheduledReconcile()
    }

    private func scheduleReconciliation() {
        guard schedulesReconciliation else { return }
        let interval = reconciliationInterval
        reconciliationTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                guard !Task.isCancelled else { return }
                await self?.scheduledReconcile()
            }
        }
    }

    private func scheduledReconcile() async {
        do { try await reconcile() }
        catch is CancellationError { return }
        catch {
            lastError = error.localizedDescription
            do { try await record(.compatibility, summary: "Scheduled reconciliation was blocked.", details: lastError) }
            catch { lastError = error.localizedDescription }
        }
    }

    private func cancelScheduledWork() {
        generation = UUID()
        for work in pending.values { work.task.cancel() }
        pending.removeAll()
        for work in followUps.values { work.task.cancel() }
        followUps.removeAll()
        reconciliationTask?.cancel()
        reconciliationTask = nil
        eventReconcileTask?.cancel()
        eventReconcileTask = nil
        for watcher in watchers.values { watcher.stop() }
        watchers.removeAll()
        watchingRootIDs.removeAll()
        unavailableRootIDs.removeAll()
    }

    deinit {
        reconciliationTask?.cancel()
        for work in pending.values { work.task.cancel() }
        for work in followUps.values { work.task.cancel() }
        for watcher in watchers.values { watcher.stop() }
    }

    private actor CandidateDiscovery {
        private let root: WatchedRootSnapshot
        private let cutoff: Date
        private let scanDate: Date
        private let keys: Set<URLResourceKey>
        private var enumerator: FileManager.DirectoryEnumerator?
        private var initialized = false
        init(root: WatchedRootSnapshot, cutoff: Date, scanDate: Date, keys: Set<URLResourceKey>) {
            self.root = root; self.cutoff = cutoff; self.scanDate = scanDate; self.keys = keys
        }
        func nextBatch() throws -> [URL]? {
            try Task.checkCancellation()
            if !initialized {
                let url = URL(fileURLWithPath: root.path)
                guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                    throw MonitoringError.blocked(reason: "Watched folder is unavailable: \(root.displayName)")
                }
                enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles, .skipsPackageDescendants])
                guard enumerator != nil else { throw MonitoringError.blocked(reason: "Watched folder cannot be scanned: \(root.displayName)") }
                initialized = true
            }
            guard let enumerator else { return nil }
            var matches: [URL] = []
            var inspected = 0
            while inspected < 128, let url = enumerator.nextObject() as? URL {
                inspected += 1
                try Task.checkCancellation()
                if url.pathComponents.contains(".git") { enumerator.skipDescendants(); continue }
                guard let values = try? url.resourceValues(forKeys: keys) else { continue }
                if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                guard MonitoringEngine.extensionIsEligible(url, root: root), !MonitoringEngine.isIgnored(url, root: root),
                      values.isDirectory != true, values.isRegularFile == true, values.isSymbolicLink == false,
                      let date = values.contentModificationDate, date >= cutoff, date <= scanDate else { continue }
                matches.append(url)
            }
            if inspected == 0 { self.enumerator = nil; return nil }
            return matches
        }
    }

    private static func validateRoot(_ root: WatchedRootSnapshot) throws {
        guard root.path.hasPrefix("/"), root.minimumStableAge.isFinite, root.minimumStableAge >= 0 else {
            throw MonitoringError.blocked(reason: "The watched root path or minimum stable age is invalid.")
        }
        let url = URL(fileURLWithPath: root.path)
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink == false else {
            throw MonitoringError.blocked(reason: "The watched root must be an existing, non-symbolic-link directory.")
        }
        if FileManager.default.fileExists(atPath: url.resolvingSymlinksInPath().appendingPathComponent(".git").path) {
            throw MonitoringError.blocked(reason: "A repository cannot be a watched root.")
        }
    }

    private static func extensionIsEligible(_ url: URL, root: WatchedRootSnapshot) -> Bool {
        root.extensions.contains { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased() == url.pathExtension.lowercased() }
    }

    private static func isIgnored(_ url: URL, root: WatchedRootSnapshot) -> Bool {
        if url.pathComponents.contains(".git") { return true }
        return root.ignorePatterns.contains { pattern in
            fnmatch(pattern, url.lastPathComponent, 0) == 0 || fnmatch(pattern, url.path, 0) == 0
        }
    }

    private static func isUnresolved(_ disposition: FindingDisposition) -> Bool {
        ![.resolved, .ignored, .requeueSucceeded, .sourceChanged].contains(disposition)
    }

    private static func description(_ classification: EvaluationClassification) -> String {
        switch classification {
        case .uploaded: "Synology reports uploaded"
        case .uploading: "Uploading"
        case .notUploaded: "Not uploaded"
        case .excluded: "Excluded from sync"
        case .syncPaused: "Sync paused"
        case .missingItem: "Provider item unavailable"
        case .permanentFailure: "Permanent upload failure"
        case .uploadError(let domain, let code): "Upload error (\(domain) \(code))"
        case .incompatible: "Verification blocked"
        }
    }

    private struct FileMetadata: Equatable {
        var canonicalPath: String
        var inode: UInt64
        var size: Int64
        var modified: Date

        func matches(_ finding: FindingSnapshot) -> Bool {
            finding.canonicalPath == canonicalPath && finding.inode == inode && finding.fileSize == size
                && abs(finding.modificationDate.timeIntervalSince(modified)) < 1
        }

        func finding(root: WatchedRootSnapshot, at date: Date) -> FindingSnapshot {
            FindingSnapshot(id: UUID(), canonicalPath: canonicalPath, filename: URL(fileURLWithPath: canonicalPath).lastPathComponent,
                rootIdentifier: root.id, inode: inode, fileSize: size, modificationDate: modified, firstDetectedAt: date,
                lastCheckedAt: date, providerState: "Awaiting confirmation", confirmationCount: 0, attemptCount: 0, disposition: .observing)
        }

        func observation(from finding: FindingSnapshot) -> ConfirmationObservation? {
            guard matches(finding), finding.confirmationCount > 0, let confirmedAt = finding.lastConfirmedAt,
                  finding.errorDomain == "NSFileProviderErrorDomain", finding.errorCode == -2005 else { return nil }
            return ConfirmationObservation(path: canonicalPath, inode: inode, fileSize: size, modificationTime: modified,
                classification: .permanentFailure(domain: "NSFileProviderErrorDomain", code: -2005), checkedAt: confirmedAt)
        }
    }

    private static func metadata(_ url: URL) throws -> FileMetadata {
        // A new URL avoids reusing Foundation's cached resource values across evaluations.
        let freshURL = URL(fileURLWithPath: url.path)
        let values = try freshURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
        guard values.isRegularFile == true, values.isSymbolicLink == false,
              let size = values.fileSize, let modified = values.contentModificationDate,
              let inode = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber else {
            throw MonitoringError.blocked(reason: "A regular local file with a known inode, size, and modification time is required.")
        }
        return FileMetadata(canonicalPath: url.resolvingSymlinksInPath().path, inode: inode.uint64Value, size: Int64(size), modified: modified)
    }
}

/// Production-only read-only command runner. Tests inject their own CommandRunning fixture.
public struct ProcessCommandRunner: CommandRunning {
    public init() {}

    public func run(executable: URL, arguments: [String]) async throws -> CommandResult {
        guard executable.path == "/usr/bin/fileproviderctl", arguments.count == 2,
              arguments[0] == "evaluate", arguments[1].hasPrefix("/") else {
            throw MonitoringError.blocked(reason: "Only an explicit read-only provider evaluation is supported.")
        }
        return try await BoundedProcess.run(executable: executable, arguments: arguments, timeout: 60)
    }
}
