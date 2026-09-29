import Foundation
import Testing
@testable import DriveMonitorCore

@Suite struct RequeuePlannerTests {
    @Test func testManualFixIsAllowedAfterAnUnsuccessfulAttempt() {
        var context = readyContext()
        context.mode = .manual
        context.disposition = .existingNeedsReview
        context.attemptCount = 1
        guard case .publish = RequeuePlanner.decide(context) else {
            Issue.record("A manual fix can run again when the file is still a confirmed failure")
            return
        }
    }

    @Test func testManualPublishOfBaselineFinding() {
        var context = readyContext()
        context.mode = .manual
        context.disposition = .existingNeedsReview
        context.baselineCompleted = false
        guard case .publish(let plan) = RequeuePlanner.decide(context) else {
            Issue.record("Manual requeue can publish an existing finding")
            return
        }
        #expect(plan.source == context.source)
        #expect(plan.retryFileName.contains(".__requeued-"))
        #expect(plan.allowFullCopyFallback == false)
    }

    @Test func testAutomaticPublishOnceAfterBaseline() {
        var context = readyContext()
        context.mode = .automatic
        context.automaticEnabled = true
        context.baselineCompleted = true
        context.disposition = .actionable
        guard case .publish = RequeuePlanner.decide(context) else {
            Issue.record("Expected automatic publish")
            return
        }
    }

    @Test func testAutomaticRefusesExistingAndSecondAttempt() {
        var existing = readyContext()
        existing.mode = .automatic
        existing.automaticEnabled = true
        existing.disposition = .existingNeedsReview
        #expect(RequeuePlanner.decide(existing) == .blocked(.existingBaselineNeedsReview))

        var disabled = readyContext()
        disabled.mode = .automatic
        disabled.automaticEnabled = false
        #expect(RequeuePlanner.decide(disabled) == .blocked(.automaticDisabled))

        var again = readyContext()
        again.mode = .automatic
        again.automaticEnabled = true
        again.attemptCount = 1
        #expect(RequeuePlanner.decide(again) == .blocked(.attemptLimitReached))
    }

    @Test func testSafetyGatesBlockPublication() {
        expectBlock(.notConfirmed) { $0.confirmed = false }
        expectBlock(.sourceIdentityChanged) { $0.observedSource.inode += 1 }
        expectBlock(.notLocal) { $0.isLocal = false }
        expectBlock(.openForWriting) { $0.openForWriting = true }
        expectBlock(.retryAlreadyActive) { $0.retryAlreadyActive = true }
        expectBlock(.monitoringPaused) { $0.monitoringPaused = true }
        expectBlock(.providerUnavailable) { $0.providerAvailable = false }
        expectBlock(.incompatibleProviderOutput) { $0.providerCompatible = false }
        expectBlock(.crossVolume) { $0.sameVolume = false }
        expectBlock(.hashMismatch) { $0.hashMatches = false }
        expectBlock(.publishFailed(stagedPath: "/staging/orphan.mp4")) { $0.publishFailurePath = "/staging/orphan.mp4" }
    }

    @Test func testRecoveryDoesNotOfferDeletion() {
        let source = readyContext().source
        let staged = RequeueJournal(
            id: UUID(),
            phase: .hashed,
            source: source,
            stagedPath: "/tmp/staged.mp4",
            updatedAt: Date()
        )
        let offer = staged.recoveryOffer
        #expect(offer?.revealPath == "/tmp/staged.mp4")
        #expect(offer?.canResumeVerification == false)
        #expect(offer?.canIgnore == true)

        let verifying = RequeueJournal(
            id: UUID(),
            phase: .verifying,
            source: source,
            publishedPath: "/cloud/retry.mp4",
            updatedAt: Date()
        )
        #expect(verifying.recoveryOffer?.canResumeVerification == true)

        let done = RequeueJournal(id: UUID(), phase: .succeeded, source: source, updatedAt: Date())
        #expect(done.recoveryOffer == nil)
    }

    private func expectBlock(_ reason: RequeueBlockReason, mutate: (inout RequeueContext) -> Void) {
        var context = readyContext()
        mutate(&context)
        #expect(RequeuePlanner.decide(context) == .blocked(reason))
    }

    private func readyContext() -> RequeueContext {
        let source = SourceVersionKey(
            canonicalPath: "/tmp/episode.mp4",
            inode: 10,
            fileSize: DiskSpacePolicy.gibibyte,
            modificationTime: Date(timeIntervalSince1970: 1_790_000_000)
        )
        return RequeueContext(
            mode: .manual,
            operationID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            source: source,
            observedSource: source,
            confirmed: true,
            isLocal: true,
            openForWriting: false,
            retryAlreadyActive: false,
            attemptCount: 0,
            availableBytes: 200 * DiskSpacePolicy.gibibyte,
            sameVolume: true,
            cloneValidated: true,
            monitoringPaused: false,
            providerAvailable: true,
            providerCompatible: true,
            disposition: .actionable,
            baselineCompleted: true,
            automaticEnabled: true,
            stem: "episode",
            fileExtension: "mp4",
            now: Date(timeIntervalSince1970: 1_790_196_300)
        )
    }
}
