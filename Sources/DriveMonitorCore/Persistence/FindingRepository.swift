import Foundation

/// Local history of findings, activity, and watched folders. The store must stay outside CloudStorage.
import SwiftData

public enum FindingRepositoryError: Error, Sendable {
    case unsafeStoreLocation
    case unknownDisposition(String)
    case unknownActivityKind(String)
}

@Model
public final class StoredFinding {
    @Attribute(.unique) public var id: UUID
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
    public var dispositionRawValue: String
    public var eligibilityBlockReason: String?
    public var sourceSHA256: String?
    public var retryPath: String?
    public var retryItemIdentifier: String?
    public var retrySHA256: String?
    public var uploadVerifiedAt: Date?
    public var rawDiagnostic: String?

    public init(_ value: FindingSnapshot) {
        id = value.id
        canonicalPath = value.canonicalPath
        filename = value.filename
        rootIdentifier = value.rootIdentifier
        resourceIdentifier = value.resourceIdentifier
        inode = value.inode
        fileProviderItemIdentifier = value.fileProviderItemIdentifier
        fileSize = value.fileSize
        modificationDate = value.modificationDate
        firstDetectedAt = value.firstDetectedAt
        lastCheckedAt = value.lastCheckedAt
        lastConfirmedAt = value.lastConfirmedAt
        errorDomain = value.errorDomain
        errorCode = value.errorCode
        providerState = value.providerState
        confirmationCount = value.confirmationCount
        attemptCount = value.attemptCount
        dispositionRawValue = value.disposition.rawValue
        eligibilityBlockReason = value.eligibilityBlockReason
        sourceSHA256 = value.sourceSHA256
        retryPath = value.retryPath
        retryItemIdentifier = value.retryItemIdentifier
        retrySHA256 = value.retrySHA256
        uploadVerifiedAt = value.uploadVerifiedAt
        rawDiagnostic = value.rawDiagnostic
    }

    public func update(from value: FindingSnapshot) {
        canonicalPath = value.canonicalPath
        filename = value.filename
        rootIdentifier = value.rootIdentifier
        resourceIdentifier = value.resourceIdentifier
        inode = value.inode
        fileProviderItemIdentifier = value.fileProviderItemIdentifier
        fileSize = value.fileSize
        modificationDate = value.modificationDate
        firstDetectedAt = value.firstDetectedAt
        lastCheckedAt = value.lastCheckedAt
        lastConfirmedAt = value.lastConfirmedAt
        errorDomain = value.errorDomain
        errorCode = value.errorCode
        providerState = value.providerState
        confirmationCount = value.confirmationCount
        attemptCount = value.attemptCount
        dispositionRawValue = value.disposition.rawValue
        eligibilityBlockReason = value.eligibilityBlockReason
        sourceSHA256 = value.sourceSHA256
        retryPath = value.retryPath
        retryItemIdentifier = value.retryItemIdentifier
        retrySHA256 = value.retrySHA256
        uploadVerifiedAt = value.uploadVerifiedAt
        rawDiagnostic = value.rawDiagnostic
    }

    public func snapshot() throws -> FindingSnapshot {
        guard let disposition = FindingDisposition(rawValue: dispositionRawValue) else {
            throw FindingRepositoryError.unknownDisposition(dispositionRawValue)
        }
        return FindingSnapshot(
            id: id, canonicalPath: canonicalPath, filename: filename, rootIdentifier: rootIdentifier,
            resourceIdentifier: resourceIdentifier, inode: inode, fileProviderItemIdentifier: fileProviderItemIdentifier,
            fileSize: fileSize, modificationDate: modificationDate, firstDetectedAt: firstDetectedAt,
            lastCheckedAt: lastCheckedAt, lastConfirmedAt: lastConfirmedAt, errorDomain: errorDomain,
            errorCode: errorCode, providerState: providerState, confirmationCount: confirmationCount,
            attemptCount: attemptCount, disposition: disposition, eligibilityBlockReason: eligibilityBlockReason,
            sourceSHA256: sourceSHA256, retryPath: retryPath, retryItemIdentifier: retryItemIdentifier,
            retrySHA256: retrySHA256, uploadVerifiedAt: uploadVerifiedAt, rawDiagnostic: rawDiagnostic
        )
    }
}

@Model
public final class StoredActivity {
    @Attribute(.unique) public var id: UUID
    public var timestamp: Date
    public var kindRawValue: String
    public var findingID: UUID?
    public var summary: String
    public var details: String?
    public var result: String?

    public init(_ value: ActivityEvent) {
        id = value.id
        timestamp = value.timestamp
        kindRawValue = value.kind.rawValue
        findingID = value.findingID
        summary = value.summary
        details = value.details
        result = value.result
    }

    public func snapshot() throws -> ActivityEvent {
        guard let kind = ActivityKind(rawValue: kindRawValue) else {
            throw FindingRepositoryError.unknownActivityKind(kindRawValue)
        }
        return ActivityEvent(id: id, timestamp: timestamp, kind: kind, findingID: findingID,
                             summary: summary, details: details, result: result)
    }
}

