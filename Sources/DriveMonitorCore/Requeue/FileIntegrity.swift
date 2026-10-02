import CryptoKit
import Darwin
import Foundation

public enum FileIntegrity {
    public static func identity(_ url: URL) throws -> RetryFileIdentity {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return RetryFileIdentity(exists: false, inode: 0, fileSize: 0, modificationTime: .distantPast) }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw RetryFinalizerError.unreadable(url.path) }
        return RetryFileIdentity(exists: true, inode: UInt64(info.st_ino), fileSize: info.st_size,
            modificationTime: Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9),
            device: UInt64(info.st_dev),
            changeTime: Date(timeIntervalSince1970: Double(info.st_ctimespec.tv_sec) + Double(info.st_ctimespec.tv_nsec) / 1e9))
    }

    public static func sourceVersion(_ url: URL) throws -> SourceVersionKey {
        let value = try identity(url)
        guard value.exists else { throw RetryFinalizerError.unreadable(url.path) }
        return SourceVersionKey(canonicalPath: url.standardizedFileURL.resolvingSymlinksInPath().path,
            inode: value.inode, fileSize: value.fileSize, modificationTime: value.modificationTime)
    }

    public static func matches(_ identity: RetryFileIdentity, source: SourceVersionKey) -> Bool {
        identity.exists && identity.inode == source.inode && identity.fileSize == source.fileSize
            && abs(identity.modificationTime.timeIntervalSince(source.modificationTime)) < 0.000001
    }

    /// Always reads bytes. Metadata is a change detector, never a substitute for this check.
    public static func sha256(_ url: URL) throws -> String {
        let before = try identity(url)
        guard before.exists else { throw RetryFinalizerError.unreadable(url.path) }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw RetryFinalizerError.unreadable(url.path) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            hasher.update(data: data)
        }
        var opened = stat()
        guard fstat(fd, &opened) == 0,
              UInt64(opened.st_ino) == before.inode, UInt64(opened.st_dev) == before.device,
              opened.st_size == before.fileSize,
              try identity(url).sameContentMetadata(as: before) else {
            throw RetryFinalizerError.unreadable(url.path)
        }
        // ctime can change for provider metadata alone; callers compare the byte hash with the commitment.
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Atomic, same-volume move with kernel-enforced no-replacement semantics.
    public static func moveExclusively(_ source: URL, _ destination: URL) throws {
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        try handle.synchronize()
        guard renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try DurableFile.synchronizeDirectory(source.deletingLastPathComponent())
        if source.deletingLastPathComponent() != destination.deletingLastPathComponent() {
            try DurableFile.synchronizeDirectory(destination.deletingLastPathComponent())
        }
    }

    /// All checks and moves stay inside the two coordinated accessors, without suspension.
    public static func coordinated<T>(original: URL, retry: URL, _ body: (URL, URL) throws -> T) throws -> T {
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var result: Result<T, Error>?
        coordinator.coordinate(writingItemAt: original, options: .forMoving,
                               writingItemAt: retry, options: .forMoving, error: &coordinationError) { first, second in
            result = Result { try body(first, second) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw RetryFinalizerError.unreadable(original.path) }
        return try result.get()
    }
}
