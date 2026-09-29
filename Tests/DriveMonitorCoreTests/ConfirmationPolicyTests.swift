import Foundation
import Testing
@testable import DriveMonitorCore

@Suite struct ConfirmationPolicyTests {
    private let modified = Date(timeIntervalSince1970: 1_758_000_000)

    @Test func testFirstFailureIsObserving() {
        let state = ConfirmationPolicy.nextState(
            previous: nil,
            previousObservation: nil,
            latest: observation(classification: .permanentFailure(domain: "NSFileProviderErrorDomain", code: -2005), at: 0),
            baselineCompleted: true
        )
        #expect(state == ConfirmationState(disposition: .observing, confirmationCount: 1))
    }

    @Test func testConfirmedFailureStaysConfirmedOnALaterCheck() {
        let previous = ConfirmationState(disposition: .existingNeedsReview, confirmationCount: 2)
        let state = ConfirmationPolicy.nextState(
            previous: previous,
            previousObservation: observation(classification: .permanentFailure(domain: "NSFileProviderErrorDomain", code: -2005), at: 0),
            latest: observation(classification: .permanentFailure(domain: "NSFileProviderErrorDomain", code: -2005), at: 20),
            baselineCompleted: false
        )
        #expect(state == ConfirmationState(disposition: .existingNeedsReview, confirmationCount: 2))
    }

    @Test func testSecondFailureBeforeIntervalStaysObserving() {
        let state = ConfirmationPolicy.nextState(
            previous: ConfirmationState(disposition: .observing, confirmationCount: 1),
            previousObservation: observation(classification: .permanentFailure(domain: "NSFileProviderErrorDomain", code: -2005), at: 0),
            latest: observation(classification: .permanentFailure(domain: "NSFileProviderErrorDomain", code: -2005), at: 59),
            baselineCompleted: true
        )
        #expect(state == ConfirmationState(disposition: .observing, confirmationCount: 1))
    }

    @Test func testSubsecondModificationDifferenceIsTheSameVersion() {
        let earlier = observation(classification: .permanentFailure(domain: "NSFileProviderErrorDomain", code: -2005), at: 0)
        var later = observation(classification: .permanentFailure(domain: "NSFileProviderErrorDomain", code: -2005), at: 60)
        later = ConfirmationObservation(
            path: later.path,
            inode: later.inode,
            fileSize: later.fileSize,
            modificationTime: later.modificationTime.addingTimeInterval(0.4),
            classification: later.classification,
            checkedAt: later.checkedAt
        )
        let state = ConfirmationPolicy.nextState(
            previous: ConfirmationState(disposition: .observing, confirmationCount: 1),
            previousObservation: earlier,
            latest: later,
            baselineCompleted: true
        )
        #expect(state.disposition == .actionable)
    }

    @Test func testSecondFailureBecomesActionableAfterBaseline() {
        let state = ConfirmationPolicy.nextState(
            previous: ConfirmationState(disposition: .observing, confirmationCount: 1),
            previousObservation: observation(classification: .permanentFailure(domain: "NSFileProviderErrorDomain", code: -2005), at: 0),
            latest: observation(classification: .permanentFailure(domain: "NSFileProviderErrorDomain", code: -2005), at: 60),
            baselineCompleted: true
        )
        #expect(state == ConfirmationState(disposition: .actionable, confirmationCount: 2))
    }

    @Test func testSecondFailureBeforeBaselineNeedsReview() {
        let state = ConfirmationPolicy.nextState(
            previous: ConfirmationState(disposition: .observing, confirmationCount: 1),
            previousObservation: observation(classification: .permanentFailure(domain: "NSFileProviderErrorDomain", code: -2005), at: 0),
            latest: observation(classification: .permanentFailure(domain: "NSFileProviderErrorDomain", code: -2005), at: 120),
            baselineCompleted: false
        )
        #expect(state == ConfirmationState(disposition: .existingNeedsReview, confirmationCount: 2))
    }

    @Test func testIdentityChangeCancelsTheFinding() {
        var changed = observation(classification: .permanentFailure(domain: "NSFileProviderErrorDomain", code: -2005), at: 120)
        changed.inode = 99
        let state = ConfirmationPolicy.nextState(
            previous: ConfirmationState(disposition: .observing, confirmationCount: 1),
            previousObservation: observation(classification: .permanentFailure(domain: "NSFileProviderErrorDomain", code: -2005), at: 0),
            latest: changed,
            baselineCompleted: true
        )
        #expect(state == ConfirmationState(disposition: .sourceChanged, confirmationCount: 0))
    }

    @Test func testUploadResolves() {
        let state = ConfirmationPolicy.nextState(
            previous: ConfirmationState(disposition: .observing, confirmationCount: 1),
            previousObservation: observation(classification: .permanentFailure(domain: "NSFileProviderErrorDomain", code: -2005), at: 0),
            latest: observation(classification: .uploaded, at: 120),
            baselineCompleted: true
        )
        #expect(state.disposition == .resolved)
    }

    @Test func testIncompatibleBlocks() {
        let state = ConfirmationPolicy.nextState(
            previous: nil,
            previousObservation: nil,
            latest: observation(classification: .incompatible(reason: "unknown"), at: 0),
            baselineCompleted: true
        )
        #expect(state.disposition == .compatibilityBlocked)
    }

    @Test func testExcludedDoesNotBecomeActionable() {
        let state = ConfirmationPolicy.nextState(
            previous: nil,
            previousObservation: nil,
            latest: observation(classification: .excluded, at: 0),
            baselineCompleted: true
        )
        #expect(state == ConfirmationState(disposition: .observing, confirmationCount: 0))
    }

    private func observation(classification: EvaluationClassification, at offset: TimeInterval) -> ConfirmationObservation {
        ConfirmationObservation(
            path: "/tmp/episode.mp4",
            inode: 10,
            fileSize: 100,
            modificationTime: modified,
            classification: classification,
            checkedAt: modified.addingTimeInterval(offset)
        )
    }
}
