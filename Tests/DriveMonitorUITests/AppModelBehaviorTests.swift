import Foundation
import Testing
import DriveMonitorCore
@testable import DriveMonitorUI

@Suite @MainActor struct AppModelBehaviorTests {
    @Test func failedStartupScanKeepsMonitoringButAutoFixWaitsForAFreshScan() async throws {
        let watched = WatchedRootSnapshot(id: UUID(), path: "/fixture", displayName: "Fixture", enabled: true, extensions: ["mp4"],
            ignorePatterns: [], minimumStableAge: 300, automaticRequeueEnabled: true, baselineCompletedAt: Date().addingTimeInterval(-3600))
        let finding = FindingSnapshot(id: UUID(), canonicalPath: "/fixture/file.mp4", filename: "file.mp4", rootIdentifier: watched.id,
            inode: 1, fileSize: 10, modificationDate: Date().addingTimeInterval(-600), firstDetectedAt: Date().addingTimeInterval(-300),
            lastCheckedAt: Date().addingTimeInterval(-120), providerState: "Permanent upload failure", confirmationCount: 2,
            attemptCount: 0, disposition: .actionable)
        var calls = 0
        var callbacks = MonitorCallbacks()
        callbacks.loadRoots = { [watched] }
        callbacks.loadFindings = { [finding] }
        callbacks.start = { _ in }
        callbacks.pause = { _ in }
        // A settings change restarted the engine while the startup scan ran.
        callbacks.scan = { throw CancellationError() }
        callbacks.automaticRequeue = { _, _ in calls += 1; return nil }
        let model = AppModel(callbacks: callbacks); model.desktopNotificationsEnabled = false
        await model.restoreSavedMonitoring()
        #expect(model.monitoringEnabled && !model.isPaused && model.lastErrorText == nil)
        for _ in 0..<20 { await Task.yield() }
        #expect(calls == 0) // saved findings are not fresh evidence
        model.applyEventUpdate([ActivityEvent(id: UUID(), timestamp: Date(), kind: .scan, summary: "Recent-file scan completed.")])
        for _ in 0..<50 where calls == 0 { await Task.yield() }
        #expect(calls == 1)
    }

    @Test func lastCheckedReflectsCompletedScansOnly() async {
        let watched = WatchedRootSnapshot(id: UUID(), path: "/fixture", displayName: "Fixture", enabled: true, extensions: ["mp4"],
            ignorePatterns: [], minimumStableAge: 300, automaticRequeueEnabled: false)
        var callbacks = MonitorCallbacks()
        callbacks.loadRoots = { [watched] }
        callbacks.start = { _ in }
        callbacks.pause = { _ in }
        callbacks.loadMonitoringPaused = { true }
        callbacks.scan = { [] }
        let model = AppModel(callbacks: callbacks); model.desktopNotificationsEnabled = false
        await model.restoreSavedMonitoring()
        #expect(model.lastScanDate == nil) // paused at launch: nothing was checked
        let earlier = Date().addingTimeInterval(-900)
        model.applyEventUpdate([ActivityEvent(id: UUID(), timestamp: earlier, kind: .scan, summary: "Recent-file scan completed.")])
        #expect(model.lastScanDate == earlier)
        model.applyEventUpdate([ActivityEvent(id: UUID(), timestamp: earlier.addingTimeInterval(-60), kind: .scan, summary: "Older scan.")])
        #expect(model.lastScanDate == earlier) // never moves backwards
    }

    @Test func windowRequestsWaitForTheMenuBarLabelAndShowTheFilesList() throws {
        let model = AppModel.preview()
        let fixed = try #require(model.findings.first { $0.disposition == .requeueSucceeded })
        model.activityFilter = .needsAttention
        model.showActivity(selecting: fixed.id)
        #expect(model.activityFilter == .recent && model.activitySelection == fixed.id && model.activityInspectorShown)
        var opened: [AppWindowID] = []
        model.windowPresenter = { opened.append($0) }
        #expect(opened == [.activity]) // the request made before the label appeared is delivered once
        model.handleReopen()
        #expect(opened == [.activity, .activity])
    }

    @Test func healthIsNotClaimedBeforeAnyCheckCompletes() async {
        let watched = WatchedRootSnapshot(id: UUID(), path: "/fixture", displayName: "Fixture", enabled: true, extensions: ["mp4"],
            ignorePatterns: [], minimumStableAge: 300, automaticRequeueEnabled: false)
        var callbacks = MonitorCallbacks()
        callbacks.loadRoots = { [watched] }
        callbacks.start = { _ in }
        callbacks.pause = { _ in }
        callbacks.scan = { throw CocoaError(.fileReadUnknown) }
        let model = AppModel(callbacks: callbacks); model.desktopNotificationsEnabled = false
        await model.restoreSavedMonitoring()
        #expect(model.status == .healthy && model.statusTitle == "Not checked yet")
        model.applyEventUpdate([ActivityEvent(id: UUID(), timestamp: Date(), kind: .scan, summary: "Recent-file scan completed.")])
        #expect(model.statusTitle == "No stuck uploads found")
    }

