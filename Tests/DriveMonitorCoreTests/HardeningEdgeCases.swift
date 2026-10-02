import Foundation
import Testing
@testable import DriveMonitorCore

@Suite struct HardeningEdgeCases {
    @Test func writerCheckRequiresCompleteRecognizedOutput() throws {
        func result(_ exit: Int32, _ output: String = "", _ error: String = "") -> CommandResult {
            CommandResult(exitCode: exit, standardOutput: output, standardError: error)
        }
        #expect(try SystemOpenWriteProbe.interpret(result(1)) == false)
        #expect(try SystemOpenWriteProbe.interpret(result(0, "p10\nf4\nar\n")) == false)
        #expect(try SystemOpenWriteProbe.interpret(result(0, "p10\nf4\nau\n")) == true)
        for output in [result(2), result(1, "", "permission denied"), result(0), result(0, "p10\nf4\na?\n"), result(0, "p10\nf4\n")] {
            #expect(throws: (any Error).self) { try SystemOpenWriteProbe.interpret(output) }
        }
    }

    @Test func repairRequiresExplicitUnpausedAndIncludedState() {
        let text = "fileproviderItems = ({ isUploaded = 0; isDownloaded = 1; uploadingError = \"Error Domain=NSFileProviderErrorDomain Code=-2005\"; });"
        guard case .item(let item) = FileProviderParser.parse(text) else { Issue.record("Expected a readable item"); return }
        #expect(!FileProviderParser.isActionablePermanentFailure(item))
    }

