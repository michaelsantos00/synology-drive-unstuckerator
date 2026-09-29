import Foundation
import Testing
@testable import DriveMonitorCore

@Suite struct RetryFinalizerTests {
    @Test func testConfirmedUploadReplacesTheOriginalName() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".test-runs/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("episode.mp4")
        let retry = root.appendingPathComponent("episode.__requeued-20260923-140311.mp4")
        try Data("original".utf8).write(to: original)
        try Data("uploaded".utf8).write(to: retry)
        let identity = try FileManager.default.attributesOfItem(atPath: original.path)
        let inode = (identity[.systemFileNumber] as? NSNumber)?.uint64Value
        let modified = identity[.modificationDate] as? Date
        let result = RetryFinalizer.system().finish(
            original: original,
            retry: retry,
            expectedInode: try #require(inode),
            expectedSize: Int64("original".utf8.count),
            expectedModified: try #require(modified)
        )
        #expect(result == .replaced(original))
        #expect(try Data(contentsOf: original) == Data("uploaded".utf8))
        #expect(!FileManager.default.fileExists(atPath: retry.path))
    }

    @Test func testChangedOriginalIsKept() {
        let original = URL(fileURLWithPath: "/cloud/episode.mp4")
        let retry = URL(fileURLWithPath: "/cloud/episode.__requeued.mp4")
        let removed = RemovalFlag()
        let finalizer = RetryFinalizer(
            identity: { url in
                if url == original {
                    return RetryFileIdentity(exists: true, inode: 9, fileSize: 10, modificationTime: Date(timeIntervalSince1970: 50))
                }
                return RetryFileIdentity(exists: true, inode: 4, fileSize: 10, modificationTime: Date(timeIntervalSince1970: 1))
            },
            remove: { _ in removed.mark() },
            move: { _, _ in }
        )
        let result = finalizer.finish(
            original: original,
            retry: retry,
            expectedInode: 3,
            expectedSize: 10,
            expectedModified: Date(timeIntervalSince1970: 1)
        )
        guard case .leftInPlace = result else {
            Issue.record("A changed original must be kept")
            return
        }
        #expect(!removed.value)
    }

    @Test func testRenameFailureReportsTheUploadedCopy() {
        let original = URL(fileURLWithPath: "/cloud/episode.mp4")
        let retry = URL(fileURLWithPath: "/cloud/episode.__requeued.mp4")
        let when = Date(timeIntervalSince1970: 1)
        let finalizer = RetryFinalizer(
            identity: { url in
                let inode: UInt64 = url == original ? 3 : 4
                return RetryFileIdentity(exists: true, inode: inode, fileSize: 10, modificationTime: when)
            },
            remove: { _ in },
            move: { _, _ in throw RetryFinalizerError.destinationOccupied(original.path) }
        )
        let result = finalizer.finish(original: original, retry: retry, expectedInode: 3, expectedSize: 10, expectedModified: when)
        guard case .originalRemoved(let retryURL, let reason) = result else {
            Issue.record("Expected the uploaded copy to be reported after a failed rename")
            return
        }
        #expect(retryURL == retry)
        #expect(reason.contains(retry.path))
    }
}

private final class RemovalFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var marked = false
    func mark() { lock.lock(); marked = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return marked }
}
