import Foundation

public struct SourceVersionKey: Hashable, Codable, Sendable {
    public var canonicalPath: String
    public var inode: UInt64
    public var fileSize: Int64
    public var modificationTime: Date

    public init(canonicalPath: String, inode: UInt64, fileSize: Int64, modificationTime: Date) {
        self.canonicalPath = canonicalPath
        self.inode = inode
        self.fileSize = fileSize
        self.modificationTime = modificationTime
    }
}

public enum FindingDisposition: String, Codable, Sendable, CaseIterable {
    case observing
    case existingNeedsReview
    case actionable
    case requeuePreparing
    case requeueUploading
    case requeueSucceeded
    case requeueFailed
    case ignored
    case resolved
    case sourceChanged
    case compatibilityBlocked
}

public struct PublicationPlan: Equatable, Sendable {
    public var operationID: UUID
    public var source: SourceVersionKey
    public var retryFileName: String
    public var allowFullCopyFallback: Bool

    public init(operationID: UUID, source: SourceVersionKey, retryFileName: String, allowFullCopyFallback: Bool) {
        self.operationID = operationID
        self.source = source
        self.retryFileName = retryFileName
        self.allowFullCopyFallback = allowFullCopyFallback
    }
}

public enum RequeueBlockReason: Equatable, Sendable {
    case notConfirmed
    case sourceIdentityChanged
    case notLocal
    case openForWriting
    case retryAlreadyActive
    case attemptLimitReached
    case insufficientSpace(available: Int64, required: Int64)
    case crossVolume
    case monitoringPaused
    case providerUnavailable
    case incompatibleProviderOutput
    case existingBaselineNeedsReview
    case automaticDisabled
    case hashMismatch
    case publishFailed(stagedPath: String)
}

public enum RequeueDecision: Equatable, Sendable {
    case publish(PublicationPlan)
    case blocked(RequeueBlockReason)
}
