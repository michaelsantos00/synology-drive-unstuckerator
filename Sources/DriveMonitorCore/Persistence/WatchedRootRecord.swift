import Foundation

public struct WatchedRootSnapshot: Equatable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var path: String
    public var displayName: String
    public var enabled: Bool
    public var extensions: [String]
    public var ignorePatterns: [String]
    public var minimumStableAge: TimeInterval
    public var automaticRequeueEnabled: Bool
    public var baselineCompletedAt: Date?

    public init(
        id: UUID,
        path: String,
        displayName: String,
        enabled: Bool,
        extensions: [String],
        ignorePatterns: [String],
        minimumStableAge: TimeInterval,
        automaticRequeueEnabled: Bool,
        baselineCompletedAt: Date? = nil
    ) {
        self.id = id
        self.path = path
        self.displayName = displayName
        self.enabled = enabled
        self.extensions = extensions
        self.ignorePatterns = ignorePatterns
        self.minimumStableAge = minimumStableAge
        self.automaticRequeueEnabled = automaticRequeueEnabled
        self.baselineCompletedAt = baselineCompletedAt
    }
}
