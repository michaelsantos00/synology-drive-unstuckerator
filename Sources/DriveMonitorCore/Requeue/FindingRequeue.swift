import Foundation

public enum RequeueExplanation {
    public static func message(_ reason: RequeueBlockReason) -> String {
        switch reason {
        case .notConfirmed:
            "This file is not a confirmed upload failure yet."
        case .sourceIdentityChanged:
            "The file changed after the failure was confirmed, so this retry was stopped."
        case .notLocal:
            "The file is not available on this Mac."
        case .openForWriting:
            "A process still has the file open for writing."
        case .retryAlreadyActive:
            "A retry is already in progress for this file."
        case .attemptLimitReached:
            "This source version already used its one retry. A changed file can be tried again."
        case .insufficientSpace(let available, let required):
            "Free space is \(available) bytes and this retry needs \(required) bytes."
        case .crossVolume:
            "The staging folder and the Synology folder are on different volumes, so the final move would not be atomic."
        case .monitoringPaused:
            "Monitoring is paused."
        case .providerUnavailable:
            "Synology Drive is not available."
        case .incompatibleProviderOutput:
            "File Provider output could not be interpreted safely."
        case .existingBaselineNeedsReview:
            "Automatic retry stays off for failures that already existed at first launch. Use Requeue on that file if you want a copy made."
        case .automaticDisabled:
            "Automatic requeue is turned off."
        case .hashMismatch:
            "The staged copy did not match the original, so it was not moved into the Synology folder. The original file was not changed."
        case .publishFailed(let stagedPath):
            "The retry copy could not be published. The staged file is still at \(stagedPath). The original file was not changed."
        }
    }
}

public enum FindingRequeue {
    public static func apply(
        _ report: ExecutionReport,
        to finding: inout FindingSnapshot,
        previousDisposition: FindingDisposition,
        now: Date
    ) {
        if let published = report.journals.last(where: { $0.publishedPath != nil })?.publishedPath {
            finding.retryPath = published
        }
        let copyWasMade = report.journals.contains {
            switch $0.phase {
            case .clonedOrCopied, .hashed, .published, .verifying, .succeeded:
                true
            case .planned, .stagingPrepared, .failed, .ignored:
                false
            }
        }
        switch report.outcome {
        case .uploaded(let identifier):
            finding.disposition = .requeueSucceeded
            finding.retryItemIdentifier = identifier
            finding.uploadVerifiedAt = now
            finding.attemptCount += 1
            finding.providerState = "Synology reports the retry uploaded"
            finding.eligibilityBlockReason = "The uploaded copy will replace the failed original."
        case .retryFailed(let code):
            finding.disposition = .requeueFailed
            finding.attemptCount += 1
            finding.errorDomain = "NSFileProviderErrorDomain"
            finding.errorCode = code
            finding.providerState = "The retry copy also failed"
            finding.eligibilityBlockReason = "No further copy was created. The original file was left in place."
        case .verifying:
            finding.disposition = .requeueUploading
            finding.attemptCount += 1
            finding.providerState = "Waiting for Synology to report the retry uploaded"
            finding.eligibilityBlockReason = "The complete retry copy is in the folder. The original file was not changed."
        case .blocked(let reason):
            if copyWasMade { finding.attemptCount += 1 }
            finding.disposition = copyWasMade ? .requeueFailed : previousDisposition
            finding.providerState = copyWasMade ? "Requeue stopped after a copy was made" : "Requeue stopped before copying"
            finding.eligibilityBlockReason = RequeueExplanation.message(reason)
        }
        finding.lastCheckedAt = now
    }
}
