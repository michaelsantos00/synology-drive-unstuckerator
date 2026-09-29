import Foundation

public protocol OpenWriteProbing: Sendable {
    /// Returns true when any process has the file open for writing.
    /// Throw when the probe cannot answer. Callers treat an error as open for writing.
    func isOpenForWriting(path: String) async throws -> Bool
}
