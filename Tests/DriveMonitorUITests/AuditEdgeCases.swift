import Foundation
import Testing
import DriveMonitorCore
@testable import DriveMonitorUI

@Suite struct AuditEdgeCases {
    @Test @MainActor func redactedDiagnosticMustRedactReasonsToo() {
        var finding = FindingSnapshot(id: UUID(), canonicalPath: "/fixture/private/customer.mov", filename: "customer.mov",
            rootIdentifier: UUID(), fileSize: 1, modificationDate: Date(), firstDetectedAt: Date(), lastCheckedAt: Date(),
            providerState: "Blocked", confirmationCount: 0, attemptCount: 0, disposition: .compatibilityBlocked)
        finding.eligibilityBlockReason = "Could not read /fixture/private/customer.mov"
        let model = AppModel(); model.desktopNotificationsEnabled = false
        model.showRawPaths = false; model.findings = [finding]
        let diagnostic = model.copyDiagnostic(id: finding.id)
        print("AUDIT redacted diagnostic still contains full path in reason = \(diagnostic.contains(finding.canonicalPath))")
        #expect(!diagnostic.contains(finding.canonicalPath))
    }

    @Test @MainActor func recentQueueMustIncludeNaturallyResolvedFiles() {
        let finding = FindingSnapshot(id: UUID(), canonicalPath: "/fixture/file.mp4", filename: "file.mp4",
            rootIdentifier: UUID(), fileSize: 1, modificationDate: Date(), firstDetectedAt: Date(), lastCheckedAt: Date(),
            providerState: "Synology reports uploaded", confirmationCount: 0, attemptCount: 0, disposition: .resolved)
        let model = AppModel(); model.desktopNotificationsEnabled = false; model.findings = [finding]
        // This is the exact projection used by the menu's Recent group.
        let recent = model.recentFindings
        print("AUDIT resolved file projected into Recent = \(recent.count)")
        #expect(recent.map(\.id) == [finding.id])
    }

    @Test func ambiguousProviderOutputMustNotAuthorizeUploaded() {
        let cases = [
            "fileproviderItems = ({ isUploaded = 1; uploadingError = unknown; });",
            "fileproviderItems = ({ isUploaded = 1; }",
            "fileproviderItems = ({ isUploaded = 0; isUploaded = 1; });"
        ]
        for text in cases {
            let classification = EvaluationClassification.classify(FileProviderParser.parse(text))
            print("AUDIT parser: \(text) => \(classification)")
            #expect(classification != .uploaded)
        }
    }

    @Test func malformedPauseOrExclusionMustNotPermitRepair() {
        for field in ["isSyncPaused", "isExcludedFromSync"] {
            let text = "fileproviderItems = ({ isUploaded = 0; isDownloaded = 1; \(field) = maybe; uploadingError = \"Error Domain=NSFileProviderErrorDomain Code=-2005\"; });"
            if case .item(let item) = FileProviderParser.parse(text) {
                print("AUDIT \(field): actionable = \(FileProviderParser.isActionablePermanentFailure(item))")
                #expect(!FileProviderParser.isActionablePermanentFailure(item))
            }
        }
    }

    @Test @MainActor func restoreDisplaysTheSavedStabilityPolicy() async {
        let root = root(path: "/fixture", age: 912)
        var callbacks = MonitorCallbacks()
        callbacks.loadRoots = { [root] }
        callbacks.start = { _ in }
        callbacks.scan = { [] }
        let model = AppModel(callbacks: callbacks); model.desktopNotificationsEnabled = false
        await model.restoreSavedMonitoring()
        print("AUDIT saved stability = \(root.minimumStableAge), displayed = \(model.minimumStableAge)")
        #expect(model.minimumStableAge == root.minimumStableAge)
    }

