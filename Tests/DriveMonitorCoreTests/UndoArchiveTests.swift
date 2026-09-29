import Foundation
import Testing
@testable import DriveMonitorCore

@Suite struct UndoArchiveTests {
    @Test func testArchiveRestoresTheOriginalAndParksTheReplacement() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".test-runs/undo-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = folder.appendingPathComponent("episode.mp4")
        try Data("original-bytes".utf8).write(to: original)
        let findingID = UUID()
        let record = try UndoArchive.store(file: original, findingID: findingID, root: root, now: Date(timeIntervalSince1970: 1_000))
        #expect(!FileManager.default.fileExists(atPath: original.path))
        try Data("uploaded-bytes".utf8).write(to: original)
        let restored = try UndoArchive.restore(record, root: root)
        #expect(restored.resolvingSymlinksInPath().path == original.resolvingSymlinksInPath().path)
        #expect(try Data(contentsOf: original) == Data("original-bytes".utf8))
        #expect(UndoArchive.restorableRecord(findingID: findingID, root: root, now: Date(timeIntervalSince1970: 1_000)) == nil)
        let removed = try UndoArchive.purgeExpired(root: root, now: Date(timeIntervalSince1970: 1_000).addingTimeInterval(UndoArchive.retention + 1))
        #expect(removed == 1)
    }

    @Test func testExpiredArchiveIsRemoved() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".test-runs/undo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("old.mp4")
        try Data("old".utf8).write(to: file)
        let archivedAt = Date(timeIntervalSince1970: 1_000)
        _ = try UndoArchive.store(file: file, findingID: UUID(), root: root, now: archivedAt)
        let removed = try UndoArchive.purgeExpired(root: root, now: archivedAt.addingTimeInterval(UndoArchive.retention + 1))
        #expect(removed == 1)
        let remaining = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        #expect(remaining.isEmpty)
    }
}
