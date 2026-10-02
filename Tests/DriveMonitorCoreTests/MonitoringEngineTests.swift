import Foundation
import Testing
@testable import DriveMonitorCore

@Suite struct MonitoringEngineTests {
    @Test func storeChangeCallbackCanAcquireTheEvaluatedPath() async throws {
        let directory = try TestDirectory(); defer { directory.remove() }
        let file = try directory.file("episode.mp4")
        let access = RepairAccess()
        let fixture = try EngineFixture(directory: directory, minimumStableAge: 300, access: access)
        try await fixture.start()
        await fixture.engine.setStoreChangeHandler {
            do { try await access.withAccess(to: file.path) {} }
            catch { Issue.record("An automatic repair callback was notified before the scan released its lease: \(error)") }
        }
        _ = try await fixture.engine.evaluateFile(file)
        await fixture.engine.stop()
    }

    @Test func deletedFileBecomesHistoryInsteadOfAPermanentAlert() async throws {
        let directory = try TestDirectory(); defer { directory.remove() }
        let file = try directory.file("episode.mp4")
        let kept = try directory.file("kept.mp4")
        let fixture = try EngineFixture(directory: directory, minimumStableAge: 600)
        try await fixture.start()
        _ = try await fixture.engine.evaluateFile(file)
        _ = try await fixture.engine.evaluateFile(kept)
        let observed = try #require(try await fixture.repository.findings(at: file.path).first)
        var ignored = try #require(try await fixture.repository.findings(at: kept.path).first)
        ignored.disposition = .ignored
        try await fixture.repository.upsert(ignored)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.removeItem(at: kept)
        let ghost = directory.url.appendingPathComponent("renamed-away.mp4")
        for _ in 0..<3 {
            _ = try await fixture.engine.evaluateFile(file)
            _ = try await fixture.engine.evaluateFile(kept)
            _ = try await fixture.engine.evaluateFile(ghost)
        }
        let rows = try await fixture.repository.findings(matching: nil)
        #expect(Set(rows.map(\.id)) == [observed.id, ignored.id]) // a path that is gone gets no new row
        #expect(rows.first { $0.id == observed.id }?.disposition == .sourceChanged)
        #expect(rows.first { $0.id == ignored.id }?.disposition == .ignored) // decisions are not rewritten
        let events = try await fixture.repository.events(limit: 50)
        #expect(!events.contains { $0.kind == .compatibility })
        #expect(events.filter { $0.kind == .lifecycle }.count == 1) // recorded once, not on every check
        #expect(await fixture.runner.paths.isEmpty)
        await fixture.engine.stop()
    }