    @Test func oversizedCommandOutputIsRejected() async {
        do {
            _ = try await BoundedProcess.run(executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["%010000d", "1"], timeout: 2, outputLimit: 100)
            Issue.record("Output above the cap must not be accepted")
        } catch { #expect(error.localizedDescription.contains("limit")) }
    }

    @Test func timeoutKeepsChildSlotUntilActualExit() async throws {
        let program = URL(fileURLWithPath: "/bin/sleep")
        let started = Date()
        do {
            _ = try await BoundedProcess.run(executable: program, arguments: ["0.3"], timeout: 0.02)
            Issue.record("A slow child must time out")
        } catch { #expect(error.localizedDescription.contains("timed out")) }
        #expect(Date().timeIntervalSince(started) < 1)
        do {
            _ = try await BoundedProcess.run(executable: program, arguments: ["0.3"], timeout: 1)
            Issue.record("A timed-out child must still own its admission slot")
        } catch { #expect(error.localizedDescription.contains("still running")) }
        try await Task.sleep(for: .milliseconds(400))
        let finished = try await BoundedProcess.run(executable: program, arguments: ["0.3"], timeout: 1)
        #expect(finished.exitCode == 0)
    }

    @Test func aBurstWaitsForAFreeSlotInsteadOfFailing() async throws {
        let program = URL(fileURLWithPath: "/bin/sleep")
        // Distinct arguments are distinct checks; the fifth must wait for one of the first four.
        let busy = (0..<4).map { index in
            Task { try await BoundedProcess.run(executable: program, arguments: ["0.4\(index + 1)"], timeout: 5) }
        }
        try await Task.sleep(for: .milliseconds(100))
        let waited = try await BoundedProcess.run(executable: program, arguments: ["0.05"], timeout: 5)
        #expect(waited.exitCode == 0)
        for task in busy { #expect(try await task.value.exitCode == 0) }
    }

    @Test func parserRejectsMalformedOptionalSafetyFields() {
        for body in ["documentSize = nope;", "documentSize = -1;", "isSyncPaused = {};", "isExcludedFromSync = ();", "itemIdentifier = {};", "isUploaded = 1;", "uploadingError = unknown;"] {
            let parsed = FileProviderParser.parse("fileproviderItems = ({ isUploaded = 1; \(body) });")
            if case .incompatible = parsed {} else { Issue.record("Expected incompatible for \(body)") }
        }
        #expect(EvaluationClassification.classify(FileProviderParser.parse("fileproviderItems = ({ isUploaded = 1; } );")) == .uploaded)
    }

    @Test func recoveryExportPublishesOnlyVerifiedCompleteBytes() async throws {
        let fixture = try ExportFixture(); defer { fixture.remove() }
        let expected = try FileIntegrity.sha256(fixture.source)
        let task = Task.detached { try await RecoveryExport.copy(source: fixture.source, destination: fixture.destination, expectedSHA256: expected) }
        try await task.value
        #expect(try FileIntegrity.sha256(fixture.destination) == expected)
        #expect(try FileIntegrity.sha256(fixture.source) == expected)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).filter { $0.contains("partial") }.isEmpty)
    }

    @Test func cancelledExportKeepsSourceAndPublishesNothing() async throws {
        let fixture = try ExportFixture(); defer { fixture.remove() }
        let expected = try FileIntegrity.sha256(fixture.source)
        let task = Task.detached {
            try await RecoveryExport.copy(source: fixture.source, destination: fixture.destination, expectedSHA256: expected) { copied, _ in
                if copied > 0 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do { try await task.value; Issue.record("Cancelled export must not publish") }
        catch is CancellationError {}
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
        #expect(try FileIntegrity.sha256(fixture.source) == expected)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).filter { $0.contains("partial") }.isEmpty)
    }

    @Test func exportRefusesHashMismatchAndExistingDestination() async throws {
        let fixture = try ExportFixture(); defer { fixture.remove() }
        do {
            try await RecoveryExport.copy(source: fixture.source, destination: fixture.destination, expectedSHA256: "bad-digest")
            Issue.record("Export must refuse a mismatched archive")
        } catch { #expect(error.localizedDescription.contains("digest")) }
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
        try Data("newer-file".utf8).write(to: fixture.destination)
        do {
            try await RecoveryExport.copy(source: fixture.source, destination: fixture.destination, expectedSHA256: nil)
            Issue.record("Export must not overwrite a destination")
        } catch { #expect(error.localizedDescription.contains("empty destination")) }
        #expect(try String(contentsOf: fixture.destination, encoding: .utf8) == "newer-file")
    }

    @Test func malformedArchiveInventoryIsVisibleAndPreserved() throws {
        let fixture = try ExportFixture(); defer { fixture.remove() }
        let archive = fixture.root.appendingPathComponent("BrokenArchive")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        try Data("invalid".utf8).write(to: archive.appendingPathComponent("manifest.json"))
        let inventory = try UndoArchive.inventory(in: fixture.root)
        #expect(inventory.unreadable.contains { $0.resolvingSymlinksInPath().path == archive.resolvingSymlinksInPath().path })
        #expect(try UndoArchive.purgeExpired(root: fixture.root) == 0)
        #expect(FileManager.default.fileExists(atPath: archive.path))
    }

    @Test func revocationBarrierSurvivesReopenAndRejectsCorruption() throws {
        let fixture = try ExportFixture(); defer { fixture.remove() }
        let permissions = try AutomaticPermissionStore(root: fixture.root)
        #expect(try permissions.isRevoked() == false)
        try permissions.saveRevocation(true)
        let reopened = try AutomaticPermissionStore(root: fixture.root)
        #expect(try reopened.isRevoked())
        try Data("corrupted".utf8).write(to: reopened.file)
        #expect(throws: (any Error).self) { try reopened.isRevoked() }
        try reopened.saveRevocation(false)
        #expect(try permissions.isRevoked() == false)
    }

    @Test func activityRetentionDropsOldScansSoonerThanOtherHistory() async throws {
        let repository = try FindingRepository(inMemory: true)
        let now = Date()
        func event(_ kind: ActivityKind, daysAgo: Double) -> ActivityEvent {
            ActivityEvent(id: UUID(), timestamp: now.addingTimeInterval(-daysAgo * 86_400), kind: kind, summary: "\(kind.rawValue) \(daysAgo)")
        }
        let keptScan = event(.scan, daysAgo: 1), keptRepair = event(.requeueSucceeded, daysAgo: 30)
        for item in [event(.scan, daysAgo: 8), keptScan, event(.requeueSucceeded, daysAgo: 200), keptRepair] {
            try await repository.append(item)
        }
        try await repository.pruneEvents(now: now)
        #expect(Set(try await repository.events(limit: 10).map(\.id)) == [keptScan.id, keptRepair.id])
    }

    @Test func historyPagesAreBoundedAndDoNotOverlap() async throws {
        let repository = try FindingRepository(inMemory: true)
        for index in 0..<7 {
            try await repository.append(ActivityEvent(id: UUID(), timestamp: Date(timeIntervalSince1970: Double(index)), kind: .scan, summary: "\(index)"))
        }
        let first = try await repository.events(limit: 3)
        let second = try await repository.events(limit: 3, offset: 3)
        #expect(first.map(\.summary) == ["6", "5", "4"])
        #expect(second.map(\.summary) == ["3", "2", "1"])
    }

    @Test @MainActor func coordinatorSkipsVersionsWrittenBeforeReviewOrStillSettling() {
        let date = Date()
        let coordinator = AutomaticRepairCoordinator(now: { date })
        let id = UUID()
        let root = WatchedRootSnapshot(id: id, path: "/fixture", displayName: "Fixture", enabled: true, extensions: ["mp4"], ignorePatterns: [], minimumStableAge: 300, automaticRequeueEnabled: true, baselineCompletedAt: date.addingTimeInterval(-3600))
        // A row recreated after the review (Clear History, rename) for a file last written before it.
        let recreated = FindingSnapshot(id: UUID(), canonicalPath: "/fixture/old.mp4", filename: "old.mp4", rootIdentifier: id, inode: 1, fileSize: 1, modificationDate: date.addingTimeInterval(-7200), firstDetectedAt: date, lastCheckedAt: date, providerState: "Confirmed", confirmationCount: 2, attemptCount: 0, disposition: .actionable)
        #expect(coordinator.reserve(findings: [recreated], roots: [root], permittedRootIDs: [id], eligible: { _ in true }) == nil)
        var settling = recreated
        settling.id = UUID(); settling.canonicalPath = "/fixture/new.mp4"; settling.modificationDate = date.addingTimeInterval(-60)
        #expect(coordinator.reserve(findings: [settling], roots: [root], permittedRootIDs: [id], eligible: { _ in true }) == nil)
        var ready = settling
        ready.modificationDate = date.addingTimeInterval(-600)
        #expect(coordinator.reserve(findings: [ready], roots: [root], permittedRootIDs: [id], eligible: { _ in true })?.id == ready.id)
    }

    @Test func operationHistoryMatchesAVersionUnderAnyName() {
        let date = Date()
        let earlier = RequeueJournal(id: UUID(), phase: .ignored,
            source: SourceVersionKey(canonicalPath: "/fixture/old-name.mp4", inode: 7, fileSize: 42, modificationTime: date), updatedAt: date)
        var renamed = FindingSnapshot(id: UUID(), canonicalPath: "/fixture/new-name.mp4", filename: "new-name.mp4", rootIdentifier: UUID(), inode: 7, fileSize: 42, modificationDate: date.addingTimeInterval(0.4), firstDetectedAt: date, lastCheckedAt: date, providerState: "Confirmed", confirmationCount: 2, attemptCount: 0, disposition: .actionable)
        #expect(AutomaticRepairCoordinator.hasOperation(for: renamed, in: [earlier]))
        renamed.fileSize = 43
        #expect(!AutomaticRepairCoordinator.hasOperation(for: renamed, in: [earlier]))
    }

    @Test @MainActor func deferredPreflightCanRetryButCommittedVersionCannot() {
        var date = Date()
        let coordinator = AutomaticRepairCoordinator(now: { date })
        let id = UUID()
        let root = WatchedRootSnapshot(id: id, path: "/fixture", displayName: "Fixture", enabled: true, extensions: ["mp4"], ignorePatterns: [], minimumStableAge: 0, automaticRequeueEnabled: true, baselineCompletedAt: date.addingTimeInterval(-3600))
        var finding = FindingSnapshot(id: UUID(), canonicalPath: "/fixture/file.mp4", filename: "file.mp4", rootIdentifier: id, inode: 1, fileSize: 1, modificationDate: date, firstDetectedAt: date, lastCheckedAt: date, providerState: "Confirmed", confirmationCount: 2, attemptCount: 0, disposition: .actionable)
        #expect(coordinator.reserve(findings: [finding], roots: [root], permittedRootIDs: [id], eligible: { _ in true }) != nil)
        #expect(coordinator.reserve(findings: [finding], roots: [root], permittedRootIDs: [id], eligible: { _ in true }) == nil)
        coordinator.finish(result: finding)
        #expect(coordinator.reserve(findings: [finding], roots: [root], permittedRootIDs: [id], eligible: { _ in true }) == nil)
        date = date.addingTimeInterval(61)
        #expect(coordinator.reserve(findings: [finding], roots: [root], permittedRootIDs: [id], eligible: { _ in true }) != nil)
        finding.attemptCount = 1; finding.retryPath = "/fixture/retry.mp4"
        coordinator.finish(result: finding)
        finding.attemptCount = 0; finding.retryPath = nil // stale delivery
        date = date.addingTimeInterval(61)
        #expect(coordinator.reserve(findings: [finding], roots: [root], permittedRootIDs: [id], eligible: { _ in true }) == nil)
    }
}

private struct ExportFixture: Sendable {
    let root: URL
    let source: URL
    let destination: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("export-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        source = root.appendingPathComponent("source.bin")
        destination = root.appendingPathComponent("export.bin")
        try Data(repeating: 42, count: 5 * 1024 * 1024).write(to: source)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
