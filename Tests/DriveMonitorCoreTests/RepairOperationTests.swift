import Foundation
import Testing
@testable import DriveMonitorCore

@Suite struct RepairOperationTests {
    @Test func pollingFailureRetainsPublishedPhaseAcrossReload() async throws {
        let fixture = try RepairFixture(); defer { fixture.remove() }
        let journal = try await fixture.publish { _ in throw CocoaError(.fileReadUnknown) }
        #expect(journal.phase == .published)
        #expect(journal.message?.contains("verification") == true)
        let reloaded = try RepairOperationStore(root: fixture.store.root)
        #expect(try reloaded.pending(path: fixture.original.path)?.publishedPath == journal.publishedPath)
        #expect(FileManager.default.fileExists(atPath: try #require(journal.publishedPath)))
    }

    @Test func changedSourceResumeRefusesAndKeepsBothVersions() async throws {
        let fixture = try RepairFixture(); defer { fixture.remove() }
        let record = try await fixture.publish { _ in "fileproviderItems = ({ isUploaded = 0; isUploading = 1; });" }
        try Data("newer-B".utf8).write(to: fixture.original)
        let report = await RequeueExecutor.verify(record: record, effects: .system(), evaluate: { _ in
            Issue.record("Changed source must stop before provider evaluation"); return ""
        }, persist: { try fixture.store.save($0) })
        guard case .recoveryRequired = report.outcome else { Issue.record("Expected recovery"); return }
        #expect(try String(contentsOf: fixture.original, encoding: .utf8) == "newer-B")
        #expect(FileManager.default.fileExists(atPath: try #require(record.publishedPath)))
    }

    @Test func publicationCheckpointFailuresStopSubsequentSideEffects() async throws {
        for phase in [RequeuePhase.planned, .stagingPrepared, .clonedOrCopied, .hashed, .publishing, .published] {
            let fixture = try RepairFixture(); defer { fixture.remove() }
            let plan = PublicationPlan(operationID: UUID(), source: try FileIntegrity.sourceVersion(fixture.original), retryFileName: "retry.mp4", allowFullCopyFallback: true)
            let report = await RequeueExecutor.publish(decision: .publish(plan), plan: plan, sourceURL: fixture.original,
                stagingRoot: fixture.root.appendingPathComponent("Staging"), targetDirectory: fixture.root,
                openForWriting: false, effects: .system(), evaluate: { _ in Issue.record("Must not evaluate after failed save"); return "" },
                persist: { record in
                    if record.phase == phase { throw CocoaError(.fileWriteNoPermission) }
                    try fixture.store.save(record)
                })
            #expect(try String(contentsOf: fixture.original, encoding: .utf8) == "original-bytes")
            #expect(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("retry.mp4").path) == (phase == .published))
            if case .uploaded = report.outcome { Issue.record("No uploaded outcome after failed persistence") }
        }
    }

    @Test func identityChangeDuringProviderAcknowledgementBlocksFinalization() async throws {
        let fixture = try RepairFixture(); defer { fixture.remove() }
        let journal = try await fixture.publish { path in
            try Data("different-new".utf8).write(to: URL(fileURLWithPath: path))
            return "fileproviderItems = ({ isUploaded = 1; documentSize = 13; });"
        }
        #expect(journal.phase == .published)
        #expect(journal.uploadVerifiedAt == nil)
        #expect(try String(contentsOf: fixture.original, encoding: .utf8) == "original-bytes")
    }

    @Test func resetPreservesRepairAndUndoFindingIDs() async throws {
        let repository = try FindingRepository(inMemory: true)
        var finding = sampleFinding()
        finding.retryPath = "/fixture/retry.mp4"; finding.disposition = .requeueUploading
        var undo = sampleFinding(); undo.disposition = .requeueSucceeded
        let other = sampleFinding()
        for row in [finding, undo, other] { try await repository.upsert(row) }
        try await repository.eraseDiscoveredItems(preserving: [undo.id])
        #expect(Set(try await repository.findings(matching: nil).map(\.id)) == [finding.id, undo.id])
    }