    @Test func ineligiblePathsLeaveNoLockFiles() async throws {
        let directory = try TestDirectory(); defer { directory.remove() }
        let locks = FileManager.default.temporaryDirectory.appendingPathComponent("locks-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: locks) }
        let fixture = try EngineFixture(directory: directory, minimumStableAge: 600, access: RepairAccess(lockRoot: locks))
        try await fixture.start()
        for name in ["notes.txt", ".DS_Store", "clip_segment_1.mp4"] {
            _ = try await fixture.engine.evaluateFile(try directory.file(name))
        }
        #expect(!FileManager.default.fileExists(atPath: locks.path)) // no lease was taken at all
        _ = try await fixture.engine.evaluateFile(try directory.file("episode.mp4"))
        // An eligible file takes the lease (creating the directory) and leaves nothing behind.
        #expect(FileManager.default.fileExists(atPath: locks.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: locks.path).isEmpty)
        await fixture.engine.stop()
    }

    @Test func eventDrivenCheckFailuresAreRecordedInActivity() async throws {
        let directory = try TestDirectory(); defer { directory.remove() }
        let file = try directory.file("episode.mp4")
        let fixture = try EngineFixture(directory: directory, store: { FailingLookups(base: $0) })
        try await fixture.start()
        fixture.watcher.push(file.path)
        var events: [ActivityEvent] = []
        for _ in 0..<100 where !events.contains(where: { $0.kind == .compatibility }) {
            try await Task.sleep(for: .milliseconds(20))
            events = try await fixture.repository.events(limit: 10)
        }
        #expect(events.contains { $0.kind == .compatibility && $0.summary.contains("episode.mp4") })
        await fixture.engine.stop()
    }

    @Test func otherUploadErrorsAreReportedNotTreatedAsUnreadable() async throws {
        let directory = try TestDirectory(); defer { directory.remove() }
        let file = try directory.file("episode.mp4", modified: Date().addingTimeInterval(-3600))
        let fixture = try EngineFixture(directory: directory, forcedClassification: .uploadError(domain: "NSFileProviderErrorDomain", code: -1005))
        try await fixture.start()
        let identity = try FileIntegrity.sourceVersion(file)
        let tracked = FindingSnapshot(id: UUID(), canonicalPath: identity.canonicalPath, filename: "episode.mp4", rootIdentifier: fixture.root.id,
            inode: identity.inode, fileSize: identity.fileSize, modificationDate: identity.modificationTime, firstDetectedAt: Date(),
            lastCheckedAt: Date(), providerState: "Permanent upload failure", confirmationCount: 1, attemptCount: 0, disposition: .observing)
        try await fixture.repository.upsert(tracked)
        _ = try await fixture.engine.evaluateFile(file)
        let row = try #require(try await fixture.repository.findings(matching: nil).first)
        #expect(row.id == tracked.id && row.disposition == .observing && row.confirmationCount == 0)
        #expect(row.providerState.contains("-1005"))
        #expect(!(try await fixture.repository.events(limit: 20)).contains { $0.kind == .compatibility })
        await fixture.engine.stop()
    }

    @Test func offlineWatchedFolderLeavesItsRowsAlone() async throws {
        let directory = try TestDirectory(); defer { directory.remove() }
        let file = try directory.file("episode.mp4")
        let fixture = try EngineFixture(directory: directory, minimumStableAge: 600)
        try await fixture.start()
        _ = try await fixture.engine.evaluateFile(file)
        let observed = try #require(try await fixture.repository.findings(matching: nil).first)
        try FileManager.default.removeItem(at: directory.url)
        _ = try await fixture.engine.evaluateFile(file)
        try FileManager.default.createDirectory(at: directory.url, withIntermediateDirectories: true)
        #expect(try await fixture.repository.findings(matching: nil) == [observed])
        await fixture.engine.stop()
    }

    @Test func previouslySavedDuplicateIsRetiredEvenWhileExportIsYoung() async throws {
        let directory = try TestDirectory(); defer { directory.remove() }
        let file = try directory.file("episode.mp4")
        let fixture = try EngineFixture(directory: directory, minimumStableAge: 600)
        try await fixture.start()
        _ = try await fixture.engine.evaluateFile(file)
        let current = try #require(try await fixture.repository.findings(matching: nil).first)
        var old = current
        old.id = UUID(); old.fileSize = 1; old.lastCheckedAt = .distantPast
        try await fixture.repository.upsert(old)
        _ = try await fixture.engine.evaluateFile(file)
        let rows = try await fixture.repository.findings(matching: nil)
        #expect(rows.count == 2) // history is retained, not deleted
        #expect(rows.filter { $0.disposition == .observing }.map(\.id) == [current.id])
        #expect(rows.first { $0.id == old.id }?.disposition == .sourceChanged)
        #expect(await fixture.runner.paths.isEmpty)
        await fixture.engine.stop()
    }

    @Test func growingExportBecomesRepairableAfterStabilityAndTwoConfirmations() async throws {
        let directory = try TestDirectory(); defer { directory.remove() }
        let file = try directory.file("episode.mp4")
        let fixture = try EngineFixture(directory: directory, permanentFailure: true, minimumStableAge: 300)
        try await fixture.start()
        try await fixture.engine.acknowledgeBaseline(rootID: fixture.root.id)
        fixture.clock.advance(1)
        _ = try await fixture.engine.evaluateFile(file)
        let first = try #require(try await fixture.repository.findings(matching: nil).first)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("more exported frames".utf8)); try handle.close()
        _ = try await fixture.engine.evaluateFile(file)
        fixture.clock.advance(301)
        _ = try await fixture.engine.evaluateFile(file)
        var rows = try await fixture.repository.findings(matching: nil)
        #expect(rows.count == 1 && rows.first?.confirmationCount == 1)
        fixture.clock.advance(61)
        _ = try await fixture.engine.evaluateFile(file)
        rows = try await fixture.repository.findings(matching: nil)
        #expect(rows.count == 1 && rows.first?.id == first.id)
        #expect(rows.first?.disposition == .actionable)
        #expect(ManualRepairEligibility.canStart(try #require(rows.first)))
        await fixture.engine.stop()
    }

    @Test func equalFilenamesInDifferentFoldersRemainSeparate() async throws {
        let directory = try TestDirectory(); defer { directory.remove() }
        try FileManager.default.createDirectory(at: directory.url.appendingPathComponent("other"), withIntermediateDirectories: true)
        let first = try directory.file("episode.mp4")
        let second = try directory.file("other/episode.mp4")
        let fixture = try EngineFixture(directory: directory, minimumStableAge: 600)
        try await fixture.start()
        _ = try await fixture.engine.evaluateFile(first)
        _ = try await fixture.engine.evaluateFile(second)
        let rows = try await fixture.repository.findings(matching: .observing)
        #expect(Set(rows.map(\.canonicalPath)) == [first.path, second.path])
        await fixture.engine.stop()
    }

    @Test func growingExportKeepsOneCurrentFinding() async throws {
        let directory = try TestDirectory(); defer { directory.remove() }
        let file = try directory.file("episode.mp4")
        let fixture = try EngineFixture(directory: directory, minimumStableAge: 600)
        try await fixture.start()
        _ = try await fixture.engine.evaluateFile(file)
        let original = try #require(try await fixture.repository.findings(matching: nil).first)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("more exported frames".utf8))
        try handle.close()
        _ = try await fixture.engine.evaluateFile(file)
        let rows = try await fixture.repository.findings(matching: nil)
        #expect(rows.count == 1)
        #expect(rows.first?.id == original.id)
        #expect(rows.first?.fileSize == original.fileSize + 20)
        #expect(await fixture.runner.paths.isEmpty)
        await fixture.engine.stop()
    }

    @Test func scanKeepsPendingRepairEvenWhenSourceBecomesYoung() async throws {
        for edit in [false, true] {
            let directory = try TestDirectory(); defer { directory.remove() }
            let file = try directory.file("episode.mp4")
            let fixture = try EngineFixture(directory: directory, permanentFailure: true)
            try await fixture.start()
            _ = try await fixture.engine.evaluateFile(file)
            var finding = try #require(try await fixture.repository.findings(matching: nil).first)
            finding.disposition = .requeueUploading
            finding.retryPath = file.path + ".retry"
            try await fixture.repository.upsert(finding)
            if edit { try Data("new-version".utf8).write(to: file) }
            try await fixture.engine.scanNow()
            let rows = try await fixture.repository.findings(matching: nil)
            #expect(rows.count == 1)
            #expect(rows.first?.disposition == .requeueUploading)
            #expect(rows.first?.retryPath == finding.retryPath)
            await fixture.engine.stop()
        }
    }

    @Test func busyFileDoesNotAbortTheRestOfTheScan() async throws {
        let directory = try TestDirectory(); defer { directory.remove() }
        let busy = try directory.file("busy.mp4")
        let free = try directory.file("free.mp4")
        let access = RepairAccess()
        let fixture = try EngineFixture(directory: directory, access: access)
        try await fixture.start()
        try await access.withAccess(to: busy.path) {
            try await fixture.engine.scanNow()
        }
        #expect(await fixture.runner.paths == [free.path])
        await fixture.engine.stop()
    }

    @Test func testReconcileSkipsOldAndNonMedia() async throws {
        let directory = try TestDirectory()
        defer { directory.remove() }
        _ = try directory.file("old.mp4", modified: Date().addingTimeInterval(-8 * 86_400))
        let recent = try directory.file("recent.mp4")
        _ = try directory.file("clip_segment_0001.mp4")
        _ = try directory.file("notes.txt")
        let fixture = try EngineFixture(directory: directory)
        try await fixture.start()
        try await fixture.engine.reconcile()
        #expect(await fixture.runner.paths == [recent.path])
        #expect(try await fixture.repository.findings(matching: nil).isEmpty)
        await fixture.engine.stop()
    }

    @Test func testDebounceCollapsesBurst() async throws {
        let directory = try TestDirectory()
        defer { directory.remove() }
        let file = try directory.file("recent.mp4")
        let fixture = try EngineFixture(directory: directory)
        try await fixture.start()
        for _ in 0..<5 { await fixture.engine.note(path: file.path) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(await fixture.runner.paths == [file.path])
        await fixture.engine.stop()
    }

    @Test func testBaselineDoesNotUpgradeExistingRows() async throws {
        let directory = try TestDirectory()
        defer { directory.remove() }
        let file = try directory.file("episode.mp4")
        let fixture = try EngineFixture(directory: directory, permanentFailure: true)
        try await fixture.start()
        #expect(try await fixture.repository.roots().first?.baselineCompletedAt == nil)
        _ = try await fixture.engine.evaluateFile(file)
        #expect(try await fixture.repository.findings(matching: nil).first?.disposition == .observing)
        fixture.clock.advance(61)
        _ = try await fixture.engine.evaluateFile(file)
        let existing = try #require(try await fixture.repository.findings(matching: .existingNeedsReview).first)
        #expect(existing.confirmationCount == 2)
        try await fixture.engine.acknowledgeBaseline(rootID: fixture.root.id)
        #expect(try await fixture.repository.roots().first?.baselineCompletedAt != nil)
        #expect(try await fixture.repository.findings(matching: nil).first?.disposition == .existingNeedsReview)
        fixture.clock.advance(61)
        _ = try await fixture.engine.evaluateFile(file)
        #expect(try await fixture.repository.findings(matching: nil).first?.disposition == .existingNeedsReview)
        let original = try FileHandle(forReadingFrom: file)
        defer { try? original.close() }
        #expect(try original.readToEnd() == Data("test media placeholder".utf8))
        await fixture.engine.stop()
    }

    @Test func testBaselineSurvivesACompatibilityBlockAndRestart() async throws {
        let directory = try TestDirectory()
        defer { directory.remove() }
        let file = try directory.file("episode.mp4")
        let fixture = try EngineFixture(directory: directory, permanentFailure: true)
        try await fixture.start()
        _ = try await fixture.engine.evaluateFile(file)
        fixture.clock.advance(61)
        _ = try await fixture.engine.evaluateFile(file)
        #expect(try await fixture.repository.findings(matching: .existingNeedsReview).count == 1)
        await fixture.runner.setFailure(.incompatible)
        _ = try await fixture.engine.evaluateFile(file)
        try await fixture.engine.acknowledgeBaseline(rootID: fixture.root.id)
        #expect(try await fixture.repository.findings(matching: .compatibilityBlocked).count == 1)
        await fixture.engine.stop()
        try await fixture.engine.start(roots: fixture.repository.roots())
        await fixture.runner.setFailure(nil)
        _ = try await fixture.engine.evaluateFile(file)
        fixture.clock.advance(61)
        _ = try await fixture.engine.evaluateFile(file)
        #expect(try await fixture.repository.findings(matching: .existingNeedsReview).count == 1)
        #expect(try await fixture.repository.findings(matching: .actionable).isEmpty)
        await fixture.engine.stop()
    }

    @Test func testConfirmationRequiresSixtySecondsAndUnchangedVersion() async throws {
        let directory = try TestDirectory()
        defer { directory.remove() }
        let file = try directory.file("episode.mp4")
        let fixture = try EngineFixture(directory: directory, permanentFailure: true)
        try await fixture.start()
        try await fixture.engine.acknowledgeBaseline(rootID: fixture.root.id)
        _ = try await fixture.engine.evaluateFile(file)
        fixture.clock.advance(59)
        _ = try await fixture.engine.evaluateFile(file)
        #expect(try await fixture.repository.findings(matching: nil).first?.confirmationCount == 1)
        #expect(try await fixture.repository.findings(matching: .actionable).isEmpty)
        fixture.clock.advance(2)
        _ = try await fixture.engine.evaluateFile(file)
        #expect(try await fixture.repository.findings(matching: .actionable).count == 1)
        try FileManager.default.setAttributes([.modificationDate: fixture.clock.date()], ofItemAtPath: file.path)
        fixture.clock.advance(61)
        _ = try await fixture.engine.evaluateFile(file)
        let rows = try await fixture.repository.findings(matching: nil)
        #expect(rows.count == 2)
        #expect(rows.first?.confirmationCount == 1)
        #expect(rows.first?.disposition == .observing)
        #expect(rows.last?.disposition == .sourceChanged)
        await fixture.engine.stop()
    }

    @Test func testIncompatibleUnreadableAndThrownCommandsBlockWithoutInventingError() async throws {
        for failure in [FixtureRunner.Failure.incompatible, .empty, .throwsError, .nonzero] {
            let directory = try TestDirectory()
            defer { directory.remove() }
            let file = try directory.file("recent.mp4")
            let fixture = try EngineFixture(directory: directory, failure: failure)
            try await fixture.start()
            let decision = try await fixture.engine.evaluateFile(file)
            guard case .blocked(let reason) = decision else {
                Issue.record("Expected an explicit blocked decision")
                continue
            }
            #expect(!reason.isEmpty)
            let finding = try #require(try await fixture.repository.findings(matching: nil).first)
            #expect(finding.disposition == .compatibilityBlocked)
            #expect(finding.errorCode == nil)
            #expect(finding.confirmationCount == 0)
            #expect(try await fixture.repository.events().contains { $0.kind == .compatibility })
            await fixture.engine.stop()
        }
    }

    @Test func testNonlocalFailureCannotBecomeActionable() async throws {
        let directory = try TestDirectory()
        defer { directory.remove() }
        let file = try directory.file("remote.mp4")
        let fixture = try EngineFixture(directory: directory, permanentFailure: true, downloaded: false)
        try await fixture.start()
        try await fixture.engine.acknowledgeBaseline(rootID: fixture.root.id)
        _ = try await fixture.engine.evaluateFile(file)
        fixture.clock.advance(61)
        let decision = try await fixture.engine.evaluateFile(file)
        guard case .blocked(let reason) = decision else { Issue.record("Expected blocked local availability"); return }
        #expect(!reason.isEmpty)
        #expect(try await fixture.repository.findings(matching: .actionable).isEmpty)
        await fixture.engine.stop()
    }

    @Test func testReconcileFindsNestedRecentMediaAndSkipsOldFiles() async throws {
        let directory = try TestDirectory()
        defer { directory.remove() }
        let old = try directory.file("old.mp4", modified: Date().addingTimeInterval(-9 * 86_400))
        let nested = directory.url.appendingPathComponent("2026/episode", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let nestedFile = nested.appendingPathComponent("nested.mp4")
        try Data("nested fixture".utf8).write(to: nestedFile)
        let fixture = try EngineFixture(directory: directory, permanentFailure: true)
        try await fixture.start()
        try await fixture.engine.reconcile()
        let reconciled = await fixture.runner.paths
        #expect(reconciled == [nestedFile.path])
        #expect(!reconciled.contains(old.path))
        _ = try await fixture.engine.evaluateFile(old)
        fixture.clock.advance(61)
        try await fixture.engine.scanNow()
        let scanned = await fixture.runner.paths
        #expect(scanned.filter { $0 == nestedFile.path }.count >= 1)
        #expect(scanned.filter { $0 == old.path }.count == 2)
        await fixture.engine.stop()
    }

    @Test func testPauseCancelsPendingEventsAndResumeRestartsWatcher() async throws {
        let directory = try TestDirectory()
        defer { directory.remove() }
        let file = try directory.file("recent.mp4")
        let fixture = try EngineFixture(directory: directory)
        try await fixture.start()
        await fixture.engine.note(path: file.path)
        await fixture.engine.pause()
        fixture.watcher.push(file.path)
        try await fixture.engine.reconcile()
        try await Task.sleep(for: .milliseconds(100))
        #expect(await fixture.runner.paths.isEmpty)
        #expect(fixture.watcher.stopCount > 0)
        try await fixture.engine.resume()
        fixture.watcher.push(file.path)
        try await Task.sleep(for: .milliseconds(200))
        #expect(await fixture.runner.paths.count >= 1)
        #expect(await fixture.runner.paths.allSatisfy { $0 == file.path })
        #expect(fixture.watcher.startCount == 2)
        await fixture.engine.stop()
    }

    @Test func testYoungFileIsListedWithoutAProviderCommand() async throws {
        let directory = try TestDirectory()
        defer { directory.remove() }
        let file = try directory.file("fresh.mp4")
        let fixture = try EngineFixture(directory: directory, minimumStableAge: 600)
        try await fixture.start()
        let decision = try await fixture.engine.evaluateFile(file)
        guard case .rejected = decision else {
            Issue.record("A file inside the stability window is not confirmed yet")
            return
        }
        let finding = try #require(try await fixture.repository.findings(matching: .observing).first)
        #expect(finding.filename == "fresh.mp4")
        #expect(finding.eligibilityBlockReason?.contains("Confirmation waits") == true)
        #expect(finding.errorCode == nil)
        #expect(await fixture.runner.paths.isEmpty)
        await fixture.engine.stop()
    }

    @Test func testRejectedExplicitPathNeverRunsACommand() async throws {
        let directory = try TestDirectory()
        defer { directory.remove() }
        let segment = try directory.file("clip_segment_0001.mp4")
        let fixture = try EngineFixture(directory: directory)
        try await fixture.start()
        let result = try await fixture.engine.handle(path: segment.path)
        #expect(result == .rejected(reason: "Not an eligible media candidate."))
        #expect(await fixture.runner.paths.isEmpty)
        await fixture.engine.stop()
    }
}

private struct TestDirectory {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("DriveMonitorTests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }
    func file(_ name: String, modified: Date = Date()) throws -> URL {
        let url = url.appendingPathComponent(name)
        try Data("test media placeholder".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        return url
    }
    func remove() {
        do { try FileManager.default.removeItem(at: url) }
        catch { Issue.record("Failed to remove only the test-created directory: \(error)") }
    }
}

private struct EngineFixture {
    let repository: FindingRepository
    let runner: FixtureRunner
    let watcher: MemoryWatcher
    let clock: TestClock
    let root: WatchedRootSnapshot
    let engine: MonitoringEngine

    init(directory: TestDirectory, permanentFailure: Bool = false, downloaded: Bool = true, failure: FixtureRunner.Failure? = nil, minimumStableAge: TimeInterval = 0, access: RepairAccess = RepairAccess(), forcedClassification: EvaluationClassification? = nil, store makeStore: ((FindingRepository) -> any FindingStoring)? = nil) throws {
        let repository = try FindingRepository(inMemory: true)
        let runner = FixtureRunner(failure: failure)
        let watcher = MemoryWatcher()
        let clock = TestClock()
        self.repository = repository
        self.runner = runner
        self.watcher = watcher
        self.clock = clock
        root = WatchedRootSnapshot(id: UUID(), path: directory.url.path, displayName: "Fixture", enabled: true,
            extensions: ["mp4"], ignorePatterns: [], minimumStableAge: minimumStableAge, automaticRequeueEnabled: false)
        let interpreting = EvaluationInterpreting(
            parse: { output in
                guard output == FixtureRunner.uploaded else { return .incompatible(reason: "Unknown fixture output.") }
                return .item(FileProviderItemState(isDownloaded: downloaded, isUploaded: !permanentFailure,
                    itemIdentifier: "fixture-item", uploadingErrorDomain: permanentFailure ? "NSFileProviderErrorDomain" : nil,
                    uploadingErrorCode: permanentFailure ? -2005 : nil))
            },
            classify: { parsed in
                if let forcedClassification, case .item = parsed { return forcedClassification }
                return switch parsed {
                case .item: permanentFailure ? .permanentFailure(domain: "NSFileProviderErrorDomain", code: -2005) : .uploaded
                case .missingItem: .missingItem
                case .incompatible(let reason): .incompatible(reason: reason)
                }
            },
            isActionablePermanentFailure: { $0.isDownloaded == true && $0.isUploaded == false && $0.uploadingErrorCode == -2005 },
            candidate: { path, _ in
                path.hasSuffix(".mp4") && !path.contains("_segment_") ? .accept : .reject(reason: "Not an eligible media candidate.")
            },
            confirm: { previous, _, _, baselineComplete in
                let count = (previous?.confirmationCount ?? 0) + 1
                return ConfirmationState(disposition: count < 2 ? .observing : (baselineComplete ? .actionable : .existingNeedsReview), confirmationCount: count)
            }
        )
        engine = MonitoringEngine(store: makeStore?(repository) ?? repository, repairAccess: access, saveRoot: { try await repository.save(root: $0) },
            saveBaseline: { try await repository.setBaseline(rootID: $0, at: $1) }, runner: runner,
            interpreting: interpreting, watcherFactory: { watcher }, debounce: .milliseconds(50),
            schedulesReconciliation: false, now: { clock.date() })
    }

    func start() async throws { try await engine.start(roots: [root]) }
}

private actor FixtureRunner: CommandRunning {
    enum Failure: Sendable { case incompatible, empty, throwsError, nonzero }
    static let uploaded = "{ fileproviderItems = ({ isUploaded = 1; }); }"
    var failure: Failure?
    private(set) var paths: [String] = []
    init(failure: Failure?) { self.failure = failure }
    func setFailure(_ failure: Failure?) { self.failure = failure }
    func run(executable: URL, arguments: [String]) async throws -> CommandResult {
        #expect(executable.path == "/usr/bin/fileproviderctl")
        #expect(arguments.count == 2 && arguments[0] == "evaluate")
        paths.append(arguments[1])
        if failure == .throwsError { throw MonitoringError.blocked(reason: "Fixture command failure.") }
        return CommandResult(exitCode: failure == .nonzero ? 1 : 0,
            standardOutput: failure == .incompatible ? "unrecognized" : (failure == .empty ? "" : Self.uploaded), standardError: "")
    }
}

/// A store whose path lookups fail, standing in for a database error during an event-driven check.
private struct FailingLookups: FindingStoring {
    let base: FindingRepository
    func upsert(_ finding: FindingSnapshot) async throws { try await base.upsert(finding) }
    func findings(matching disposition: FindingDisposition?) async throws -> [FindingSnapshot] { try await base.findings(matching: disposition) }
    func findings(at path: String) async throws -> [FindingSnapshot] { throw CocoaError(.fileReadUnknown) }
    func append(_ event: ActivityEvent) async throws { try await base.append(event) }
}

private final class MemoryWatcher: DirectoryWatching, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (String) -> Void)?
    private var starts = 0
    private var stops = 0
    var startCount: Int { lock.withLock { starts } }
    var stopCount: Int { lock.withLock { stops } }
    func start(root: URL, handler: @escaping @Sendable (String) -> Void) throws {
        lock.withLock { self.handler = handler; starts += 1 }
    }
    func stop() { lock.withLock { handler = nil; stops += 1 } }
    func push(_ path: String) { lock.withLock { handler }?(path) }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date()
    func date() -> Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
}

@Suite struct AuditEngineEdgeCases {
    @Test func savedUnavailableRootIsRetriedWhenItReturns() async throws {
        let directory = try TestDirectory(); defer { directory.remove() }
        let fixture = try EngineFixture(directory: directory)
        try FileManager.default.removeItem(at: directory.url)
        try await fixture.engine.start(roots: [fixture.root], persist: false, allowUnavailable: true)
        #expect(await fixture.engine.unavailableRootIDs.contains(fixture.root.id))
        try FileManager.default.createDirectory(at: directory.url, withIntermediateDirectories: true)
        _ = try directory.file("returned.mp4", modified: fixture.clock.date().addingTimeInterval(-10))
        try await fixture.engine.reconcile()
        #expect(await fixture.engine.unavailableRootIDs.isEmpty)
        #expect(await fixture.runner.paths.count == 1)
        await fixture.engine.stop()
    }

    @Test func scheduledReconcileMustRecheckKnownFailureOutsideDiscoveryWindow() async throws {
        let directory = try TestDirectory(); defer { directory.remove() }
        let file = try directory.file("episode.mp4", modified: Date().addingTimeInterval(-8 * 86400))
        let fixture = try EngineFixture(directory: directory, permanentFailure: true)
        try await fixture.start()
        _ = try await fixture.engine.evaluateFile(file)
        let before = await fixture.runner.paths.count
        try await fixture.engine.reconcile()
        let after = await fixture.runner.paths.count
        print("AUDIT old known failure: provider checks before reconcile = \(before), after = \(after)")
        #expect(after > before)
        await fixture.engine.stop()
    }
}
