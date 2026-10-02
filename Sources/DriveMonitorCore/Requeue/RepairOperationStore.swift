import CryptoKit
import Darwin
import Foundation

/// Operation evidence is independent of the user-clearable findings list.
public struct RepairOperationStore: Sendable {
    public let root: URL
    private let cache = OperationInventoryCache()

    public init(root: URL) throws {
        let root = root.standardizedFileURL
        guard !root.pathComponents.contains("CloudStorage"),
              root.resolvingSymlinksInPath().path == root.path else {
            throw MonitoringError.blocked(reason: "Repair records must be outside synced folders and symbolic links.")
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.root = root
    }

    public func save(_ record: RequeueJournal) throws {
        defer { cache.invalidate() }
        try DurableFile.write(JSONEncoder().encode(record), to: root.appendingPathComponent(record.id.uuidString + ".json"))
    }

    public func inventory() throws -> (records: [RequeueJournal], unreadable: [URL]) {
        try readInventory(useCache: false)
    }

    private func readInventory(useCache: Bool) throws -> (records: [RequeueJournal], unreadable: [URL]) {
        let urls = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        var signatures: [URL: RetryFileIdentity] = [:]
        var records: [RequeueJournal] = [], unreadable: [URL] = []
        for url in urls {
            do { signatures[url] = try FileIntegrity.identity(url) }
            catch {
                signatures[url] = RetryFileIdentity(exists: false, inode: 0, fileSize: 0, modificationTime: .distantPast)
                unreadable.append(url)
            }
        }
        if useCache, let saved = cache.value(for: signatures) { return saved }
        for url in urls where !unreadable.contains(url) {
            do { records.append(try JSONDecoder().decode(RequeueJournal.self, from: Data(contentsOf: url))) }
            catch { unreadable.append(url) }
        }
        let result = (records.sorted { $0.updatedAt > $1.updatedAt }, unreadable.sorted { $0.path < $1.path })
        cache.save(result, signatures: signatures)
        return result
    }

    /// Mutations fail closed if an unknown record might own the path. Read-only monitoring can continue.
    public func records() throws -> [RequeueJournal] {
        let inventory = try inventory()
        guard inventory.unreadable.isEmpty else {
            throw MonitoringError.blocked(reason: "Repair is blocked by unreadable operation records. Open Activity → Recovery to reveal them.")
        }
        return inventory.records
    }

    public func knownRecords() throws -> [RequeueJournal] { try readInventory(useCache: true).records }

    public func knownPending(path: String) throws -> RequeueJournal? {
        try knownRecords().first { $0.source.canonicalPath == path && $0.requiresRecovery }
    }

    public func pending(path: String) throws -> RequeueJournal? {
        try records().first { $0.source.canonicalPath == path && $0.requiresRecovery }
    }
}

private final class OperationInventoryCache: @unchecked Sendable {
    private let lock = NSLock()
    private var signatures: [URL: RetryFileIdentity] = [:]
    private var stored: (records: [RequeueJournal], unreadable: [URL])?
    func value(for signatures: [URL: RetryFileIdentity]) -> (records: [RequeueJournal], unreadable: [URL])? {
        lock.withLock { self.signatures == signatures ? stored : nil }
    }
    func save(_ value: (records: [RequeueJournal], unreadable: [URL]), signatures: [URL: RetryFileIdentity]) {
        lock.withLock { self.signatures = signatures; stored = value }
    }
    func invalidate() { lock.withLock { stored = nil } }
}

/// Shared by monitoring, manual repair, and Undo. Actor reentrancy never releases a lease.
public actor RepairAccess {
    private var paths: Set<String> = []
    private let lockRoot: URL?

    public init(lockRoot: URL? = nil) { self.lockRoot = lockRoot }

    public func withAccess<T: Sendable>(to path: String, operation: @Sendable () async throws -> T) async throws -> T {
        let canonical = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        guard paths.insert(canonical).inserted else {
            throw RepairAccessError.busy
        }
        defer { paths.remove(canonical) }
        let lock = try lockRoot.map { try HeldLock.acquire(in: $0, for: canonical) }
        defer { lock?.release() }
        return try await operation()
    }

    /// Removes lock files nobody holds, such as those left by earlier builds that never removed them.
    public static func pruneStaleLocks(in root: URL) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return }
        for name in names where name.hasSuffix(".lock") {
            let path = root.appendingPathComponent(name).path
            let descriptor = open(path, O_RDWR | O_NOFOLLOW)
            guard descriptor >= 0 else { continue }
            defer { close(descriptor) }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { continue } // in use
            if HeldLock.pathNamesLockedFile(path, descriptor: descriptor) { unlink(path) }
            flock(descriptor, LOCK_UN)
        }
    }
}

/// An advisory lock file shared by app instances. The file is removed on release so lock files do
/// not accumulate. Because a holder may remove it between another process's open and its lock, a new
/// holder confirms the path still names the file it locked, and starts over if not.
private struct HeldLock {
    let descriptor: Int32
    let path: String

    static func acquire(in root: URL, for canonical: String) throws -> HeldLock {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let name = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
        let path = root.appendingPathComponent(name + ".lock").path
        for _ in 0..<8 {
            let descriptor = open(path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else { throw POSIXError(.EIO) }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                close(descriptor)
                throw RepairAccessError.busy
            }
            if pathNamesLockedFile(path, descriptor: descriptor) { return HeldLock(descriptor: descriptor, path: path) }
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
        throw RepairAccessError.busy
    }

    static func pathNamesLockedFile(_ path: String, descriptor: Int32) -> Bool {
        var held = stat(), named = stat()
        return fstat(descriptor, &held) == 0 && lstat(path, &named) == 0
            && held.st_dev == named.st_dev && held.st_ino == named.st_ino
    }

    /// Unlinks while still locked: anyone who opened this file will find the path gone and retry.
    func release() {
        unlink(path)
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

enum DurableFile {
    static func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
        try synchronizeDirectory(url.deletingLastPathComponent())
    }

    static func synchronizeDirectory(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw POSIXError(.EIO) }
    }
}

public enum RepairAccessError: Error, LocalizedError, Sendable {
    case busy
    public var errorDescription: String? { "This file is already being checked, repaired, or restored. Try again when it finishes." }
}
