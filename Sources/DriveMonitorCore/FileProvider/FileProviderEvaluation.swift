import Foundation

public struct FileProviderItemState: Equatable, Sendable {
    public var displayName: String?
    public var documentSize: Int64?
    public var isDownloaded: Bool?
    public var isExcludedFromSync: Bool?
    public var isSyncPaused: Bool?
    public var isUploaded: Bool?
    public var isUploading: Bool?
    public var itemIdentifier: String?
    public var parentItemIdentifier: String?
    public var uploadingErrorDomain: String?
    public var uploadingErrorCode: Int?
    public var uploadingErrorRaw: String?

    public init(
        displayName: String? = nil,
        documentSize: Int64? = nil,
        isDownloaded: Bool? = nil,
        isExcludedFromSync: Bool? = nil,
        isSyncPaused: Bool? = nil,
        isUploaded: Bool? = nil,
        isUploading: Bool? = nil,
        itemIdentifier: String? = nil,
        parentItemIdentifier: String? = nil,
        uploadingErrorDomain: String? = nil,
        uploadingErrorCode: Int? = nil,
        uploadingErrorRaw: String? = nil
    ) {
        self.displayName = displayName
        self.documentSize = documentSize
        self.isDownloaded = isDownloaded
        self.isExcludedFromSync = isExcludedFromSync
        self.isSyncPaused = isSyncPaused
        self.isUploaded = isUploaded
        self.isUploading = isUploading
        self.itemIdentifier = itemIdentifier
        self.parentItemIdentifier = parentItemIdentifier
        self.uploadingErrorDomain = uploadingErrorDomain
        self.uploadingErrorCode = uploadingErrorCode
        self.uploadingErrorRaw = uploadingErrorRaw
    }
}

public enum EvaluationParseResult: Equatable, Sendable {
    case item(FileProviderItemState)
    case missingItem
    case incompatible(reason: String)
}

public enum EvaluationClassification: Equatable, Sendable {
    case uploaded
    case uploading
    case permanentFailure(domain: String, code: Int)
    case excluded
    case syncPaused
    case notUploaded
    case missingItem
    case incompatible(reason: String)
}

public enum DumpParseResult: Equatable, Sendable {
    case count(Int)
    case unavailable(reason: String)
}
