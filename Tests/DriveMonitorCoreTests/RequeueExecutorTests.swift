import Foundation
import Testing
@testable import DriveMonitorCore

@Suite struct RequeueExecutorTests {
    @Test func testCloneLeavesOriginalBytesUnchanged() async throws {
        let fixture = try Scratch()
        let source = fixture.file("original.mp4", contents: Data("episode-bytes".utf8))
        let before = try Data(contentsOf: source)
        let plan = samplePlan()
        let report = await RequeueExecutor.publish(
            decision: .publish(plan),
            plan: plan,
            sourceURL: source,
            stagingRoot: fixture.root.appendingPathComponent("staging"),
            targetDirectory: fixture.root.appendingPathComponent("target"),
            openForWriting: false,
            effects: .system(),
            evaluate: { _ in uploadedEvaluation(identifier: "retry-1") },
            maxPolls: 1
        )
        #expect(report.outcome == .uploaded(itemIdentifier: "retry-1"))
        #expect(try Data(contentsOf: source) == before)
        let published = fixture.root.appendingPathComponent("target").appendingPathComponent(plan.retryFileName)
        #expect(FileManager.default.fileExists(atPath: published.path))
        #expect(try Data(contentsOf: published) == before)
    }

    @Test func testCrossVolumeBlocksBeforeCopy() async throws {
        let fixture = try Scratch()
        let source = fixture.file("original.mp4", contents: Data("episode-bytes".utf8))
        var effects = RequeueEffects.system()
        let clones = LockedCounter()
        effects.sameVolume = { _, _ in false }
        effects.cloneFile = { _, _ in
            clones.increment()
            return true
        }
        let plan = samplePlan()
        let report = await RequeueExecutor.publish(
            decision: .publish(plan),
            plan: plan,
            sourceURL: source,
            stagingRoot: fixture.root.appendingPathComponent("staging"),
            targetDirectory: fixture.root.appendingPathComponent("target"),
            openForWriting: false,
            effects: effects,
            evaluate: { _ in uploadedEvaluation(identifier: "should-not-run") }
        )
        #expect(report.outcome == .blocked(.crossVolume))
        #expect(clones.value == 0)
        #expect(try Data(contentsOf: source) == Data("episode-bytes".utf8))
    }

    @Test func testHashMismatchKeepsStaging() async throws {
        let fixture = try Scratch()
        let source = fixture.file("original.mp4", contents: Data("episode-bytes".utf8))
        var effects = RequeueEffects.system()
        effects.hashFile = { url in
            url.lastPathComponent == "original.mp4" ? "aaa" : "bbb"
        }
        let plan = samplePlan()
        let report = await RequeueExecutor.publish(
            decision: .publish(plan),
            plan: plan,
            sourceURL: source,
            stagingRoot: fixture.root.appendingPathComponent("staging"),
            targetDirectory: fixture.root.appendingPathComponent("target"),
            openForWriting: false,
            effects: effects,
            evaluate: { _ in uploadedEvaluation(identifier: "nope") }
        )
        #expect(report.outcome == .blocked(.hashMismatch))
        let staged = fixture.root
            .appendingPathComponent("staging")
            .appendingPathComponent(plan.operationID.uuidString)
            .appendingPathComponent(plan.retryFileName)
        #expect(FileManager.default.fileExists(atPath: staged.path))
    }

    @Test func testExistingDestinationDoesNotOverwrite() async throws {
        let fixture = try Scratch()
        let source = fixture.file("original.mp4", contents: Data("new".utf8))
        let plan = samplePlan()
        let target = fixture.root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let existing = target.appendingPathComponent(plan.retryFileName)
        try Data("keep-me".utf8).write(to: existing)
        let report = await RequeueExecutor.publish(
            decision: .publish(plan),
            plan: plan,
            sourceURL: source,
            stagingRoot: fixture.root.appendingPathComponent("staging"),
            targetDirectory: target,
            openForWriting: false,
            effects: .system(),
            evaluate: { _ in uploadedEvaluation(identifier: "nope") }
        )
        guard case .blocked(.publishFailed) = report.outcome else {
            Issue.record("Expected publish to stop, got \(report.outcome)")
            return
        }
        #expect(try Data(contentsOf: existing) == Data("keep-me".utf8))
    }

    @Test func testVerificationSucceedsOnlyWhenUploadedAndNoError() async throws {
        let uploading = """
        fileproviderItems = ( { isUploaded = 0; isUploading = 1; } );
        """
        let fixture = try Scratch()
        let source = fixture.file("original.mp4", contents: Data("episode-bytes".utf8))
        let responses = Responses(values: [uploading, uploadedEvaluation(identifier: "done-7")])
        let plan = samplePlan()
        let report = await RequeueExecutor.publish(
            decision: .publish(plan),
            plan: plan,
            sourceURL: source,
            stagingRoot: fixture.root.appendingPathComponent("staging"),
            targetDirectory: fixture.root.appendingPathComponent("target"),
            openForWriting: false,
            effects: .system(),
            evaluate: { _ in await responses.next() },
            maxPolls: 2
        )
        #expect(report.outcome == .uploaded(itemIdentifier: "done-7"))
    }

    @Test func testRetry2005DoesNotScheduleAnotherCopy() async throws {
        let fixture = try Scratch()
        let source = fixture.file("original.mp4", contents: Data("episode-bytes".utf8))
        let clones = LockedCounter()
        var effects = RequeueEffects.system()
        let originalClone = effects.cloneFile
        effects.cloneFile = { source, destination in
            clones.increment()
            return try originalClone(source, destination)
        }
        let plan = samplePlan()
        let report = await RequeueExecutor.publish(
            decision: .publish(plan),
            plan: plan,
            sourceURL: source,
            stagingRoot: fixture.root.appendingPathComponent("staging"),
            targetDirectory: fixture.root.appendingPathComponent("target"),
            openForWriting: false,
            effects: effects,
            evaluate: { _ in
                """
                fileproviderItems = ( { isUploaded = 0; isDownloading = 0; isDownloaded = 1; uploadingError = "Error Domain=NSFileProviderErrorDomain Code=-2005 \\"(null)\\""; } );
                """
            }
        )
        #expect(report.outcome == .retryFailed(code: -2005))
        #expect(clones.value == 1)
        #expect(try Data(contentsOf: source) == Data("episode-bytes".utf8))
    }

    private func samplePlan() -> PublicationPlan {
        PublicationPlan(
            operationID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            source: SourceVersionKey(
                canonicalPath: "/tmp/original.mp4",
                inode: 4,
                fileSize: 13,
                modificationTime: Date(timeIntervalSince1970: 10)
            ),
            retryFileName: "original.__requeued-20260923-204500.mp4",
            allowFullCopyFallback: true
        )
    }

    private func uploadedEvaluation(identifier: String) -> String {
        """
        fileproviderItems = ( { isUploaded = 1; isUploading = 0; itemIdentifier = "\(identifier)"; } );
        """
    }
}

private struct Scratch {
    let root: URL

    init() throws {
        root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".test-runs", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("target"), withIntermediateDirectories: true)
    }

    func file(_ name: String, contents: Data) -> URL {
        let url = root.appendingPathComponent(name)
        try? contents.write(to: url)
        return url
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private actor Responses {
    var values: [String]
    init(values: [String]) { self.values = values }
    func next() -> String { values.isEmpty ? "" : values.removeFirst() }
}
