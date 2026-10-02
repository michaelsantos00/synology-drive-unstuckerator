import CryptoKit
import Foundation
import Darwin

/// Copies outside the UI actor and exposes only a complete, verified destination.
public enum RecoveryExport {
    public static func copy(source: URL, destination: URL, expectedSHA256: String?,
                            progress: @escaping @Sendable (Int64, Int64) async -> Void = { _, _ in }) async throws {
        let original = try FileIntegrity.identity(source)
        guard original.exists, source.standardizedFileURL != destination.standardizedFileURL,
              !FileManager.default.fileExists(atPath: destination.path) else {
            throw MonitoringError.blocked(reason: "Choose an empty destination for the exported copy.")
        }
        let parent = destination.deletingLastPathComponent()
        let available = try parent.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
        guard let available, available >= original.fileSize,
              available - original.fileSize >= DiskSpacePolicy.minimumReserve else {
            throw MonitoringError.blocked(reason: "The export needs room for the complete file plus 1 GiB free.")
        }
        let partial = parent.appendingPathComponent(".unstuckerator-export-\(UUID().uuidString).partial")
        let inputFD = open(source.path, O_RDONLY | O_NOFOLLOW)
        guard inputFD >= 0 else { throw CocoaError(.fileReadUnknown) }
        let input = FileHandle(fileDescriptor: inputFD, closeOnDealloc: true)
        defer { try? input.close() }
        let outputFD = open(partial.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard outputFD >= 0 else { throw CocoaError(.fileWriteUnknown) }
        let output = FileHandle(fileDescriptor: outputFD, closeOnDealloc: true)
        defer { try? output.close(); try? FileManager.default.removeItem(at: partial) }
        let partialIdentity = try FileIntegrity.identity(partial)
        var digest = SHA256(), copied: Int64 = 0
        await progress(0, original.fileSize)
        while true {
            try Task.checkCancellation()
            let data = try input.read(upToCount: 4 * 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            try output.write(contentsOf: data)
            digest.update(data: data)
            copied += Int64(data.count)
            await progress(copied, original.fileSize)
        }
        try output.synchronize()
        let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
        guard copied == original.fileSize, try FileIntegrity.identity(source) == original,
              expectedSHA256.map({ $0 == hash }) ?? true else {
            throw MonitoringError.blocked(reason: "The retained file changed or did not match its recorded digest. No completed export was published.")
        }
        try Task.checkCancellation()
        guard try FileIntegrity.identity(partial).inode == partialIdentity.inode,
              try FileIntegrity.sha256(partial) == hash else {
            throw MonitoringError.blocked(reason: "The temporary export changed before publication.")
        }
        try FileIntegrity.moveExclusively(partial, destination)
    }
}
