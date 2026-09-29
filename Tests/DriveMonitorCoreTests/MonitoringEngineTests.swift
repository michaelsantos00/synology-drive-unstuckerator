import Foundation
import Testing
@testable import DriveMonitorCore

@Suite struct MonitoringEngineTests {
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
        #expect(await fixture.runner.paths == [file.path])
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

    init(directory: TestDirectory, permanentFailure: Bool = false, downloaded: Bool = true, failure: FixtureRunner.Failure? = nil, minimumStableAge: TimeInterval = 0) throws {
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
                switch parsed {
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
        engine = MonitoringEngine(store: repository, saveRoot: { try await repository.save(root: $0) }, runner: runner,
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
