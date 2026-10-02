import Foundation
import Testing
@testable import DriveMonitorCore

@Suite struct RetryFinalizerTests {
    @Test func committedBytesReplaceAndSurviveReload() async throws {
        let fixture = try RepairFixture()
        defer { fixture.remove() }
        let journal = try await fixture.publish()
        let result = RetryFinalizer.system().finish(record: journal, undoRoot: fixture.undo, persist: fixture.store.save)
        #expect(result == .replaced(fixture.original))
        #expect(try Data(contentsOf: fixture.original) == Data("original-bytes".utf8))
        #expect(try fixture.store.records().first?.phase == .succeeded)
        #expect(UndoArchive.records(in: fixture.undo).first?.purgeAllowed == true)
    }

    @Test func changedSourceCannotReplaceCommittedOriginal() async throws {
        let fixture = try RepairFixture(); defer { fixture.remove() }
        let journal = try await fixture.publish()
        try Data("newer-edit-B!!".utf8).write(to: fixture.original)
        let result = RetryFinalizer.system().finish(record: journal, undoRoot: fixture.undo, persist: fixture.store.save)
        guard case .leftInPlace = result else { Issue.record("Must preserve newer source"); return }
        #expect(try String(contentsOf: fixture.original, encoding: .utf8) == "newer-edit-B!!")
        #expect(UndoArchive.records(in: fixture.undo).isEmpty)
    }

    @Test func sameLengthInPlaceRetryEditCannotPassDigestGate() async throws {
        let fixture = try RepairFixture(); defer { fixture.remove() }
        var journal = try await fixture.publish()
        let retry = try #require(journal.publishedPath).fileURL
        let handle = try FileHandle(forWritingTo: retry)
        try handle.write(contentsOf: Data("changed-bytes!".utf8)); try handle.close()
        // Even if metadata is substituted or restored, the committed digest must reject new bytes.
        journal.retryIdentity = try FileIntegrity.identity(retry)
        let result = RetryFinalizer.system().finish(record: journal, undoRoot: fixture.undo, persist: fixture.store.save)
        guard case .leftInPlace = result else { Issue.record("Must reject changed retry bytes"); return }
        #expect(try String(contentsOf: fixture.original, encoding: .utf8) == "original-bytes")
    }

    @Test func failedRenameKeepsOriginalArchiveOutsideExpiry() async throws {
        let fixture = try RepairFixture(); defer { fixture.remove() }
        let journal = try await fixture.publish()
        var finalizer = RetryFinalizer()
        finalizer.move = { _, destination in throw RetryFinalizerError.destinationOccupied(destination.path) }
        let result = finalizer.finish(record: journal, undoRoot: fixture.undo, persist: fixture.store.save)
        guard case .originalRemoved = result else { Issue.record("Expected recovery"); return }
        #expect(try fixture.store.records().first?.phase == .finalizing)
        #expect(try UndoArchive.purgeExpired(root: fixture.undo, now: .distantFuture) == 0)
        let archive = try #require(UndoArchive.records(in: fixture.undo).first)
        #expect(try FileIntegrity.sha256(UndoArchive.payloadURL(archive, root: fixture.undo)) == journal.sourceSHA256)
    }

    @Test func journalFailureStopsNextMove() async throws {
        for phase in [RequeuePhase.archiving, .archived, .finalizing, .succeeded] {
            let fixture = try RepairFixture(); defer { fixture.remove() }
            let journal = try await fixture.publish()
            let result = RetryFinalizer().finish(record: journal, undoRoot: fixture.undo) { current in
                if current.phase == phase { throw CocoaError(.fileWriteNoPermission) }
                try fixture.store.save(current)
            }
            if case .replaced = result { Issue.record("Persistence failure must not report Fixed") }
            if phase == .archiving { #expect(FileManager.default.fileExists(atPath: fixture.original.path)) }
            if phase == .archived || phase == .finalizing {
                #expect(!FileManager.default.fileExists(atPath: fixture.original.path))
                #expect(FileManager.default.fileExists(atPath: try #require(journal.publishedPath)))
            }
            #expect(try UndoArchive.purgeExpired(root: fixture.undo, now: .distantFuture) == 0)
        }
    }
}

struct RepairFixture: Sendable {
    let root: URL
    let original: URL
    let undo: URL
    let store: RepairOperationStore
    init() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("repair-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        original = root.appendingPathComponent("original.mp4")
        undo = root.appendingPathComponent("Undo")
        store = try RepairOperationStore(root: root.appendingPathComponent("Journals"))
        try Data("original-bytes".utf8).write(to: original)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func publish(evaluate: @escaping @Sendable (String) async throws -> String = { _ in
        "fileproviderItems = ({ isUploaded = 1; isUploading = 0; itemIdentifier = retry1; documentSize = 14; });"
    }) async throws -> RequeueJournal {
        let plan = PublicationPlan(operationID: UUID(), source: try FileIntegrity.sourceVersion(original), retryFileName: "retry.mp4", allowFullCopyFallback: true)
        let report = await RequeueExecutor.publish(decision: .publish(plan), plan: plan, sourceURL: original,
            stagingRoot: root.appendingPathComponent("Staging"), targetDirectory: root, openForWriting: false,
            effects: .system(), evaluate: evaluate, persist: { try store.save($0) })
        var journal = try #require(report.journals.last)
        journal.finding = FindingSnapshot(id: UUID(), canonicalPath: plan.source.canonicalPath, filename: original.lastPathComponent,
            rootIdentifier: UUID(), inode: plan.source.inode, fileSize: plan.source.fileSize, modificationDate: plan.source.modificationTime,
            firstDetectedAt: Date(), lastCheckedAt: Date(), providerState: "fixture", confirmationCount: 2, attemptCount: 1,
            disposition: .requeueUploading, retryPath: journal.publishedPath)
        try store.save(journal)
        return journal
    }
}

private extension String { var fileURL: URL { URL(fileURLWithPath: self) } }
