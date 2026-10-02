import Foundation
import Testing
import DriveMonitorCore
@testable import DriveMonitorUI

@Suite struct ManualRepairTests {
    @Test @MainActor func obsoleteExportSnapshotsStayInHistoryWithoutDuplicatingTheQueue() {
        let current = sample(path: "/fixture/episode.mp4", inode: 1, size: 2613281739, modified: Date())
        var old = current
        old.id = UUID(); old.fileSize = 193399887; old.disposition = .sourceChanged
        let model = AppModel(); model.desktopNotificationsEnabled = false
        model.findings = [old, current]
        #expect(model.discoveredFindings.map(\.id) == [current.id])
        #expect(model.badgeCount == 1)
        #expect(ActivityFilter.earlier.includes(old))
    }

    @Test @MainActor func automaticRepairDispatchesOnceAndCompletesThroughRealPipeline() async throws {
        let fixture = try await Fixture(); defer { fixture.remove() }
        let (finding, root) = try await fixture.prepareAutomatic()
        await fixture.runner.setMode(.uploaded)
        var calls = 0
        var callbacks = MonitorCallbacks()
        callbacks.loadRoots = { [root] }
        callbacks.loadFindings = { [finding] }
        callbacks.start = { _ in }
        callbacks.scan = { [finding] }
        callbacks.automaticRequeue = { id, allowed in
            calls += 1
            return try await ManualRequeueAction.perform(id: id, repository: fixture.repository,
                environment: fixture.environment, mode: .automatic, automaticAllowed: allowed)
        }
        let model = AppModel(callbacks: callbacks); model.desktopNotificationsEnabled = false
        await model.restoreSavedMonitoring()
        for _ in 0..<500 where !model.requeueInFlight.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(calls == 1)
        #expect(model.findings.first?.disposition == .requeueSucceeded)
        #expect(try fixture.environment.operations.records().count == 1)
        model.applyStoreUpdate(findings: [finding], events: []) // repeated stale delivery must not re-dispatch
        await Task.yield()
        #expect(calls == 1)
    }

    @Test func automaticRepairChecksOptInBaselineStabilityAndPauseBeforeCopying() async throws {
        for condition in ["disabled", "baseline", "existing", "young", "paused", "oneConfirmation", "attempted"] {
            let fixture = try await Fixture(); defer { fixture.remove() }
            var (finding, root) = try await fixture.prepareAutomatic()
            switch condition {
            case "disabled": root.automaticRequeueEnabled = false
            case "baseline": root.baselineCompletedAt = nil
            case "existing": finding.disposition = .existingNeedsReview
            case "young": root.minimumStableAge = 300
            case "oneConfirmation": finding.confirmationCount = 1
            case "attempted": finding.attemptCount = 1
            default: break
            }
            try await fixture.repository.save(root: root)
            try await fixture.repository.upsert(finding)
            do {
                _ = try await ManualRequeueAction.perform(id: finding.id, repository: fixture.repository,
                    environment: fixture.environment, mode: .automatic, automaticAllowed: { condition != "paused" })
                Issue.record("Auto-fix should block \(condition)")
            } catch { /* Expected: no operation or copy may exist. */ }
            #expect(try fixture.environment.operations.records().isEmpty)
            #expect(await fixture.runner.count == 0)
            #expect(try String(contentsOf: fixture.original, encoding: .utf8) == "original-A")
        }
    }

