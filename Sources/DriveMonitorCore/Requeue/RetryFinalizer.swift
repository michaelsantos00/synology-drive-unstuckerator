import Foundation

/// After Synology reports the sibling uploaded, archives the original and renames the sibling.
/// Stops if the original's inode, size, or modification time no longer match the verified version.

public enum RetryNormalization: Equatable, Sendable {
    case replaced(URL)
    case leftInPlace(String)
    case originalRemoved(retryURL: URL, reason: String)
}

public struct RetryFileIdentity: Equatable, Sendable {
    public var exists: Bool
    public var inode: UInt64
    public var fileSize: Int64
    public var modificationTime: Date

    public init(exists: Bool, inode: UInt64, fileSize: Int64, modificationTime: Date) {
        self.exists = exists
        self.inode = inode
        self.fileSize = fileSize
        self.modificationTime = modificationTime
    }
}

public struct RetryFinalizer {
    public var identity: @Sendable (URL) throws -> RetryFileIdentity
    public var remove: @Sendable (URL) throws -> Void
    public var move: @Sendable (URL, URL) throws -> Void

    public init(
        identity: @escaping @Sendable (URL) throws -> RetryFileIdentity,
        remove: @escaping @Sendable (URL) throws -> Void,
        move: @escaping @Sendable (URL, URL) throws -> Void
    ) {
        self.identity = identity
        self.remove = remove
        self.move = move
    }

    public static func system() -> RetryFinalizer {
        RetryFinalizer(
            identity: { url in
                guard FileManager.default.fileExists(atPath: url.path) else {
                    return RetryFileIdentity(exists: false, inode: 0, fileSize: 0, modificationTime: .distantPast)
                }
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                guard let size = values.fileSize,
                      let modified = values.contentModificationDate,
                      let inode = attributes[.systemFileNumber] as? NSNumber else {
                    throw RetryFinalizerError.unreadable(url.path)
                }
                return RetryFileIdentity(exists: true, inode: inode.uint64Value, fileSize: Int64(size), modificationTime: modified)
            },
            remove: { url in
                try FileManager.default.removeItem(at: url)
            },
            move: { source, destination in
                if FileManager.default.fileExists(atPath: destination.path) {
                    throw RetryFinalizerError.destinationOccupied(destination.path)
                }
                try FileManager.default.moveItem(at: source, to: destination)
            }
        )
    }

    public func finish(
        original: URL,
        retry: URL,
        expectedInode: UInt64,
        expectedSize: Int64,
        expectedModified: Date
    ) -> RetryNormalization {
        if original.resolvingSymlinksInPath().path == retry.resolvingSymlinksInPath().path {
            return .leftInPlace("The retry path is the original file, so nothing was deleted.")
        }
        do {
            let retryIdentity = try identity(retry)
            guard retryIdentity.exists else {
                return .leftInPlace("The uploaded copy is missing, so the original was kept.")
            }
            let originalIdentity = try identity(original)
            guard originalIdentity.exists else {
                return .leftInPlace("The original file is already gone.")
            }
            guard originalIdentity.inode == expectedInode,
                  originalIdentity.fileSize == expectedSize,
                  abs(originalIdentity.modificationTime.timeIntervalSince(expectedModified)) < 1,
                  originalIdentity.inode != retryIdentity.inode else {
                return .leftInPlace("The original file changed after the copy was made, so it was kept.")
            }
            try remove(original)
        } catch {
            return .leftInPlace("The original could not be removed: \(error.localizedDescription)")
        }
        do {
            try move(retry, original)
            return .replaced(original)
        } catch {
            return .originalRemoved(
                retryURL: retry,
                reason: "The failed original was removed, but the uploaded copy could not be renamed. It is still at \(retry.path). \(error.localizedDescription)"
            )
        }
    }
}

public enum RetryFinalizerError: Error, Equatable {
    case unreadable(String)
    case destinationOccupied(String)
}
