import Foundation
import Testing
@testable import DriveMonitorCore

@Suite struct UndoArchiveTests {
    @Test func verifiedUndoRetainsParkedPayloadWithoutInheritedExpiry() throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original.mp4")
        try Data("original".utf8).write(to: original)
        let findingID = UUID()
        let replacement = root.appendingPathComponent("replacement.mp4")
        try Data("uploaded".utf8).write(to: replacement)
        let record = try UndoArchive.store(file: original, findingID: findingID, root: root.appendingPathComponent("Undo"),
            now: Date(timeIntervalSince1970: 1000), operationID: UUID(), expectedReplacementSHA256: FileIntegrity.sha256(replacement))
        try FileIntegrity.moveExclusively(replacement, original)
        let undoRoot = root.appendingPathComponent("Undo")
        try UndoArchive.armExpiry(id: record.id, root: undoRoot, now: Date(timeIntervalSince1970: 1000))
        _ = try UndoArchive.restore(record, root: undoRoot, now: Date(timeIntervalSince1970: 1000 + UndoArchive.retention - 60))
        #expect(try String(contentsOf: original, encoding: .utf8) == "original")
        #expect(try UndoArchive.purgeExpired(root: undoRoot, now: .distantFuture) == 0)
        let parked = UndoArchive.records(in: undoRoot).filter { $0.id != record.id }
        #expect(parked.count == 1)
        #expect(try String(contentsOf: UndoArchive.payloadURL(#require(parked.first), root: undoRoot), encoding: .utf8) == "uploaded")
    }

    @Test func changedOccupantAndLegacyArchiveFailClosed() throws {
        for legacy in [true, false] {
            let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
            let original = root.appendingPathComponent("file.mp4")
            try Data("A".utf8).write(to: original)
            let undoRoot = root.appendingPathComponent("Undo")
            let record = try UndoArchive.store(file: original, findingID: UUID(), root: undoRoot,
                operationID: legacy ? nil : UUID(), expectedReplacementSHA256: legacy ? nil : "committed-hash")
            try Data("C-new-unique-edit".utf8).write(to: original)
            #expect(throws: UndoArchiveError.self) { try UndoArchive.restore(record, root: undoRoot) }
            #expect(try UndoArchive.purgeExpired(root: undoRoot, now: .distantFuture) == 0)
            #expect(try String(contentsOf: original, encoding: .utf8) == "C-new-unique-edit")
            #expect(try String(contentsOf: UndoArchive.payloadURL(record, root: undoRoot), encoding: .utf8) == "A")
        }
    }

    @Test func onlyCompletedUnchangedArchiveExpires() throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("file.mp4")
        try Data("A".utf8).write(to: original)
        let hash = try FileIntegrity.sha256(original)
        let undoRoot = root.appendingPathComponent("Undo")
        let record = try UndoArchive.store(file: original, findingID: UUID(), root: undoRoot,
            operationID: UUID(), expectedReplacementSHA256: hash)
        try Data("A".utf8).write(to: original)
        #expect(try UndoArchive.purgeExpired(root: undoRoot, now: .distantFuture) == 0)
        try UndoArchive.armExpiry(id: record.id, root: undoRoot)
        #expect(try UndoArchive.purgeExpired(root: undoRoot, now: .distantFuture) == 1)
    }

    private func temporaryRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
