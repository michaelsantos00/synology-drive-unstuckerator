import Foundation
import Testing
@testable import DriveMonitorCore

@Suite struct FindingRequeueTests {
    @Test func testUploadedRetryKeepsTheOriginalDispositionRecord() {
        var finding = sample()
        let report = ExecutionReport(
            outcome: .uploaded(itemIdentifier: "retry-item"),
            journals: [journal(.published, published: "/cloud/episode.__requeued-20260923-140311.mp4")]
        )
        FindingRequeue.apply(report, to: &finding, previousDisposition: .existingNeedsReview, now: Date(timeIntervalSince1970: 10))
        #expect(finding.disposition == .requeueSucceeded)
        #expect(finding.attemptCount == 1)
        #expect(finding.retryItemIdentifier == "retry-item")
        #expect(finding.retryPath == "/cloud/episode.__requeued-20260923-140311.mp4")
        #expect(finding.eligibilityBlockReason == "The uploaded copy will replace the failed original.")
    }

    @Test func testBlockedBeforeCopyDoesNotConsumeTheAttempt() {
        var finding = sample()
        let report = ExecutionReport(
            outcome: .blocked(.crossVolume),
            journals: [journal(.failed, staged: "/staging")]
        )
        FindingRequeue.apply(report, to: &finding, previousDisposition: .existingNeedsReview, now: Date(timeIntervalSince1970: 10))
        #expect(finding.disposition == .existingNeedsReview)
        #expect(finding.attemptCount == 0)
        #expect(finding.retryPath == nil)
        #expect(finding.eligibilityBlockReason?.contains("different volumes") == true)
    }

    private func sample() -> FindingSnapshot {
        FindingSnapshot(
            id: UUID(), canonicalPath: "/cloud/episode.mp4", filename: "episode.mp4", rootIdentifier: UUID(),
            fileSize: 10, modificationDate: Date(timeIntervalSince1970: 1), firstDetectedAt: Date(timeIntervalSince1970: 1),
            lastCheckedAt: Date(timeIntervalSince1970: 1), providerState: "Permanent upload failure", confirmationCount: 2,
            attemptCount: 0, disposition: .existingNeedsReview
        )
    }

    private func journal(_ phase: RequeuePhase, staged: String? = nil, published: String? = nil) -> RequeueJournal {
        RequeueJournal(
            id: UUID(), phase: phase,
            source: SourceVersionKey(canonicalPath: "/cloud/episode.mp4", inode: 1, fileSize: 10, modificationTime: Date(timeIntervalSince1970: 1)),
            stagedPath: staged, publishedPath: published, updatedAt: Date(timeIntervalSince1970: 2)
        )
    }
}