    @Test func repeatVerificationOfUnchangedFilesDoesNotReadThemAgain() async throws {
        let fixture = try RepairFixture(); defer { fixture.remove() }
        let waiting: @Sendable (String) async throws -> String = { _ in "fileproviderItems = ({ isUploaded = 0; isUploading = 1; });" }
        let record = try await fixture.publish(evaluate: waiting)
        let reads = ReadLog()
        let system = RequeueEffects.system()
        var effects = system
        effects.hashFile = { url in reads.add(url.lastPathComponent); return try await system.hashFile(url) }
        for _ in 0..<3 {
            let report = await RequeueExecutor.verify(record: record, effects: effects, evaluate: waiting, persist: { try fixture.store.save($0) })
            #expect(report.outcome == .verifying)
        }
        // Publication already read and verified both files in this process; nothing changed since.
        #expect(reads.count("original.mp4") == 0 && reads.count("retry.mp4") == 0)
        // Any write or metadata change moves the change time, which forces a fresh read.
        _ = fixture.original.withUnsafeFileSystemRepresentation { path in
            "1".withCString { setxattr(path, "com.example.touch", $0, 1, 0, 0) }
        }
        _ = await RequeueExecutor.verify(record: record, effects: effects, evaluate: waiting, persist: { try fixture.store.save($0) })
        #expect(reads.count("original.mp4") == 1 && reads.count("retry.mp4") == 0)
    }

    @Test func uploadErrorsOnTheRetryHandOffToBackgroundChecksAndClearWhenGone() async throws {
        let fixture = try RepairFixture(); defer { fixture.remove() }
        let offline = "fileproviderItems = ({ isUploaded = 0; uploadingError = \"Error Domain=NSFileProviderErrorDomain Code=-1005\"; });"
        let uploading = "fileproviderItems = ({ isUploaded = 0; isUploading = 1; });"
        let record = try await fixture.publish { _ in uploading }
        let calls = ReadLog()
        let report = await RequeueExecutor.verify(record: record, effects: .system(), evaluate: { _ in calls.add("evaluate"); return offline },
            maxPolls: 20, persist: { try fixture.store.save($0) })
        #expect(report.outcome == .verifying)
        #expect(calls.count("evaluate") == 4) // a minute of errors at 15 s, then the background checks take over
        #expect(report.journals.last?.message?.contains("-1005") == true)
        let responses = Responses([offline, uploading])
        let recovered = await RequeueExecutor.verify(record: record, effects: .system(), evaluate: { _ in await responses.next() },
            maxPolls: 2, persist: { try fixture.store.save($0) })
        #expect(recovered.outcome == .verifying && recovered.journals.last?.message == nil) // the error cleared
    }

    @Test func reviewDateDoesNotOverwriteRulesSavedMeanwhile() async throws {
        let repository = try FindingRepository(inMemory: true)
        let root = WatchedRootSnapshot(id: UUID(), path: "/fixture", displayName: "Fixture", enabled: true, extensions: ["mp4"],
            ignorePatterns: [], minimumStableAge: 300, automaticRequeueEnabled: false)
        try await repository.save(root: root)
        var edited = root
        edited.extensions = ["mov"]; edited.minimumStableAge = 900
        try await repository.replaceRoots([edited]) // rules applied while the review date was being saved
        let date = Date()
        try await repository.setBaseline(rootID: root.id, at: date)
        let saved = try #require(try await repository.roots().first)
        #expect(saved.extensions == ["mov"] && saved.minimumStableAge == 900)
        #expect(abs(try #require(saved.baselineCompletedAt).timeIntervalSince(date)) < 0.001)
    }