@Model
public final class StoredRoot {
    @Attribute(.unique) public var id: UUID
    public var path: String
    public var displayName: String
    public var enabled: Bool
    public var extensions: [String]
    public var ignorePatterns: [String]
    public var minimumStableAge: TimeInterval
    public var automaticRequeueEnabled: Bool
    public var baselineCompletedAt: Date?

    public init(_ value: WatchedRootSnapshot) {
        id = value.id
        path = value.path
        displayName = value.displayName
        enabled = value.enabled
        extensions = value.extensions
        ignorePatterns = value.ignorePatterns
        minimumStableAge = value.minimumStableAge
        automaticRequeueEnabled = value.automaticRequeueEnabled
        baselineCompletedAt = value.baselineCompletedAt
    }

    public func update(from value: WatchedRootSnapshot) {
        path = value.path
        displayName = value.displayName
        enabled = value.enabled
        extensions = value.extensions
        ignorePatterns = value.ignorePatterns
        minimumStableAge = value.minimumStableAge
        automaticRequeueEnabled = value.automaticRequeueEnabled
        baselineCompletedAt = value.baselineCompletedAt
    }

    public func snapshot() -> WatchedRootSnapshot {
        WatchedRootSnapshot(id: id, path: path, displayName: displayName, enabled: enabled,
                            extensions: extensions, ignorePatterns: ignorePatterns,
                            minimumStableAge: minimumStableAge, automaticRequeueEnabled: automaticRequeueEnabled,
                            baselineCompletedAt: baselineCompletedAt)
    }
}

@ModelActor
public actor FindingRepository: FindingStoring {
    public init(inMemory: Bool) throws {
        let schema = Schema([StoredFinding.self, StoredActivity.self, StoredRoot.self])
        let configuration: ModelConfiguration
        if inMemory {
            configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        } else {
            let directory = try AppStorage.folderURL().appendingPathComponent("Store", isDirectory: true)
            let store = directory.appendingPathComponent("Findings.store")
            // Refuse redirected storage rather than risk writing into a synced folder or a checkout.
            guard !store.pathComponents.contains("CloudStorage"),
                  store.resolvingSymlinksInPath().path == store.standardizedFileURL.path else {
                throw FindingRepositoryError.unsafeStoreLocation
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            configuration = ModelConfiguration(schema: schema, url: store, cloudKitDatabase: .none)
        }
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        context.autosaveEnabled = false
        modelContainer = container
        modelExecutor = DefaultSerialModelExecutor(modelContext: context)
    }

    public func upsert(_ finding: FindingSnapshot) async throws {
        let id = finding.id
        let query = FetchDescriptor<StoredFinding>(predicate: #Predicate { $0.id == id })
        if let stored = try modelContext.fetch(query).first { stored.update(from: finding) }
        else { modelContext.insert(StoredFinding(finding)) }
        try persist()
    }

    public func findings(matching disposition: FindingDisposition? = nil) async throws -> [FindingSnapshot] {
        var query = FetchDescriptor<StoredFinding>(sortBy: [SortDescriptor(\.lastCheckedAt, order: .reverse)])
        if let disposition {
            let raw = disposition.rawValue
            query.predicate = #Predicate { $0.dispositionRawValue == raw }
        }
        return try modelContext.fetch(query).map { try $0.snapshot() }
    }

    public func append(_ event: ActivityEvent) async throws {
        let id = event.id
        let query = FetchDescriptor<StoredActivity>(predicate: #Predicate { $0.id == id })
        guard try modelContext.fetch(query).isEmpty else { return }
        modelContext.insert(StoredActivity(event))
        try persist()
    }

    public func events() async throws -> [ActivityEvent] {
        try modelContext.fetch(FetchDescriptor<StoredActivity>(sortBy: [SortDescriptor(\.timestamp, order: .reverse)]))
            .map { try $0.snapshot() }
    }

    public func roots() async throws -> [WatchedRootSnapshot] {
        try modelContext.fetch(FetchDescriptor<StoredRoot>(sortBy: [SortDescriptor(\.displayName)]))
            .map { $0.snapshot() }
    }

    public func eraseDiscoveredItems() async throws {
        for item in try modelContext.fetch(FetchDescriptor<StoredFinding>()) {
            modelContext.delete(item)
        }
        for item in try modelContext.fetch(FetchDescriptor<StoredActivity>()) {
            modelContext.delete(item)
        }
        try persist()
    }

    public func save(root: WatchedRootSnapshot) async throws {
        let id = root.id
        let query = FetchDescriptor<StoredRoot>(predicate: #Predicate { $0.id == id })
        if let stored = try modelContext.fetch(query).first { stored.update(from: root) }
        else { modelContext.insert(StoredRoot(root)) }
        try persist()
    }

    private func persist() throws {
        do { try modelContext.save() }
        catch { modelContext.rollback(); throw error }
    }
}
