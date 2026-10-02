import Darwin
import Foundation
import Testing
@testable import DriveMonitorCore

@Suite struct RepairRecoveryTests {
    @Test func invalidRecoveryChoiceLeavesPublishedVerificationAvailable() async throws {
        let fixture = try RepairFixture(); defer { fixture.remove() }
        var record = try await fixture.publish()
        record.phase = .published; try fixture.store.save(record)
        let service = RepairRecovery(operations: fixture.store, access: RepairAccess(), undoRoot: fixture.undo)
        await #expect(throws: MonitoringError.self) {
            try await service.resolve(#require(record.finding), choice: .restoreArchivedOriginal)
        }
        #expect(try fixture.store.records().first?.phase == .published)
        #expect(FileManager.default.fileExists(atPath: try #require(record.publishedPath)))
    }

    @Test func expiryWriteFailureDoesNotUndoDurableCompletion() async throws {
        for writeLanded in [false, true] {
            let fixture = try RepairFixture(); defer { fixture.remove() }
            let record = try await fixture.publish()
            var finalizer = RetryFinalizer()
            finalizer.armExpiry = { id, root in
                if writeLanded { try UndoArchive.armExpiry(id: id, root: root) }
                throw CocoaError(.fileWriteUnknown)
            }
            let result = finalizer.finish(record: record, undoRoot: fixture.undo, persist: fixture.store.save)
            guard case .replacedWithWarning = result else { Issue.record("Completion must survive an expiry warning"); continue }
            #expect(try fixture.store.records().first?.phase == .succeeded)
            #expect(UndoArchive.records(in: fixture.undo).first?.purgeAllowed == writeLanded)
            #expect(try String(contentsOf: fixture.original, encoding: .utf8) == "original-bytes")
        }
    }

