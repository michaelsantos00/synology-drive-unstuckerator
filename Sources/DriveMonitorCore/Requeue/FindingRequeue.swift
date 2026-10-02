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
        case .preparationFailed(let reason):
            reason
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
        let copyWasMade = report.journals.contains { $0.sourceSHA256 != nil || $0.phase == .clonedOrCopied }
        if let record = report.journals.last {
            finding.sourceSHA256 = record.sourceSHA256 ?? finding.sourceSHA256
            finding.retrySHA256 = record.retrySHA256 ?? finding.retrySHA256
        }
        switch report.outcome {
        case .uploaded(let identifier):
            finding.disposition = .requeueUploading
            finding.retryItemIdentifier = identifier
            finding.uploadVerifiedAt = now
            finding.attemptCount = max(1, finding.attemptCount)
            finding.providerState = "Upload verified; final placement pending"
            finding.eligibilityBlockReason = "The original and retry must pass final integrity checks."
        case .retryFailed(let code):
            finding.disposition = .requeueUploading
            finding.attemptCount = max(1, finding.attemptCount)
            finding.errorDomain = "NSFileProviderErrorDomain"
            finding.errorCode = code
            finding.providerState = "The published retry also failed"
            finding.eligibilityBlockReason = "Check upload verifies the existing retry. No additional copy will be created."
        case .verifying, .verificationFailed:
            finding.disposition = .requeueUploading
            finding.attemptCount = max(1, finding.attemptCount)
            finding.providerState = "Waiting for upload verification"
            if case .verificationFailed(let message) = report.outcome { finding.eligibilityBlockReason = message }
            else { finding.eligibilityBlockReason = report.journals.last?.message ?? "The retry is published. The original is still in place." }
        case .recoveryRequired(let reason):
            finding.disposition = .recoveryRequired
            finding.providerState = "Recovery review required"
            finding.eligibilityBlockReason = reason
        case .blocked(let reason):
            if copyWasMade { finding.attemptCount = max(1, finding.attemptCount) }
            finding.disposition = copyWasMade ? .requeueFailed : previousDisposition
            finding.providerState = "Repair stopped"
            finding.eligibilityBlockReason = RequeueExplanation.message(reason)
        }
        finding.lastCheckedAt = now
    }

    public static func snapshot(for journal: RequeueJournal, fallback: FindingSnapshot) -> FindingSnapshot {
        var finding = journal.finding ?? fallback
        finding.sourceSHA256 = journal.sourceSHA256
        finding.retrySHA256 = journal.retrySHA256
        finding.retryPath = journal.publishedPath
        finding.retryItemIdentifier = journal.retryItemIdentifier
        finding.uploadVerifiedAt = journal.uploadVerifiedAt
        finding.lastCheckedAt = journal.updatedAt
        finding.eligibilityBlockReason = journal.message
        switch journal.phase {
        case .planned, .stagingPrepared, .clonedOrCopied, .hashed, .publishing:
            finding.disposition = .requeuePreparing
            finding.providerState = journal.phase == .hashed ? "Copy verified" : "Preparing a retry copy"
        case .published, .verifying, .uploadAcknowledged, .archiving, .archived, .finalizing:
            finding.disposition = .requeueUploading
            finding.attemptCount = max(1, finding.attemptCount)
            finding.providerState = journal.phase == .uploadAcknowledged ? "Upload verified; final placement pending" : "Retry published; awaiting verification"
        case .succeeded:
            // Track the replacement's identity, so our own rename cannot look like
            // a new user export and become eligible for another automatic retry.
            if let identity = journal.retryIdentity {
                finding.inode = identity.inode
                finding.fileSize = identity.fileSize
                finding.modificationDate = identity.modificationTime
            }
            finding.disposition = .requeueSucceeded
            finding.retryPath = finding.canonicalPath
            finding.providerState = journal.finalPathVerifiedAt != nil ? "Final filename reports uploaded; local content verified"
                : journal.finalPathError != nil ? finalNameFailedState : "Replacement placed locally; final-name upload not verified"
            finding.eligibilityBlockReason = journal.message ?? (journal.finalPathVerifiedAt != nil
                ? "The original is retained for Undo. This is provider acknowledgment, not an independent NAS checksum."
                : "The uploaded retry was placed at the original name. Check final name to verify its provider state; the original remains retained.")
        case .failed:
            finding.disposition = .requeueFailed
            finding.providerState = "Repair stopped before publication"
        case .undone:
            finding.disposition = .resolved
            finding.providerState = "Original restored; retained copy is in Recovery"
        case .ignored:
            finding.disposition = .ignored
        case .recoveryRequired:
            finding.disposition = .recoveryRequired
            finding.providerState = "Recovery review required"
            if finding.eligibilityBlockReason == nil { finding.eligibilityBlockReason = "An interrupted operation needs review. No additional copy will be created." }
        }
        return finding
    }
}

public extension FindingRequeue {
    /// Provider state of a placed replacement whose final filename Synology reports as failing.
    static let finalNameFailedState = "Final filename upload failed"
}

public extension FindingSnapshot {
    /// The replacement is in place but did not upload under its final name; it needs a decision.
    var finalNameFailed: Bool { disposition == .requeueSucceeded && providerState == FindingRequeue.finalNameFailedState }

    var hasRepairEvidence: Bool {
        retryPath != nil || [.requeuePreparing, .requeueUploading, .recoveryRequired].contains(disposition)
    }
}

public enum ManualRepairEligibility {
    public static func canStart(_ finding: FindingSnapshot, now: Date = Date()) -> Bool {
        guard !finding.hasRepairEvidence else { return false }
        if [.actionable, .existingNeedsReview].contains(finding.disposition) { return true }
        return finding.disposition == .observing && finding.errorCode == -2005 && finding.confirmationCount > 0
            && now.timeIntervalSince(finding.lastConfirmedAt ?? finding.firstDetectedAt) >= 60
    }
}
