import Foundation

/// Name and age gates applied before a path is sent to `fileproviderctl`.
/// Segment files, retry siblings, and conflict copies stay ignored.

public enum CandidateDecision: Equatable, Sendable {
    case accept
    case reject(reason: String)
}

public struct ConfirmationObservation: Equatable, Sendable {
    public var path: String
    public var inode: UInt64
    public var fileSize: Int64
    public var modificationTime: Date
    public var classification: EvaluationClassification
    public var checkedAt: Date

    public init(
        path: String,
        inode: UInt64,
        fileSize: Int64,
        modificationTime: Date,
        classification: EvaluationClassification,
        checkedAt: Date
    ) {
        self.path = path
        self.inode = inode
        self.fileSize = fileSize
        self.modificationTime = modificationTime
        self.classification = classification
        self.checkedAt = checkedAt
    }
}

public struct ConfirmationState: Equatable, Sendable {
    public var disposition: FindingDisposition
    public var confirmationCount: Int

    public init(disposition: FindingDisposition, confirmationCount: Int) {
        self.disposition = disposition
        self.confirmationCount = confirmationCount
    }
}

public enum CandidateRules {
    public static let defaultMinimumAge: TimeInterval = 300

    public static func evaluate(
        name: String,
        isHidden: Bool,
        isRegularFile: Bool,
        byteSize: Int64,
        age: TimeInterval,
        extensions: [String],
        extraIgnoreSubstrings: [String] = []
    ) -> CandidateDecision {
        if isHidden || name.hasPrefix(".") {
            return .reject(reason: "hidden file")
        }
        if !isRegularFile {
            return .reject(reason: "not a regular file")
        }
        if byteSize <= 0 {
            return .reject(reason: "empty file")
        }
        if age < defaultMinimumAge {
            return .reject(reason: "newer than the minimum stable age")
        }

        let lowered = name.lowercased()
        let allowed = Set(extensions.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) })
        let ext = (name as NSString).pathExtension.lowercased()
        if ext.isEmpty || !allowed.contains(ext) {
            return .reject(reason: "extension is not eligible")
        }

        let builtIn = ["_segment_", ".__requeued-", " conflicted copy", "(conflict"]
        for pattern in builtIn + extraIgnoreSubstrings {
            if lowered.contains(pattern.lowercased()) {
                return .reject(reason: "name matches an ignore pattern")
            }
        }
        let blockedSuffixes = [".tmp", ".temp", ".partial", ".part", ".download", ".crdownload"]
        if blockedSuffixes.contains(where: { lowered.hasSuffix($0) }) {
            return .reject(reason: "temporary filename")
        }
        return .accept
    }
}
