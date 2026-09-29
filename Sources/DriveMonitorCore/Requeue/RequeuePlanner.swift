import Foundation

/// Decides whether a retry may be published. Automatic mode is one attempt per source version.
/// Manual mode may try again while the file is still a confirmed failure.

public enum RequeueMode: Equatable, Sendable {
    case manual
    case automatic
}

public struct RequeueContext: Equatable, Sendable {
    public var mode: RequeueMode
    public var operationID: UUID
    public var source: SourceVersionKey
    public var observedSource: SourceVersionKey
    public var confirmed: Bool
    public var isLocal: Bool
    public var openForWriting: Bool
    public var retryAlreadyActive: Bool
    public var attemptCount: Int
    public var availableBytes: Int64
    public var sameVolume: Bool
    public var cloneValidated: Bool
    public var monitoringPaused: Bool
    public var providerAvailable: Bool
    public var providerCompatible: Bool
    public var disposition: FindingDisposition
    public var baselineCompleted: Bool
    public var automaticEnabled: Bool
    public var hashMatches: Bool?
    public var publishFailurePath: String?
    public var stem: String
    public var fileExtension: String
    public var now: Date
    public var takenNames: Set<String>
    public var randomSuffix: String?
    public var diskPolicy: DiskSpacePolicy

    public init(
        mode: RequeueMode,
        operationID: UUID,
        source: SourceVersionKey,
        observedSource: SourceVersionKey,
        confirmed: Bool,
        isLocal: Bool,
        openForWriting: Bool,
        retryAlreadyActive: Bool,
        attemptCount: Int,
        availableBytes: Int64,
        sameVolume: Bool,
        cloneValidated: Bool,
        monitoringPaused: Bool,
        providerAvailable: Bool,
        providerCompatible: Bool,
        disposition: FindingDisposition,
        baselineCompleted: Bool,
        automaticEnabled: Bool,
        hashMatches: Bool? = nil,
        publishFailurePath: String? = nil,
        stem: String,
        fileExtension: String,
        now: Date,
        takenNames: Set<String> = [],
        randomSuffix: String? = nil,
        diskPolicy: DiskSpacePolicy = DiskSpacePolicy()
    ) {
        self.mode = mode
        self.operationID = operationID
        self.source = source
        self.observedSource = observedSource
        self.confirmed = confirmed
        self.isLocal = isLocal
        self.openForWriting = openForWriting
        self.retryAlreadyActive = retryAlreadyActive
        self.attemptCount = attemptCount
        self.availableBytes = availableBytes
        self.sameVolume = sameVolume
        self.cloneValidated = cloneValidated
        self.monitoringPaused = monitoringPaused
        self.providerAvailable = providerAvailable
        self.providerCompatible = providerCompatible
        self.disposition = disposition
        self.baselineCompleted = baselineCompleted
        self.automaticEnabled = automaticEnabled
        self.hashMatches = hashMatches
        self.publishFailurePath = publishFailurePath
        self.stem = stem
        self.fileExtension = fileExtension
        self.now = now
        self.takenNames = takenNames
        self.randomSuffix = randomSuffix
        self.diskPolicy = diskPolicy
    }
}

public enum RequeuePlanner {
    public static func decide(_ context: RequeueContext) -> RequeueDecision {
        if !context.providerCompatible || context.disposition == .compatibilityBlocked {
            return .blocked(.incompatibleProviderOutput)
        }
        if !context.providerAvailable {
            return .blocked(.providerUnavailable)
        }
        if !context.isLocal {
            return .blocked(.notLocal)
        }
        if context.openForWriting {
            return .blocked(.openForWriting)
        }
        if context.observedSource != context.source {
            return .blocked(.sourceIdentityChanged)
        }
        if let publishFailurePath = context.publishFailurePath {
            return .blocked(.publishFailed(stagedPath: publishFailurePath))
        }
        if context.hashMatches == false {
            return .blocked(.hashMismatch)
        }
        if context.monitoringPaused {
            return .blocked(.monitoringPaused)
        }
        if context.retryAlreadyActive {
            return .blocked(.retryAlreadyActive)
        }
        if context.mode == .automatic, context.attemptCount > 0 {
            return .blocked(.attemptLimitReached)
        }
        if let automaticBlock = automaticBlock(context) {
            return .blocked(automaticBlock)
        }
        if !context.confirmed || !isEligibleDisposition(context) {
            return .blocked(.notConfirmed)
        }

        switch context.diskPolicy.assess(
            available: context.availableBytes,
            sourceSize: context.source.fileSize,
            sameVolume: context.sameVolume,
            cloneValidated: context.cloneValidated
        ) {
        case .blocked(let reason):
            return .blocked(reason)
        case .allowed(let allowance):
            let name = RetryNaming.fileName(
                stem: context.stem,
                extension: context.fileExtension,
                now: context.now,
                takenNames: context.takenNames,
                randomSuffix: context.randomSuffix
            )
            return .publish(
                PublicationPlan(
                    operationID: context.operationID,
                    source: context.source,
                    retryFileName: name,
                    allowFullCopyFallback: allowance.allowFullCopyFallback
                )
            )
        }
    }

    private static func automaticBlock(_ context: RequeueContext) -> RequeueBlockReason? {
        guard context.mode == .automatic else { return nil }
        if !context.automaticEnabled {
            return .automaticDisabled
        }
        if !context.baselineCompleted || context.disposition == .existingNeedsReview {
            return .existingBaselineNeedsReview
        }
        if context.disposition != .actionable {
            return .notConfirmed
        }
        return nil
    }

    private static func isEligibleDisposition(_ context: RequeueContext) -> Bool {
        switch context.mode {
        case .manual:
            return context.disposition == .actionable || context.disposition == .existingNeedsReview
        case .automatic:
            return context.disposition == .actionable
        }
    }
}
