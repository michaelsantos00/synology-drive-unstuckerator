import DriveMonitorCore
import Foundation

public struct RecoveryFile: Identifiable, Sendable {
    public var id: UUID { record.id }
    public var record: UndoRecord
    public var url: URL
    public var exists: Bool
    public var size: Int64

    public init(record: UndoRecord, url: URL) {
        self.record = record
        self.url = url
        let identity = try? FileIntegrity.identity(url)
        self.exists = identity?.exists == true
        self.size = identity?.fileSize ?? 0
    }
}