    @Test func resetKeepsIgnoreAndSetupDecisions() async throws {
        // Erasing these would let the same file return as a new failure that auto-fix may pick.
        let repository = try FindingRepository(inMemory: true)
        var ignored = sampleFinding(); ignored.disposition = .ignored
        var existing = sampleFinding(); existing.disposition = .existingNeedsReview
        var observing = sampleFinding(); observing.disposition = .observing
        let actionable = sampleFinding()
        for row in [ignored, existing, observing, actionable] { try await repository.upsert(row) }
        try await repository.eraseDiscoveredItems()
        #expect(Set(try await repository.findings(matching: nil).map(\.id)) == [ignored.id, existing.id])
    }

    @Test func releasedLeasesLeaveNoLockFilesAndPruneSkipsHeldOnes() async throws {
        let locks = FileManager.default.temporaryDirectory.appendingPathComponent("locks-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: locks) }
        let access = RepairAccess(lockRoot: locks)
        for index in 0..<5 { try await access.withAccess(to: "/fixture/\(index).mp4") {} }
        #expect(try FileManager.default.contentsOfDirectory(atPath: locks.path).isEmpty)
        // A stale file from an earlier build is pruned; a file someone holds is not.
        let stale = locks.appendingPathComponent("stale.lock").path
        #expect(FileManager.default.createFile(atPath: stale, contents: nil))
        let barrier = Barrier()
        let holder = Task { try await access.withAccess(to: "/fixture/held.mp4") { await barrier.wait() } }
        while !(await barrier.waiting) { await Task.yield() }
        RepairAccess.pruneStaleLocks(in: locks)
        #expect(try FileManager.default.contentsOfDirectory(atPath: locks.path).count == 1)
        await #expect(throws: RepairAccessError.self) { try await RepairAccess(lockRoot: locks).withAccess(to: "/fixture/held.mp4") {} }
        await barrier.release()
        try await holder.value
        #expect(try FileManager.default.contentsOfDirectory(atPath: locks.path).isEmpty)
    }

    @Test func leaseRemainsHeldAcrossSuspension() async throws {
        let access = RepairAccess()
        let barrier = Barrier()
        let first = Task { try await access.withAccess(to: "/fixture/a.mp4") { await barrier.wait(); return 1 } }
        while !(await barrier.waiting) { await Task.yield() }
        await #expect(throws: RepairAccessError.self) { try await access.withAccess(to: "/fixture/a.mp4") { 2 } }
        await barrier.release()
        #expect(try await first.value == 1)
        #expect(try await access.withAccess(to: "/fixture/a.mp4") { 3 } == 3)
    }

    @Test func separateGateInstancesShareTheDiskLease() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let firstGate = RepairAccess(lockRoot: root)
        let secondGate = RepairAccess(lockRoot: root)
        let barrier = Barrier()
        let first = Task { try await firstGate.withAccess(to: "/fixture/locked.mp4") { await barrier.wait(); return 1 } }
        while !(await barrier.waiting) { await Task.yield() }
        await #expect(throws: RepairAccessError.self) { try await secondGate.withAccess(to: "/fixture/locked.mp4") { 2 } }
        await barrier.release()
        #expect(try await first.value == 1)
        #expect(try await secondGate.withAccess(to: "/fixture/locked.mp4") { 3 } == 3)
    }

    private func sampleFinding() -> FindingSnapshot {
        FindingSnapshot(id: UUID(), canonicalPath: "/fixture/a.mp4", filename: "a.mp4", rootIdentifier: UUID(),
            fileSize: 1, modificationDate: Date(), firstDetectedAt: Date(), lastCheckedAt: Date(),
            providerState: "fixture", confirmationCount: 2, attemptCount: 0, disposition: .actionable)
    }
}
private actor Barrier {
    var continuation: CheckedContinuation<Void, Never>?
    var waiting: Bool { continuation != nil }
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

private final class ReadLog: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []
    func add(_ name: String) { lock.withLock { names.append(name) } }
    func count(_ name: String) -> Int { lock.withLock { names.filter { $0 == name }.count } }
}

private actor Responses {
    private var queue: [String]
    init(_ queue: [String]) { self.queue = queue }
    func next() -> String { queue.count > 1 ? queue.removeFirst() : queue[0] }
}