    @Test func automaticRepairRefusesVersionsWrittenBeforeReviewOrAlreadyAttempted() async throws {
        // A row recreated after the review (Clear History, rename) for a file written before it.
        do {
            let fixture = try await Fixture(); defer { fixture.remove() }
            var (finding, root) = try await fixture.prepareAutomatic()
            root.baselineCompletedAt = Date().addingTimeInterval(30)
            finding.firstDetectedAt = Date().addingTimeInterval(60)
            try await fixture.repository.save(root: root)
            try await fixture.repository.upsert(finding)
            do {
                _ = try await ManualRequeueAction.perform(id: finding.id, repository: fixture.repository,
                    environment: fixture.environment, mode: .automatic, automaticAllowed: { true })
                Issue.record("Auto-fix should refuse a version written before the setup review")
            } catch { /* Expected: nothing may be copied. */ }
            #expect(try fixture.environment.operations.records().isEmpty)
            #expect(await fixture.runner.count == 0)
        }
        // An earlier operation on the same content version, recorded under the file's old name.
        do {
            let fixture = try await Fixture(); defer { fixture.remove() }
            let (finding, _) = try await fixture.prepareAutomatic()
            let earlier = RequeueJournal(id: UUID(), phase: .ignored,
                source: SourceVersionKey(canonicalPath: fixture.root.appendingPathComponent("old name.mp4").path,
                    inode: try #require(finding.inode), fileSize: finding.fileSize, modificationTime: finding.modificationDate),
                updatedAt: Date())
            try fixture.environment.operations.save(earlier)
            do {
                _ = try await ManualRequeueAction.perform(id: finding.id, repository: fixture.repository,
                    environment: fixture.environment, mode: .automatic, automaticAllowed: { true })
                Issue.record("Auto-fix should refuse a version that already had an operation")
            } catch { /* Expected. */ }
            #expect(try fixture.environment.operations.records().map(\.id) == [earlier.id])
            #expect(await fixture.runner.count == 0)
            // The rule is automatic-only: a manual Fix of the same version still runs.
            let manual = try await ManualRequeueAction.perform(id: finding.id, repository: fixture.repository, environment: fixture.environment)
            #expect(manual.disposition == .requeueUploading)
        }
    }

    @Test func turningOffAutoFixDuringHashingPreventsPublication() async throws {
        let fixture = try await Fixture(); defer { fixture.remove() }
        let (finding, _) = try await fixture.prepareAutomatic()
        let permission = AutomaticPermission()
        var environment = fixture.environment
        environment.onProgress = { snapshot in
            if snapshot.sourceSHA256 != nil { await permission.disable() }
        }
        let result = try await ManualRequeueAction.perform(id: finding.id, repository: fixture.repository,
            environment: environment, mode: .automatic, automaticAllowed: { await permission.allowed })
        #expect(result.disposition != .requeueSucceeded)
        let record = try #require(try environment.operations.records().first)
        #expect(record.phase == .failed && record.publishedPath == nil)
        #expect(FileManager.default.fileExists(atPath: try #require(record.stagedPath)))
        #expect(try String(contentsOf: fixture.original, encoding: .utf8) == "original-A")
    }

    @Test @MainActor func automaticSettingPersistsAndPauseBlocksDispatch() async throws {
        let fixture = try await Fixture(); defer { fixture.remove() }
        var (finding, root) = try await fixture.prepareAutomatic()
        root.automaticRequeueEnabled = false
        try await fixture.repository.save(root: root)
        let originalRoot = root
        var callbacks = MonitorCallbacks()
        callbacks.loadRoots = { [originalRoot] }
        callbacks.loadFindings = { [finding] }
        callbacks.start = { _ in }
        callbacks.pause = { _ in }
        callbacks.saveRoot = { try await fixture.repository.save(root: $0) }
        var calls = 0
        callbacks.automaticRequeue = { _, _ in calls += 1; return nil }
        let model = AppModel(callbacks: callbacks); model.desktopNotificationsEnabled = false
        await model.restoreSavedMonitoring()
        #expect(!model.automaticRequeueEnabled && calls == 0)
        #expect(model.fileActionTitle(finding) == "Fix" && model.canRequeue(finding))
        model.setMonitoringEnabled(false)
        for _ in 0..<100 where model.changingMonitoring { try await Task.sleep(for: .milliseconds(5)) }
        model.setAutomaticRequeueEnabled(true)
        for _ in 0..<500 where model.savingAutomaticSetting { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.automaticRequeueEnabled && model.isPaused && calls == 0)
        #expect(try await fixture.repository.roots().first?.automaticRequeueEnabled == true)
        finding.disposition = .observing; finding.confirmationCount = 0; finding.errorCode = nil
        model.applyStoreUpdate(findings: [finding], events: [])
        #expect(model.fileActionTitle(finding) == "Fix" && !model.canRequeue(finding))
        model.setMonitoringEnabled(true)
        await Task.yield()
        #expect(calls == 0)
    }

    @Test func publishedRetrySurvivesTimeoutAndChangedSourceResume() async throws {
        let fixture = try await Fixture(); defer { fixture.remove() }
        let finding = try await ManualRequeueAction.perform(id: fixture.finding.id, repository: fixture.repository, environment: fixture.environment)
        #expect(finding.disposition == .requeueUploading)
        let retry = URL(fileURLWithPath: try #require(finding.retryPath))
        #expect(FileManager.default.fileExists(atPath: retry.path))
        try Data("newer-original-B".utf8).write(to: fixture.original)
        await fixture.runner.setMode(.uploaded)
        let resumed = try await ManualRequeueAction.perform(id: finding.id, repository: fixture.repository, environment: fixture.environment)
        #expect(resumed.disposition == .recoveryRequired)
        #expect(try String(contentsOf: fixture.original, encoding: .utf8) == "newer-original-B")
        #expect(try String(contentsOf: retry, encoding: .utf8) == "original-A")
        #expect(UndoArchive.records(in: fixture.environment.undoRoot).isEmpty)
        #expect(try fixture.environment.operations.records().count == 1)
    }

    @Test func uploadedRetryBecomesFixedOnlyAfterFinalPlacement() async throws {
        let fixture = try await Fixture(); defer { fixture.remove() }
        await fixture.runner.setMode(.uploaded)
        let finding = try await ManualRequeueAction.perform(id: fixture.finding.id, repository: fixture.repository, environment: fixture.environment)
        #expect(finding.disposition == .requeueSucceeded)
        #expect(finding.sourceSHA256 == finding.retrySHA256)
        #expect(finding.retryPath == finding.canonicalPath)
        let archive = try #require(UndoArchive.restorableRecord(findingID: finding.id, root: fixture.environment.undoRoot))
        #expect(archive.purgeAllowed == false)
        #expect(try fixture.environment.operations.records().first?.phase == .succeeded)
        #expect(try fixture.environment.operations.pending(path: fixture.original.path) != nil)
        // The fixture still reports -2005 for the final name: placed, but it needs a decision, not "fixed".
        #expect(finding.finalNameFailed && FindingQueue.attention.includes(finding) && !FindingQueue.recent.includes(finding))
        #expect(try fixture.environment.operations.records().first?.finalPathError != nil)
        await fixture.runner.acknowledgeFinalName()
        let checked = try await ManualRequeueAction.perform(id: finding.id, repository: fixture.repository, environment: fixture.environment)
        #expect(checked.disposition == .requeueSucceeded)
        #expect(!checked.finalNameFailed && FindingQueue.recent.includes(checked))
        #expect(try fixture.environment.operations.records().first?.finalPathError == nil)
        #expect(try fixture.environment.operations.records().first?.finalPathVerifiedAt != nil)
        #expect(try fixture.environment.operations.pending(path: fixture.original.path) == nil)
        #expect(UndoArchive.restorableRecord(findingID: finding.id, root: fixture.environment.undoRoot)?.purgeAllowed == true)
        #expect(try fixture.environment.operations.records().count == 1)
    }

    @Test func finalNameFailureSurvivesTransientAndAmbiguousChecks() async throws {
        let fixture = try await Fixture(); defer { fixture.remove() }
        await fixture.runner.setMode(.uploaded)
        let failed = try await ManualRequeueAction.perform(id: fixture.finding.id, repository: fixture.repository, environment: fixture.environment)
        #expect(failed.finalNameFailed)
        // A check that cannot finish keeps the failure and its explanation.
        await fixture.runner.setFinalName(output: nil, throwing: true)
        let transient = try await ManualRequeueAction.perform(id: failed.id, repository: fixture.repository, environment: fixture.environment)
        #expect(transient.finalNameFailed && transient.eligibilityBlockReason?.contains("failed to upload") == true)
        // A momentarily missing provider item says nothing new about the upload.
        await fixture.runner.setFinalName(output: "fileproviderctl: couldn't find a file")
        let missing = try await ManualRequeueAction.perform(id: failed.id, repository: fixture.repository, environment: fixture.environment)
        #expect(missing.finalNameFailed)
        // Uploading again clears it.
        await fixture.runner.setFinalName(output: "fileproviderItems = ({ isUploaded = 0; isUploading = 1; });")
        let moving = try await ManualRequeueAction.perform(id: failed.id, repository: fixture.repository, environment: fixture.environment)
        #expect(!moving.finalNameFailed && moving.disposition == .requeueSucceeded)
    }

    @Test func completedReplacementIsNotRediscoveredAsANewAutomaticSource() async throws {
        let fixture = try await Fixture(); defer { fixture.remove() }
        let (finding, savedRoot) = try await fixture.prepareAutomatic()
        var root = savedRoot
        root.ignorePatterns = ["*/Undo/*", "*/Staging/*", "*/Journals/*"]
        await fixture.runner.setMode(.uploaded)
        _ = try await ManualRequeueAction.perform(id: finding.id, repository: fixture.repository, environment: fixture.environment)
        await fixture.runner.acknowledgeFinalName()
        let completed = try await ManualRequeueAction.perform(id: finding.id, repository: fixture.repository, environment: fixture.environment)
        #expect(completed.inode == (try FileIntegrity.identity(fixture.original)).inode)
        let engine = MonitoringEngine(store: fixture.repository, repairAccess: fixture.environment.access,
            pendingRepair: { try fixture.environment.operations.knownPending(path: $0) != nil },
            saveRoot: { try await fixture.repository.save(root: $0) }, runner: fixture.runner,
            interpreting: ProductionInterpretation.standard, watcherFactory: { RecoveryScanWatcher() }, schedulesReconciliation: false)
        try await engine.start(roots: [root])
        let before = await fixture.runner.count
        try await engine.reconcile()
        #expect(await fixture.runner.count == before)
        #expect(try await fixture.repository.findings(matching: nil).count == 1)
        await engine.stop()
    }

    @Test func writerReopenedBeforeFinalizationDefersArchive() async throws {
        let fixture = try await Fixture(); defer { fixture.remove() }
        await fixture.runner.setMode(.uploaded)
        let probe = ReopenedWriter()
        var environment = fixture.environment
        environment.writeProbe = { _ in await probe.open() }
        let finding = try await ManualRequeueAction.perform(id: fixture.finding.id, repository: fixture.repository, environment: environment)
        #expect(finding.disposition == .requeueUploading)
        #expect(try environment.operations.records().first?.phase == .uploadAcknowledged)
        #expect(UndoArchive.records(in: environment.undoRoot).isEmpty)
        #expect(try String(contentsOf: fixture.original, encoding: .utf8) == "original-A")
        #expect(FileManager.default.fileExists(atPath: try #require(finding.retryPath)))
    }

    @Test func aNewVersionCanBeRepairedAfterUndo() async throws {
        let fixture = try await Fixture(); defer { fixture.remove() }
        await fixture.runner.setMode(.uploaded)
        let fixed = try await ManualRequeueAction.perform(id: fixture.finding.id, repository: fixture.repository, environment: fixture.environment)
        let recovery = RepairRecovery(operations: fixture.environment.operations, access: fixture.environment.access, undoRoot: fixture.environment.undoRoot)
        let restored = try await recovery.undo(fixed)
        try await fixture.repository.upsert(restored)
        try Data("new-version-B".utf8).write(to: fixture.original)
        let identity = try FileIntegrity.sourceVersion(fixture.original)
        let next = sample(path: identity.canonicalPath, inode: identity.inode, size: identity.fileSize, modified: identity.modificationTime)
        try await fixture.repository.upsert(next)
        let repaired = try await ManualRequeueAction.perform(id: next.id, repository: fixture.repository, environment: fixture.environment)
        #expect(repaired.disposition == .requeueSucceeded)
        #expect(try String(contentsOf: fixture.original, encoding: .utf8) == "new-version-B")
    }

    @Test func resolvedRecoveryCreatesAFreshRepairableObservation() async throws {
        let fixture = try await Fixture(); defer { fixture.remove() }
        let pending = try await ManualRequeueAction.perform(id: fixture.finding.id, repository: fixture.repository, environment: fixture.environment)
        let recovery = RepairRecovery(operations: fixture.environment.operations, access: fixture.environment.access, undoRoot: fixture.environment.undoRoot)
        var observing = try await recovery.resolve(pending, choice: .keepCurrentOriginal)
        let old = try #require(try fixture.environment.operations.records().first?.finding)
        #expect(old.disposition == .ignored)
        #expect(observing.id != old.id)
        #expect(observing.retryPath == nil && observing.confirmationCount == 0)
        try await fixture.repository.upsert(old)
        try await fixture.repository.upsert(observing)
        let clock = RecoveryScanClock()
        let root = WatchedRootSnapshot(id: observing.rootIdentifier, path: fixture.root.path, displayName: "Fixture",
            enabled: true, extensions: ["mp4"], ignorePatterns: ["*/Undo/*", "*/Staging/*"], minimumStableAge: 0, automaticRequeueEnabled: false)
        let repository = fixture.repository
        let engine = MonitoringEngine(store: repository, repairAccess: fixture.environment.access,
            saveRoot: { try await repository.save(root: $0) }, runner: fixture.runner,
            interpreting: ProductionInterpretation.standard, watcherFactory: { RecoveryScanWatcher() },
            schedulesReconciliation: false, now: { clock.now })
        try await engine.start(roots: [root])
        try await engine.scanNow()
        clock.advance()
        try await engine.scanNow()
        await engine.stop()
        observing = try #require(try await repository.findings(matching: nil).first(where: { $0.id == observing.id }))
        #expect(observing.disposition == .existingNeedsReview && observing.confirmationCount == 2)
        await fixture.runner.setMode(.uploaded)
        let repaired = try await ManualRequeueAction.perform(id: observing.id, repository: fixture.repository, environment: fixture.environment)
        #expect(repaired.disposition == .requeueSucceeded)
        #expect(try String(contentsOf: fixture.original, encoding: .utf8) == "original-A")
    }

    @Test func legacyRetryIsNeverRepublished() async throws {
        let fixture = try await Fixture(); defer { fixture.remove() }
        var legacy = fixture.finding
        legacy.disposition = .requeueUploading; legacy.retryPath = fixture.original.path + ".retry"
        try Data("old retry".utf8).write(to: URL(fileURLWithPath: legacy.retryPath!))
        try await fixture.repository.upsert(legacy)
        let result = try await ManualRequeueAction.perform(id: legacy.id, repository: fixture.repository, environment: fixture.environment)
        #expect(result.disposition == .recoveryRequired)
        #expect(try fixture.environment.operations.records().isEmpty)
        #expect(await fixture.runner.count == 0)
    }

    @Test @MainActor func resetKeepsInFlightGuardAndFailedFixIsDisabled() async throws {
        let barrier = WaitingAction()
        var callbacks = MonitorCallbacks()
        callbacks.requeue = { _ in await barrier.wait(); return nil }
        callbacks.resetQueueStore = { [] }
        let model = AppModel(callbacks: callbacks)
        model.desktopNotificationsEnabled = false
        let finding = sample(path: "/fixture/a.mp4", inode: 1, size: 1, modified: Date())
        model.findings = [finding]
        model.requeue(id: finding.id)
        while !(await barrier.waiting) { await Task.yield() }
        model.resetQueue()
        #expect(model.requeueInFlight.contains(finding.id))
        model.requeue(id: finding.id)
        #expect(await barrier.count == 1)
        await barrier.release()
        while model.requeueInFlight.contains(finding.id) { await Task.yield() }
        var failed = finding; failed.disposition = .requeueFailed
        #expect(!model.canRequeue(failed))
    }

    @Test @MainActor func unavailableRootStillLoadsRecoveryHistory() async throws {
        var callbacks = MonitorCallbacks()
        let finding = sample(path: "/missing/root/a.mp4", inode: 1, size: 1, modified: Date())
        callbacks.loadFindings = { [finding] }
        callbacks.loadRoots = { [WatchedRootSnapshot(id: UUID(), path: "/missing/root", displayName: "Offline", enabled: true,
            extensions: ["mp4"], ignorePatterns: [], minimumStableAge: 300, automaticRequeueEnabled: false)] }
        callbacks.start = { _ in throw CocoaError(.fileReadNoSuchFile) }
        let model = AppModel(callbacks: callbacks); model.desktopNotificationsEnabled = false
        await model.restoreSavedMonitoring()
        #expect(model.findings.map(\.id) == [finding.id])
        #expect(model.lastErrorText != nil)
    }
}

private struct Fixture: Sendable {
    let root: URL
    let original: URL
    let finding: FindingSnapshot
    let repository: FindingRepository
    let runner: FixtureRunner
    let environment: ManualRequeueAction.Environment
    init() async throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("ui-repair-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        original = root.appendingPathComponent("episode.mp4")
        try Data("original-A".utf8).write(to: original)
        let identity = try FileIntegrity.sourceVersion(original)
        finding = sample(path: identity.canonicalPath, inode: identity.inode, size: identity.fileSize, modified: identity.modificationTime)
        repository = try FindingRepository(inMemory: true)
        try await repository.upsert(finding)
        runner = FixtureRunner(original: original.path)
        environment = ManualRequeueAction.Environment(
            operations: try RepairOperationStore(root: root.appendingPathComponent("Journals")), access: RepairAccess(),
            stagingRoot: root.appendingPathComponent("Staging"), undoRoot: root.appendingPathComponent("Undo"),
            runner: runner, maxPolls: 1, pollInterval: .zero, writeProbe: { _ in false }, availableBytes: { _ in 1_000_000_000_000 })
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func prepareAutomatic() async throws -> (FindingSnapshot, WatchedRootSnapshot) {
        var ready = finding
        ready.disposition = .actionable
        let watched = WatchedRootSnapshot(id: ready.rootIdentifier, path: root.path, displayName: "Fixture",
            enabled: true, extensions: ["mp4"], ignorePatterns: [], minimumStableAge: 0,
            automaticRequeueEnabled: true, baselineCompletedAt: Date().addingTimeInterval(-3600))
        try await repository.save(root: watched)
        try await repository.upsert(ready)
        return (ready, watched)
    }
}

private actor AutomaticPermission {
    var allowed = true
    func disable() { allowed = false }
}

private func sample(path: String, inode: UInt64, size: Int64, modified: Date) -> FindingSnapshot {
    FindingSnapshot(id: UUID(), canonicalPath: path, filename: "episode.mp4", rootIdentifier: UUID(), inode: inode,
        fileSize: size, modificationDate: modified, firstDetectedAt: Date().addingTimeInterval(-120), lastCheckedAt: Date(),
        providerState: "Permanent upload failure", confirmationCount: 2, attemptCount: 0, disposition: .existingNeedsReview)
}

private actor FixtureRunner: CommandRunning {
    enum Mode { case timeout, uploaded }
    let original: String
    var mode: Mode = .timeout
    var count = 0
    var finalAcknowledged = false
    var finalOverride: String?
    var finalThrows = false
    func acknowledgeFinalName() { finalAcknowledged = true }
    func setFinalName(output: String?, throwing: Bool = false) { finalOverride = output; finalThrows = throwing }
    init(original: String) { self.original = original }
    func setMode(_ value: Mode) { mode = value }
    func run(executable: URL, arguments: [String]) async throws -> CommandResult {
        count += 1
        if arguments.last == original, finalThrows { throw CocoaError(.fileReadUnknown) }
        if arguments.last == original, let finalOverride {
            return CommandResult(exitCode: 0, standardOutput: finalOverride, standardError: "")
        }
        if arguments.last == original && !finalAcknowledged {
            return CommandResult(exitCode: 0, standardOutput: "fileproviderItems = ({ isUploaded = 0; isDownloaded = 1; isSyncPaused = 0; isExcludedFromSync = 0; uploadingError = \"Error Domain=NSFileProviderErrorDomain Code=-2005\"; });", standardError: "")
        }
        if mode == .timeout { throw CocoaError(.fileReadUnknown) }
        return CommandResult(exitCode: 0, standardOutput: "fileproviderItems = ({ isUploaded = 1; isUploading = 0; itemIdentifier = retry1; });", standardError: "")
    }
}

private actor WaitingAction {
    var continuation: CheckedContinuation<Void, Never>?
    var count = 0
    var waiting: Bool { continuation != nil }
    func wait() async { count += 1; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

private final class RecoveryScanWatcher: DirectoryWatching, @unchecked Sendable {
    func start(root: URL, handler: @escaping @Sendable (String) -> Void) throws {}
    func stop() {}
}
private final class RecoveryScanClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date()
    var now: Date { lock.withLock { date } }
    func advance() { lock.withLock { date.addTimeInterval(61) } }
}

private actor ReopenedWriter {
    private var calls = 0
    func open() -> Bool { calls += 1; return calls >= 3 }
}