    @Test func aFileRequestedBeforeItLoadsOpensItsListWhenItArrives() throws {
        let sample = AppModel.preview()
        let fixed = try #require(sample.findings.first { $0.disposition == .requeueSucceeded })
        let model = AppModel()
        model.activityFilter = .needsAttention
        model.showActivity(selecting: fixed.id) // a notification click at launch, before rows load
        #expect(model.activityFilter == .needsAttention)
        model.findings = sample.findings
        #expect(model.activityFilter == .recent && model.activitySelection == fixed.id)
    }

    @Test func recoveryBadgeCountsOnlyRepairsThatNeedReview() async throws {
        let sample = AppModel.preview()
        let interrupted = try #require(sample.findings.first { $0.disposition == .recoveryRequired })
        let uploading = try #require(sample.findings.first { $0.disposition == .requeueUploading })
        func journal(_ phase: RequeuePhase, _ finding: FindingSnapshot) -> RequeueJournal {
            var record = RequeueJournal(id: UUID(), phase: phase, source: SourceVersionKey(canonicalPath: finding.canonicalPath,
                inode: 1, fileSize: finding.fileSize, modificationTime: Date()), updatedAt: Date())
            record.finding = finding
            return record
        }
        let operations = [journal(.published, uploading), journal(.recoveryRequired, interrupted)]
        var callbacks = MonitorCallbacks()
        callbacks.loadOperations = { operations }
        let model = AppModel(callbacks: callbacks)
        model.findings = sample.findings
        await model.refreshRecovery()
        #expect(model.recoveryReviewCount == 1) // the healthy in-flight upload is not something to review
    }

    @Test func aStaleSnapshotDoesNotUndoARepairInProgress() async throws {
        let gate = Gate()
        var callbacks = MonitorCallbacks()
        callbacks.requeue = { _ in await gate.wait(); return nil }
        let model = AppModel(callbacks: callbacks); model.desktopNotificationsEnabled = false
        let sample = AppModel.preview()
        let finding = try #require(sample.findings.first { $0.disposition == .actionable })
        model.findings = [finding]
        model.requeue(id: finding.id)
        while !(await gate.waiting) { await Task.yield() }
        #expect(model.findings.first?.disposition == .requeuePreparing)
        model.applyStoreUpdate(findings: [finding], events: []) // read before the repair started
        #expect(model.findings.first?.disposition == .requeuePreparing)
        await gate.release()
        for _ in 0..<100 where !model.requeueInFlight.isEmpty { await Task.yield() }
        #expect(model.requeueInFlight.isEmpty && model.findings.first?.disposition == .actionable) // the repair's own result applies
    }

    @Test func repairProgressRefreshesRetainedFilesSoUndoCanAppear() async throws {
        var loads = 0
        var callbacks = MonitorCallbacks()
        callbacks.loadRecovery = { loads += 1; return [] }
        let model = AppModel(callbacks: callbacks); model.desktopNotificationsEnabled = false
        var finding = try #require(AppModel.preview().findings.first { $0.disposition == .requeueUploading })
        model.findings = [finding]
        // Background verification finalized the repair; the original is now archived.
        finding.disposition = .requeueSucceeded
        finding.providerState = FindingRequeue.finalNameFailedState
        model.applyRepairUpdate(finding)
        for _ in 0..<100 where loads == 0 { await Task.yield() }
        #expect(loads == 1)
        model.applyRepairUpdate(finding) // nothing changed: no reload
        for _ in 0..<20 { await Task.yield() }
        #expect(loads == 1)
    }

    @Test func otherUploadErrorsAreNotDescribedAsConfirmingTheStuckUpload() throws {
        var finding = try #require(AppModel.preview().findings.first { $0.disposition == .observing })
        finding.errorCode = -1005
        finding.providerState = "Upload error (NSFileProviderErrorDomain -1005)"
        #expect(finding.statusText == finding.providerState)
        finding.errorCode = -2005
        #expect(finding.statusText == "Confirming failure")
    }

    @Test func clearHistoryKeepsDecisionRowsInMemory() {
        let model = AppModel.preview()
        var ignored = try! #require(model.findings.first { $0.disposition == .observing })
        ignored.disposition = .ignored
        model.findings[model.findings.firstIndex { $0.id == ignored.id }!] = ignored
        model.resetQueue()
        #expect(model.findings.contains { $0.id == ignored.id })
        #expect(model.findings.contains { $0.disposition == .existingNeedsReview })
        #expect(!model.findings.contains { $0.disposition == .actionable })
        #expect(model.findings.contains { $0.hasRepairEvidence })
    }
}

private actor Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    var waiting: Bool { continuation != nil }
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
