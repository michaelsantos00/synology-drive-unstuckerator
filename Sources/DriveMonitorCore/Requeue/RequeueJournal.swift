import Foundation

public enum RequeuePhase: String, Codable, Sendable, CaseIterable {
    case planned
    case stagingPrepared
    case clonedOrCopied
    case hashed
    case published
    case verifying
    case succeeded
    case failed
    case ignored
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
        case .published, .verifying:
            return JournalRecoveryOffer(
                revealPath: publishedPath ?? stagedPath,
                canResumeVerification: true,
                canIgnore: true
            )
        case .succeeded, .failed, .ignored:
            return nil
        }
    }
}
