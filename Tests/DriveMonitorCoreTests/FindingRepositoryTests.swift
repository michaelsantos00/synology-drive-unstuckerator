import Foundation
import Testing
@testable import DriveMonitorCore

@Suite struct FindingRepositoryTests {
    @Test func testRepositoryRoundTrip() async throws {
        let repository = try FindingRepository(inMemory: true)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let root = WatchedRootSnapshot(id: UUID(), path: "/fixture/media", displayName: "Media", enabled: true,
            extensions: ["mp4", "mov"], ignorePatterns: ["*_segment_*"], minimumStableAge: 60, automaticRequeueEnabled: false)
        var finding = FindingSnapshot(id: UUID(), canonicalPath: "/fixture/media/episode.mp4", filename: "episode.mp4",
            rootIdentifier: root.id, resourceIdentifier: Data([1, 2, 3]), inode: 42, fileProviderItemIdentifier: "provider-item",
            fileSize: 4096, modificationDate: date, firstDetectedAt: date, lastCheckedAt: date,
            lastConfirmedAt: date, errorDomain: "NSFileProviderErrorDomain", errorCode: -2005,
            providerState: "Permanent upload failure", confirmationCount: 2, attemptCount: 0,
            disposition: .existingNeedsReview, eligibilityBlockReason: "Review the first-launch baseline.",
            sourceSHA256: "source-fixture-hash", retryPath: "/fixture/media/retry.mp4", retryItemIdentifier: "retry-item",
            retrySHA256: "retry-fixture-hash", uploadVerifiedAt: date, rawDiagnostic: "fixture diagnostic")
        let event = ActivityEvent(id: UUID(), timestamp: date, kind: .findingDetected, findingID: finding.id,
            summary: "Existing upload failure", details: "First-launch baseline", result: "existingNeedsReview")
        try await repository.save(root: root)
        try await repository.upsert(finding)
        try await repository.append(event)
        #expect(try await repository.findings(matching: nil) == [finding])
        #expect(try await repository.findings(matching: .existingNeedsReview) == [finding])
        #expect(try await repository.findings(matching: .actionable).isEmpty)
        #expect(try await repository.events() == [event])
        #expect(try await repository.roots() == [root])
        finding.disposition = .ignored
        try await repository.upsert(finding)
        try await repository.append(event)
        #expect(try await repository.findings(matching: nil) == [finding])
        #expect(try await repository.events().count == 1)
        var acknowledged = root
        acknowledged.baselineCompletedAt = date
        try await repository.save(root: acknowledged)
        #expect(try await repository.roots() == [acknowledged])
        #expect(try await repository.findings(matching: nil).first?.disposition == .ignored)
    }

    @Test func testOnDiskStoreStaysOutsideCloudStorage() throws {
        let repository = try FindingRepository(inMemory: false)
        _ = repository
        let store = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Synology Drive Unstuckerator/Store/Findings.store")
        #expect(FileManager.default.fileExists(atPath: store.path))
        #expect(!store.path.contains("CloudStorage"))
    }
}
