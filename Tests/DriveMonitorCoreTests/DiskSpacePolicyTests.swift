import Foundation
import Testing
@testable import DriveMonitorCore

@Suite struct DiskSpacePolicyTests {
    private let policy = DiskSpacePolicy()

    @Test func testCrossVolumeBlocksBeforeCopy() {
        let decision = policy.assess(
            available: 400 * DiskSpacePolicy.gibibyte,
            sourceSize: DiskSpacePolicy.gibibyte,
            sameVolume: false,
            cloneValidated: true
        )
        #expect(decision == .blocked(.crossVolume))
    }

    @Test func testAbsoluteGuardRejectsCopyBelowSourceSize() {
        let tinyReserve = DiskSpacePolicy(reserve: 0)
        #expect(tinyReserve.reserve == DiskSpacePolicy.minimumReserve)
        let decision = tinyReserve.assess(
            available: 500,
            sourceSize: 1_000,
            sameVolume: true,
            cloneValidated: false
        )
        guard case .blocked(.insufficientSpace(_, let required)) = decision else {
            Issue.record("Expected a space block")
            return
        }
        #expect(required >= 1_000)
    }

    @Test func testValidatedCloneWaivesDoubleSize() {
        let source = 40 * DiskSpacePolicy.gibibyte
        let decision = policy.assess(
            available: policy.reserve,
            sourceSize: source,
            sameVolume: true,
            cloneValidated: true
        )
        #expect(decision == .allowed(DiskAllowance(allowFullCopyFallback: false)))
    }

    @Test func testUnvalidatedCloneNeedsReserveAndDoubleSize() {
        let source = 30 * DiskSpacePolicy.gibibyte
        let short = policy.assess(
            available: policy.reserve,
            sourceSize: source,
            sameVolume: true,
            cloneValidated: false
        )
        guard case .blocked(.insufficientSpace) = short else {
            Issue.record("Expected the unvalidated copy to be blocked")
            return
        }
        let enough = policy.assess(
            available: source * 2,
            sourceSize: source,
            sameVolume: true,
            cloneValidated: false
        )
        #expect(enough == .allowed(DiskAllowance(allowFullCopyFallback: true)))
    }

    @Test func testWarningIsSeparateFromTheBlock() {
        #expect(policy.shouldWarn(available: 90 * DiskSpacePolicy.gibibyte))
        #expect(!policy.shouldWarn(available: 100 * DiskSpacePolicy.gibibyte))
    }
}