    @Test func readOnlyFilesCanPublishFinalizeUndoAndResolve() async throws {
        let fixture = try RepairFixture(); defer { fixture.remove() }
        #expect(chmod(fixture.original.path, 0o444) == 0)
        let record = try await fixture.publish()
        #expect(record.phase == .uploadAcknowledged)
        #expect(RetryFinalizer().finish(record: record, undoRoot: fixture.undo, persist: fixture.store.save) == .replaced(fixture.original))
        let service = RepairRecovery(operations: fixture.store, access: RepairAccess(), undoRoot: fixture.undo)
        let restored = try await service.undo(#require(record.finding))
        #expect(restored.disposition == .resolved)
        #expect(try String(contentsOf: fixture.original, encoding: .utf8) == "original-bytes")
        let pending = try RepairFixture(); defer { pending.remove() }
        #expect(chmod(pending.original.path, 0o444) == 0)
        let retry = try await pending.publish { _ in "fileproviderItems = ({ isUploaded = 0; isUploading = 1; });" }
        let resolver = RepairRecovery(operations: pending.store, access: RepairAccess(), undoRoot: pending.undo)
        let observing = try await resolver.resolve(#require(retry.finding), choice: .keepCurrentOriginal)
        #expect(observing.disposition == .observing)
        #expect(observing.retryPath == nil)
        #expect(try String(contentsOf: pending.original, encoding: .utf8) == "original-bytes")
    }

    @Test func undoStartsAFreshObservationOfTheRestoredOriginal() async throws {
        let fixture = try RepairFixture(); defer { fixture.remove() }
        let record = try await fixture.publish()
        #expect(RetryFinalizer().finish(record: record, undoRoot: fixture.undo, persist: fixture.store.save) == .replaced(fixture.original))
        let service = RepairRecovery(operations: fixture.store, access: RepairAccess(), undoRoot: fixture.undo)
        let closed = try await service.undo(#require(record.finding))
        let next = try #require(try fixture.store.records().first { $0.id == record.id }?.nextFinding)
        let restored = try FileIntegrity.sourceVersion(fixture.original)
        #expect(closed.disposition == .resolved && closed.hasRepairEvidence)
        #expect(next.id != closed.id && next.disposition == .observing && !next.hasRepairEvidence)
        #expect(next.inode == restored.inode && next.fileSize == restored.fileSize)
        // Monitoring checks it again and Fix stays available, but this version already used its automatic attempt.
        #expect(AutomaticRepairCoordinator.hasOperation(for: next, in: try fixture.store.records()))
    }

    @Test func refusedUndoKeepsCompletedOperationAndExpiry() async throws {
        let fixture = try RepairFixture(); defer { fixture.remove() }
        let record = try await fixture.publish()
        #expect(RetryFinalizer().finish(record: record, undoRoot: fixture.undo, persist: fixture.store.save) == .replaced(fixture.original))
        let finding = try #require(record.finding)
        let archive = try #require(UndoArchive.restorableRecord(findingID: finding.id, root: fixture.undo))
        try Data("newer-unique-edit".utf8).write(to: fixture.original)
        let service = RepairRecovery(operations: fixture.store, access: RepairAccess(), undoRoot: fixture.undo)
        await #expect(throws: UndoArchiveError.changedOccupant) { try await service.undo(finding) }
        #expect(try fixture.store.records().first?.phase == .succeeded)
        #expect(UndoArchive.records(in: fixture.undo).first?.expiresAt == archive.expiresAt)
        #expect(UndoArchive.records(in: fixture.undo).first?.purgeAllowed == true)
        #expect(try String(contentsOf: fixture.original, encoding: .utf8) == "newer-unique-edit")
    }

    @Test func explicitKeepCurrentArchivesRetryAndReleasesPath() async throws {
        let fixture = try RepairFixture(); defer { fixture.remove() }
        var record = try await fixture.publish()
        record.phase = .recoveryRequired; try fixture.store.save(record)
        try Data("version-B".utf8).write(to: fixture.original)
        let service = RepairRecovery(operations: fixture.store, access: RepairAccess(), undoRoot: fixture.undo)
        let result = try await service.resolve(#require(record.finding), choice: .keepCurrentOriginal)
        #expect(result.disposition == .observing)
        #expect(result.retryPath == nil)
        #expect(try fixture.store.pending(path: record.source.canonicalPath) == nil)
        #expect(try String(contentsOf: fixture.original, encoding: .utf8) == "version-B")
        #expect(!FileManager.default.fileExists(atPath: try #require(record.publishedPath)))
        #expect(try UndoArchive.purgeExpired(root: fixture.undo, now: .distantFuture) == 0)
        let retained = try #require(UndoArchive.records(in: fixture.undo).first)
        #expect(try String(contentsOf: UndoArchive.payloadURL(retained, root: fixture.undo), encoding: .utf8) == "original-bytes")
    }

    @Test func interruptedFinalizationHasAnExplicitRestorePath() async throws {
        let fixture = try RepairFixture(); defer { fixture.remove() }
        let record = try await fixture.publish()
        var finalizer = RetryFinalizer()
        finalizer.move = { _, _ in throw CocoaError(.fileWriteNoPermission) }
        _ = finalizer.finish(record: record, undoRoot: fixture.undo, persist: fixture.store.save)
        let service = RepairRecovery(operations: fixture.store, access: RepairAccess(), undoRoot: fixture.undo)
        let result = try await service.resolve(#require(record.finding), choice: .restoreArchivedOriginal)
        #expect(result.disposition == .observing)
        #expect(result.retryPath == nil)
        #expect(try String(contentsOf: fixture.original, encoding: .utf8) == "original-bytes")
        #expect(try fixture.store.pending(path: record.source.canonicalPath) == nil)
        #expect(try UndoArchive.purgeExpired(root: fixture.undo, now: .distantFuture) == 0)
    }

    @Test func metadataOnlyProviderChangeRetainsDigestProtection() async throws {
        let fixture = try RepairFixture(); defer { fixture.remove() }
        let record = try await fixture.publish { path in
            #expect(chmod(path, 0o600) == 0)
            return "fileproviderItems = ({ isUploaded = 1; documentSize = 14; });"
        }
        #expect(record.phase == .uploadAcknowledged)
        #expect(RetryFinalizer().finish(record: record, undoRoot: fixture.undo, persist: fixture.store.save) == .replaced(fixture.original))
    }

    @Test func unreadableJournalPreservesReadOnlyInventoryButBlocksRepair() async throws {
        let fixture = try RepairFixture(); defer { fixture.remove() }
        let record = try await fixture.publish()
        let bad = fixture.store.root.appendingPathComponent("broken.json")
        try Data("{ truncated".utf8).write(to: bad)
        #expect(try fixture.store.knownRecords().map(\.id) == [record.id])
        let unreadable = try fixture.store.inventory().unreadable.map { $0.standardizedFileURL.resolvingSymlinksInPath().path }
        #expect(unreadable == [bad.standardizedFileURL.resolvingSymlinksInPath().path])
        #expect(throws: MonitoringError.self) { try fixture.store.pending(path: "/unrelated/path") }
    }

    @Test func temporarilyMissingOriginalDoesNotPermanentlyDisableExpiry() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file.mp4")
        try Data("A".utf8).write(to: file)
        let hash = try FileIntegrity.sha256(file)
        let undo = root.appendingPathComponent("Undo")
        let record = try UndoArchive.store(file: file, findingID: UUID(), root: undo, operationID: UUID(), expectedReplacementSHA256: hash)
        try UndoArchive.armExpiry(id: record.id, root: undo)
        #expect(try UndoArchive.purgeExpired(root: undo, now: .distantFuture) == 0)
        #expect(UndoArchive.records(in: undo).first?.purgeAllowed == true)
        try Data("A".utf8).write(to: file)
        #expect(try UndoArchive.purgeExpired(root: undo, now: .distantFuture) == 1)
    }
}
