import Foundation

public struct FindingSnapshot: Equatable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var canonicalPath: String
    public var filename: String
    public var rootIdentifier: UUID
    public var resourceIdentifier: Data?
    public var inode: UInt64?
    public var fileProviderItemIdentifier: String?
    public var fileSize: Int64
    public var modificationDate: Date
    public var firstDetectedAt: Date
    public var lastCheckedAt: Date
    public var lastConfirmedAt: Date?
    public var errorDomain: String?
    public var errorCode: Int?
    public var providerState: String
    public var confirmationCount: Int
    public var attemptCount: Int
    public var disposition: FindingDisposition
    public var eligibilityBlockReason: String?
    public var sourceSHA256: String?
    public var retryPath: String?
    public var retryItemIdentifier: String?
    public var retrySHA256: String?
    public var uploadVerifiedAt: Date?
    public var rawDiagnostic: String?

    public init(
        id: UUID,
        canonicalPath: String,
        filename: String,
        rootIdentifier: UUID,
        resourceIdentifier: Data? = nil,
        inode: UInt64? = nil,
        fileProviderItemIdentifier: String? = nil,
        fileSize: Int64,
        modificationDate: Date,
        firstDetectedAt: Date,
        lastCheckedAt: Date,
        lastConfirmedAt: Date? = nil,
        errorDomain: String? = nil,
        errorCode: Int? = nil,
        providerState: String,
        confirmationCount: Int,
        attemptCount: Int,
        disposition: FindingDisposition,
        eligibilityBlockReason: String? = nil,
        sourceSHA256: String? = nil,
        retryPath: String? = nil,
        retryItemIdentifier: String? = nil,
        retrySHA256: String? = nil,
        uploadVerifiedAt: Date? = nil,
        rawDiagnostic: String? = nil
    ) {
        self.id = id
        self.canonicalPath = canonicalPath
        self.filename = filename
        self.rootIdentifier = rootIdentifier
        self.resourceIdentifier = resourceIdentifier
        self.inode = inode
        self.fileProviderItemIdentifier = fileProviderItemIdentifier
        self.fileSize = fileSize
        self.modificationDate = modificationDate
        self.firstDetectedAt = firstDetectedAt
        self.lastCheckedAt = lastCheckedAt
        self.lastConfirmedAt = lastConfirmedAt
        self.errorDomain = errorDomain
        self.errorCode = errorCode
        self.providerState = providerState
        self.confirmationCount = confirmationCount
        self.attemptCount = attemptCount
        self.disposition = disposition
        self.eligibilityBlockReason = eligibilityBlockReason
        self.sourceSHA256 = sourceSHA256
        self.retryPath = retryPath
        self.retryItemIdentifier = retryItemIdentifier
        self.retrySHA256 = retrySHA256
        self.uploadVerifiedAt = uploadVerifiedAt
        self.rawDiagnostic = rawDiagnostic
    }
}

public enum ActivityKind: String, Codable, Sendable, CaseIterable {
    case scan
    case findingDetected
    case findingConfirmed
    case requeueStarted
    case requeueSucceeded
    case requeueFailed
    case requeueBlocked
    case lifecycle
    case compatibility
    case baseline
    case recovery
    case settings
}

public struct ActivityEvent: Equatable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var timestamp: Date
    public var kind: ActivityKind
    public var findingID: UUID?
    public var summary: String
    public var details: String?
    public var result: String?

    public init(
        id: UUID,
        timestamp: Date,
        kind: ActivityKind,
        findingID: UUID? = nil,
        summary: String,
        details: String? = nil,
        result: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.findingID = findingID
        self.summary = summary
        self.details = details
        self.result = result
    }
}

public protocol FindingStoring: Sendable {
    func upsert(_ finding: FindingSnapshot) async throws
    func findings(matching disposition: FindingDisposition?) async throws -> [FindingSnapshot]
    func append(_ event: ActivityEvent) async throws
}