    @Test @MainActor func replacingFolderMustNotRestoreThePreviousFolder() async throws {
        let directory = try Directory(); defer { directory.remove() }
        let first = directory.url.appendingPathComponent("first")
        let second = directory.url.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let repository = try FindingRepository(inMemory: true)
        let previous = root(path: first.path)
        try await repository.save(root: previous)
        var callbacks = MonitorCallbacks()
        callbacks.loadRoots = { try await repository.roots() }
        callbacks.start = { _ in }
        callbacks.scan = { [] }
        callbacks.saveRoot = { try await repository.save(root: $0) }
        callbacks.saveRoots = { try await repository.replaceRoots($0) }
        let model = AppModel(callbacks: callbacks); model.desktopNotificationsEnabled = false
        await model.restoreSavedMonitoring()
        model.confirmRoot(second)
        for _ in 0..<100 {
            if try await repository.roots().contains(where: { $0.path == second.path }) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let reopened = AppModel(callbacks: callbacks); reopened.desktopNotificationsEnabled = false
        await reopened.restoreSavedMonitoring()
        print("AUDIT roots after replacement/reopen: \(reopened.watchedRoots.map(\.path))")
        #expect(reopened.watchedRoots.map(\.path) == [second.path])
    }

    @Test @MainActor func applyingSettingsMustKeepAPausedEnginePaused() async throws {
        let directory = try Directory(); defer { directory.remove() }
        let repository = try FindingRepository(inMemory: true)
        let watched = root(path: directory.url.path)
        let engine = MonitoringEngine(store: repository, saveRoot: { try await repository.save(root: $0) },
            runner: EmptyRunner(), interpreting: ProductionInterpretation.standard,
            watcherFactory: { QuietWatcher() }, schedulesReconciliation: false)
        var callbacks = MonitorCallbacks()
        callbacks.loadRoots = { [watched] }
        callbacks.start = { try await engine.start(roots: $0) }
        callbacks.saveRoot = { try await repository.save(root: $0) }
        callbacks.saveRoots = { try await repository.replaceRoots($0) }
        callbacks.pause = { if $0 { await engine.pause() } else { try await engine.resume() } }
        let model = AppModel(callbacks: callbacks); model.desktopNotificationsEnabled = false
        await model.restoreSavedMonitoring()
        model.setMonitoringEnabled(false)
        for _ in 0..<100 {
            if await engine.isPaused { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        model.applyRootSettings()
        for _ in 0..<100 {
            if model.recentActivity.contains(where: { $0.summary == "Monitoring settings updated." }) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        print("AUDIT after Apply: UI paused = \(model.isPaused), engine paused = \(await engine.isPaused)")
        #expect(await engine.isPaused)
        await engine.stop()
    }

    @Test @MainActor func failedAutoFixOptOutMustStayOffAfterRestart() async throws {
        let repository = try FindingRepository(inMemory: true)
        let watched = root(path: "/fixture", automatic: true)
        try await repository.save(root: watched)
        var callbacks = MonitorCallbacks()
        callbacks.loadRoots = { try await repository.roots() }
        callbacks.start = { _ in }
        callbacks.scan = { [] }
        callbacks.saveRoot = { try await repository.save(root: $0) }
        callbacks.saveRoots = { try await repository.replaceRoots($0) }
        let model = AppModel(callbacks: callbacks); model.desktopNotificationsEnabled = false
        await model.restoreSavedMonitoring()
        var failing = callbacks
        failing.start = { _ in throw CocoaError(.fileReadNoSuchFile) }
        let editable = AppModel(callbacks: failing); editable.desktopNotificationsEnabled = false
        await editable.restoreSavedMonitoring()
        editable.setAutomaticRequeueEnabled(false)
        for _ in 0..<100 where editable.savingAutomaticSetting { try await Task.sleep(for: .milliseconds(5)) }
        let reopened = AppModel(callbacks: callbacks); reopened.desktopNotificationsEnabled = false
        await reopened.restoreSavedMonitoring()
        print("AUDIT opt-out failed to restart engine: current-session auto = \(editable.automaticRequeueEnabled), reopened auto = \(reopened.automaticRequeueEnabled)")
        #expect(!reopened.automaticRequeueEnabled)
    }

    @Test @MainActor func permissionRevocationSurvivesPersistenceFailure() async throws {
        let repository = try FindingRepository(inMemory: true)
        let watched = root(path: "/fixture", automatic: true)
        try await repository.save(root: watched)
        var revoked = false
        var callbacks = MonitorCallbacks()
        callbacks.loadRoots = { try await repository.roots() }
        callbacks.loadAutomaticRevocation = { revoked }
        callbacks.saveAutomaticRevocation = { revoked = $0 }
        callbacks.start = { _ in }
        callbacks.saveRoots = { _ in throw CocoaError(.fileWriteNoPermission) }
        let model = AppModel(callbacks: callbacks); model.desktopNotificationsEnabled = false
        await model.restoreSavedMonitoring()
        model.setAutomaticRequeueEnabled(false)
        for _ in 0..<100 where model.savingAutomaticSetting { try await Task.sleep(for: .milliseconds(5)) }
        let reopened = AppModel(callbacks: callbacks); reopened.desktopNotificationsEnabled = false
        await reopened.restoreSavedMonitoring()
        #expect(revoked && !reopened.automaticRequeueEnabled)
        #expect(try await repository.roots().first?.automaticRequeueEnabled == true)
    }

    @Test @MainActor func autoFixMustNotRestartBeforeFreshFailureVerification() async {
        let watched = root(path: "/fixture", automatic: true)
        let finding = FindingSnapshot(id: UUID(), canonicalPath: "/fixture/file.mp4", filename: "file.mp4",
            rootIdentifier: watched.id, inode: 1, fileSize: 10, modificationDate: Date().addingTimeInterval(-600),
            firstDetectedAt: Date().addingTimeInterval(-300), lastCheckedAt: Date().addingTimeInterval(-120),
            providerState: "Permanent upload failure", confirmationCount: 2, attemptCount: 0, disposition: .actionable)
        var calls = 0
        var callbacks = MonitorCallbacks()
        callbacks.loadRoots = { [watched] }
        callbacks.loadFindings = { [finding] }
        callbacks.start = { _ in }
        callbacks.scan = { throw CocoaError(.fileReadUnknown) }
        callbacks.automaticRequeue = { _, _ in calls += 1; return nil }
        let model = AppModel(callbacks: callbacks); model.desktopNotificationsEnabled = false
        await model.restoreSavedMonitoring()
        for _ in 0..<20 { await Task.yield() }
        print("AUDIT auto dispatch after failed startup scan = \(calls)")
        #expect(calls == 0)
    }
}

private func root(path: String, age: Double = 300, automatic: Bool = false) -> WatchedRootSnapshot {
    WatchedRootSnapshot(id: UUID(), path: path, displayName: "Fixture", enabled: true, extensions: ["mp4"],
        ignorePatterns: [], minimumStableAge: age, automaticRequeueEnabled: automatic,
        baselineCompletedAt: Date().addingTimeInterval(-3600))
}
private struct Directory {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("audit-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    func remove() { try? FileManager.default.removeItem(at: url) }
}
private struct EmptyRunner: CommandRunning {
    func run(executable: URL, arguments: [String]) async throws -> CommandResult {
        throw CocoaError(.fileReadUnknown)
    }
}
private final class QuietWatcher: DirectoryWatching, @unchecked Sendable {
    func start(root: URL, handler: @escaping @Sendable (String) -> Void) throws {}
    func stop() {}
}
