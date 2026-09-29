import Foundation

/// Two unchanged observations, at least 60 seconds apart, before a permanent failure is actionable.
/// A finding that is already actionable or waiting for review is not demoted by a later check.
public enum ConfirmationPolicy {
    public static let minimumInterval: TimeInterval = 60
    /// SwiftData rounds modification dates. A sub-second gap is the same file, not a new version.
    public static let modificationTolerance: TimeInterval = 1

    public static func nextState(
        previous: ConfirmationState?,
        previousObservation: ConfirmationObservation?,
        latest: ConfirmationObservation,
        baselineCompleted: Bool
    ) -> ConfirmationState {
        switch latest.classification {
        case .incompatible:
            return ConfirmationState(disposition: .compatibilityBlocked, confirmationCount: 0)
        case .uploaded:
            return ConfirmationState(disposition: .resolved, confirmationCount: previous?.confirmationCount ?? 0)
        default:
            break
        }

        if let previousObservation, !sameVersion(previousObservation, latest) {
            return ConfirmationState(disposition: .sourceChanged, confirmationCount: 0)
        }

        if case .permanentFailure = latest.classification {
            let priorFailure: Bool
            if let previousObservation, case .permanentFailure = previousObservation.classification {
                priorFailure = true
            } else {
                priorFailure = false
            }
            guard priorFailure, let previousObservation else {
                return ConfirmationState(disposition: .observing, confirmationCount: 1)
            }
            if let previous, previous.disposition == .actionable || previous.disposition == .existingNeedsReview {
                return ConfirmationState(disposition: previous.disposition, confirmationCount: max(previous.confirmationCount, 2))
            }
            let elapsed = latest.checkedAt.timeIntervalSince(previousObservation.checkedAt)
            guard elapsed >= minimumInterval else {
                return ConfirmationState(disposition: .observing, confirmationCount: max(previous?.confirmationCount ?? 1, 1))
            }
            let disposition: FindingDisposition = baselineCompleted ? .actionable : .existingNeedsReview
            return ConfirmationState(disposition: disposition, confirmationCount: 2)
        }

        return ConfirmationState(disposition: .observing, confirmationCount: previous?.confirmationCount ?? 0)
    }

    private static func sameVersion(_ earlier: ConfirmationObservation, _ later: ConfirmationObservation) -> Bool {
        earlier.inode == later.inode
            && earlier.fileSize == later.fileSize
            && abs(earlier.modificationTime.timeIntervalSince(later.modificationTime)) < modificationTolerance
    }
}