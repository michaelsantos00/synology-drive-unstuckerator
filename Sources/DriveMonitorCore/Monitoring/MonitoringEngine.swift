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

    private let store: any FindingStoring
    private let saveRoot: @Sendable (WatchedRootSnapshot) async throws -> Void
    private let runner: any CommandRunning
    private let interpreting: EvaluationInterpreting
    private let watcherFactory: @Sendable () -> any DirectoryWatching
    private let debounce: Duration
    private let reconciliationInterval: Duration
    private let schedulesReconciliation: Bool
    private let now: @Sendable () -> Date
    private var roots: [WatchedRootSnapshot] = []
    private var watchers: [any DirectoryWatching] = []
    private var pending: [String: (id: UUID, task: Task<Void, Never>)] = [:]
    private var reconciliationTask: Task<Void, Never>?
    private var evaluating: Set<String> = []
    private var followUps: [UUID: Task<Void, Never>] = [:]
    private var onStoreChange: @Sendable () async -> Void = {}
    private var started = false
    private var generation = UUID()

    public init(
        store: any FindingStoring,
        saveRoot: @escaping @Sendable (WatchedRootSnapshot) async throws -> Void,
        runner: any CommandRunning,
        interpreting: EvaluationInterpreting,
        watcherFactory: @escaping @Sendable () -> any DirectoryWatching = { FSEventsDirectoryWatcher() },
        debounce: Duration = .seconds(2),
        reconciliationInterval: Duration = .seconds(300),
        schedulesReconciliation: Bool = true,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.saveRoot = saveRoot
        self.runner = runner
        self.interpreting = interpreting
        self.watcherFactory = watcherFactory
        self.debounce = max(debounce, .zero)
        self.reconciliationInterval = max(reconciliationInterval, .seconds(1))
        self.schedulesReconciliation = schedulesReconciliation
        self.now = now
    }

    public func cancelPendingFollowUps() {
        for work in followUps.values { work.cancel() }
        followUps.removeAll()
    }

    public func setStoreChangeHandler(_ handler: @escaping @Sendable () async -> Void) {
        onStoreChange = handler
    }

    public func start(roots: [WatchedRootSnapshot]) async throws {
        stop()
        let startGeneration = generation
        guard Set(roots.map(\.id)).count == roots.count else {
            throw MonitoringError.blocked(reason: "Watched root identifiers must be unique.")
        }
        for root in roots where root.enabled { try Self.validateRoot(root) }
        for root in roots {
            try await saveRoot(root)
            guard generation == startGeneration else {
                throw MonitoringError.blocked(reason: "Monitoring configuration changed while roots were being saved.")
            }
        }
        self.roots = roots
        started = true
        isPaused = false
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
        for root in roots where root.enabled { try Self.validateRoot(root) }
        isPaused = false
        do { try installWatchers(); scheduleReconciliation() }
        catch { pause(); throw error }
    }

    public func acknowledgeBaseline(rootID: UUID) async throws {
        guard var root = roots.first(where: { $0.id == rootID }) else {
            throw MonitoringError.blocked(reason: "The watched root is unavailable.")
        }
        guard root.baselineCompletedAt == nil else { return }
        root.baselineCompletedAt = now()
        // Persist before allowing any later evaluation to see an acknowledged baseline.
        try await saveRoot(root)
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
        _ = try await scanRecentFiles(manual: false)
    }

    public func scanNow() async throws {
        guard started else { throw MonitoringError.blocked(reason: "Choose and confirm a watched folder first.") }
        let scanned = try await scanRecentFiles(manual: true)
        let unresolved = try await store.findings(matching: nil).filter { Self.isUnresolved($0.disposition) }
        var checked = scanned
        for finding in unresolved where !checked.contains(finding.canonicalPath) {
            checked.insert(finding.canonicalPath)
            _ = try await evaluateFile(finding.canonicalPath)
        }
    }

    /// Metadata walk of each watched tree. Only eligible files modified in the last seven days are evaluated.
    /// File contents are not opened, and older files are not sent to fileproviderctl.
    private func scanRecentFiles(manual: Bool) async throws -> Set<String> {
        let scanGeneration = generation
        let scanDate = now()
        let cutoff = scanDate.addingTimeInterval(-7 * 24 * 60 * 60)
        var evaluated: Set<String> = []
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey, .contentModificationDateKey]
        for root in roots where root.enabled {
            guard started, manual || (!isPaused && generation == scanGeneration) else { break }
            let candidates = Self.recentCandidates(root: root, cutoff: cutoff, scanDate: scanDate, keys: keys)
            for url in candidates {
                guard started, manual || (!isPaused && generation == scanGeneration) else { break }
                let path = url.standardizedFileURL.path
                guard evaluated.insert(path).inserted else { continue }
                _ = try await evaluate(path: path, manual: manual)
            }
        }
        lastScanAt = scanDate
        try await record(.scan, summary: "Recent-file scan completed.", details: "Seven-day window; \(evaluated.count) candidate paths inspected.")
        return evaluated
    }

    private func evaluate(path: String, manual: Bool) async throws -> MonitoringDecision {
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
        let all = try await store.findings(matching: nil)
        let previous = all.filter { $0.canonicalPath == canonical && $0.rootIdentifier == root.id }
            .sorted { $0.lastCheckedAt > $1.lastCheckedAt }
        let metadata: FileMetadata
        do { metadata = try Self.metadata(url) }
        catch {
            return try await block(path: canonical, root: root, metadata: nil, previous: previous.first,
                                   reason: "Source metadata cannot be verified: \(error.localizedDescription)", raw: nil)
        }
        guard metadata.canonicalPath == canonical else {
            return .blocked(reason: "The source path changed while its metadata was inspected.")
        }
        var existing = previous.first { metadata.matches($0) }
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
            finding.errorDomain = nil
            finding.errorCode = nil
            try await store.upsert(finding)
            await onStoreChange()
            scheduleFollowUp(path: canonical, after: .seconds(max(1, root.minimumStableAge - age + 1)))
            return .rejected(reason: reason)
        }
        guard started, manual || (!isPaused && generation == workGeneration), !Task.isCancelled else {
            return .blocked(reason: "Monitoring changed before evaluation could start.")
        }
        for var older in previous where !metadata.matches(older) && Self.isUnresolved(older.disposition) {
            older.disposition = .sourceChanged
            older.eligibilityBlockReason = "The source version changed; this finding no longer describes the current file."
            try await store.upsert(older)
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

        case .uploading, .notUploaded, .excluded, .syncPaused, .missingItem:
            guard existing != nil else { return .evaluated }
            finding.providerState = Self.description(classification)
            finding.confirmationCount = 0
            finding.lastConfirmedAt = nil
            finding.eligibilityBlockReason = "A current actionable permanent upload failure has not been confirmed."
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
        await onStoreChange()
        return .evaluated
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
        await onStoreChange()
        return .blocked(reason: finding.eligibilityBlockReason!)
    }

    private func scheduleFollowUp(path: String, after delay: Duration) {
        let id = UUID()
        let generation = generation
        let task = Task { [weak self] in
            try? await Task.sleep(for: delay)
            await self?.runFollowUp(path: path, id: id, generation: generation)
        }
        followUps[id] = task
    }

    private func runFollowUp(path: String, id: UUID, generation: UUID) async {
        followUps[id] = nil
        guard started, !isPaused, self.generation == generation else { return }
        do { _ = try await handle(path: path) }
        catch { lastError = error.localizedDescription }
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
        catch { lastError = error.localizedDescription }
    }

    private func installWatchers() throws {
        let generation = generation
        for root in roots where root.enabled {
            let watcher = watcherFactory()
            do {
                try watcher.start(root: URL(fileURLWithPath: root.path)) { [weak self] path in
                    Task { await self?.acceptEvent(path: path, generation: generation) }
                }
            } catch {
                watcher.stop()
                throw error
            }
            watchers.append(watcher)
        }
    }

    private func acceptEvent(path: String, generation: UUID) {
        guard self.generation == generation else { return }
        note(path: path)
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
        for work in followUps.values { work.cancel() }
        followUps.removeAll()
        reconciliationTask?.cancel()
        reconciliationTask = nil
        for watcher in watchers { watcher.stop() }
        watchers.removeAll()
    }

    deinit {
        reconciliationTask?.cancel()
        for work in pending.values { work.task.cancel() }
        for work in followUps.values { work.cancel() }
        for watcher in watchers { watcher.stop() }
    }

    private static func recentCandidates(root: WatchedRootSnapshot, cutoff: Date, scanDate: Date, keys: Set<URLResourceKey>) -> [URL] {
        let rootURL = URL(fileURLWithPath: root.path)
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var matches: [URL] = []
        for case let url as URL in enumerator {
            if url.pathComponents.contains(".git") {
                if url.lastPathComponent == ".git" { enumerator.skipDescendants() }
                continue
            }
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                enumerator.skipDescendants()
                continue
            }
            guard extensionIsEligible(url, root: root) else { continue }
            guard let values = try? url.resourceValues(forKeys: keys) else { continue }
            guard values.isDirectory != true, values.isRegularFile == true, values.isSymbolicLink == false else { continue }
            guard let date = values.contentModificationDate, date >= cutoff, date <= scanDate else { continue }
            matches.append(url)
        }
        return matches
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
        return try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce()
            DispatchQueue.global(qos: .utility).async {
                do {
                    once.finish(continuation, result: .success(try Self.runSynchronously(executable: executable, arguments: arguments)))
                } catch {
                    once.finish(continuation, result: .failure(error))
                }
            }
            // The child is left running. This app does not signal fileproviderd or the evaluate process.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 60) {
                once.finish(continuation, result: .failure(MonitoringError.blocked(reason: "Provider evaluation timed out.")))
            }
        }
    }

    private static func runSynchronously(executable: URL, arguments: [String]) throws -> CommandResult {
            let process = Process()
            let output = Pipe()
            let errors = Pipe()
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = output
            process.standardError = errors
            try process.run()
            let group = DispatchGroup()
            let capturedOutput = CapturedData()
            let capturedErrors = CapturedData()
            // Drain both pipes concurrently so large diagnostics cannot fill a pipe and deadlock.
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                capturedOutput.set(output.fileHandleForReading.readDataToEndOfFile())
                group.leave()
            }
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                capturedErrors.set(errors.fileHandleForReading.readDataToEndOfFile())
                group.leave()
            }
            process.waitUntilExit()
            group.wait()
            guard let stdout = String(data: capturedOutput.get(), encoding: .utf8) else {
                throw MonitoringError.blocked(reason: "Provider command output is not valid UTF-8.")
            }
            let stderr = String(decoding: capturedErrors.get(), as: UTF8.self)
            return CommandResult(exitCode: process.terminationStatus, standardOutput: stdout, standardError: stderr)
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    func finish(_ continuation: CheckedContinuation<CommandResult, Error>, result: Result<CommandResult, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        continuation.resume(with: result)
    }
}

private final class CapturedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ value: Data) { lock.withLock { data = value } }
    func get() -> Data { lock.withLock { data } }
}
