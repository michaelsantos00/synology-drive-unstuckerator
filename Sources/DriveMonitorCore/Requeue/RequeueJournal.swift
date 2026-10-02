import Foundation

public enum RequeuePhase: String, Codable, Sendable, CaseIterable {
    case planned
    case stagingPrepared
    case clonedOrCopied
    case hashed
    case publishing
    case published
    case verifying
    case uploadAcknowledged
    case archiving
    case archived
    case finalizing
    case recoveryRequired
    case succeeded
    case failed
    case ignored
    case undone
}

public struct JournalRecoveryOffer: Equatable, Sendable {
    public var revealPath: String?
    public var canResumeVerification: Bool
    public var canIgnore: Bool

    public init(revealPath: String?, canResumeVerification: Bool, canIgnore: Bool) {
        self.revealPath = revealPath
        self.canResumeVerification = canResumeVerification
        self.canIgnore = canIgnore
    }
}

public struct RequeueJournal: Equatable, Codable, Sendable {
    public var id: UUID
    public var phase: RequeuePhase
    public var source: SourceVersionKey
    public var stagedPath: String?
    public var publishedPath: String?
    public var updatedAt: Date
    public var sourceSHA256: String?
    public var retrySHA256: String?
    public var retryIdentity: RetryFileIdentity?
    public var uploadVerifiedAt: Date?
    public var retryItemIdentifier: String?
    public var finalPathVerificationRequired: Bool?
    public var finalPathVerifiedAt: Date?
    /// Set while Synology reports the final filename itself failed to upload. Absent in older records.
    public var finalPathError: String?
    public var archiveID: UUID?
    public var finding: FindingSnapshot?
    public var nextFinding: FindingSnapshot?
    public var message: String?

    public var requiresRecovery: Bool {
        if phase == .succeeded { return finalPathVerificationRequired == true && finalPathVerifiedAt == nil }
        return ![.succeeded, .failed, .ignored, .undone].contains(phase)
    }

    public init(
        id: UUID,
        phase: RequeuePhase,
        source: SourceVersionKey,
        stagedPath: String? = nil,
        publishedPath: String? = nil,
        updatedAt: Date
    ) {
        self.id = id
        self.phase = phase
        self.source = source
        self.stagedPath = stagedPath
        self.publishedPath = publishedPath
        self.updatedAt = updatedAt
    }

    public var recoveryOffer: JournalRecoveryOffer? {
        switch phase {
        case .planned, .stagingPrepared, .clonedOrCopied, .hashed:
            return JournalRecoveryOffer(revealPath: stagedPath, canResumeVerification: false, canIgnore: true)
        case .published, .verifying, .uploadAcknowledged:
            return JournalRecoveryOffer(
                revealPath: publishedPath ?? stagedPath,
                canResumeVerification: true,
                canIgnore: true
            )
        case .publishing, .archiving, .archived, .finalizing, .recoveryRequired:
            return JournalRecoveryOffer(revealPath: publishedPath ?? stagedPath, canResumeVerification: false, canIgnore: false)
        case .succeeded, .failed, .ignored, .undone:
            return nil
        }
    }
}
