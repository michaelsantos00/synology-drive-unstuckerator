import Foundation

public struct UndoRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var findingID: UUID?
    public var originalPath: String
    public var cachedFileName: String
    public var archivedAt: Date
    public var expiresAt: Date

    public init(id: UUID, findingID: UUID?, originalPath: String, cachedFileName: String, archivedAt: Date, expiresAt: Date) {
        self.id = id
        self.findingID = findingID
        self.originalPath = originalPath
        self.cachedFileName = cachedFileName
        self.archivedAt = archivedAt
        self.expiresAt = expiresAt
    }

    public func isExpired(at now: Date) -> Bool { now >= expiresAt }
}

public enum UndoArchive {
    public static let retention: TimeInterval = 6 * 60 * 60

    public static func supportRoot() throws -> URL {
        let root = try AppStorage.folderURL().appendingPathComponent("Undo", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Moves `file` into the cache only after its manifest is on disk.
    /// The payload lives in `payload/` so it cannot collide with `manifest.json`.
    public static func store(file: URL, findingID: UUID?, root: URL, now: Date = Date()) throws -> UndoRecord {
        let originalPath = file.resolvingSymlinksInPath().path
        let id = UUID()
        let folder = root.appendingPathComponent(id.uuidString, isDirectory: true)
        let payload = folder.appendingPathComponent("payload", isDirectory: true)
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        let cachedName = file.lastPathComponent
        let destination = payload.appendingPathComponent(cachedName)
        let record = UndoRecord(
            id: id,
            findingID: findingID,
            originalPath: originalPath,
            cachedFileName: cachedName,
            archivedAt: now,
            expiresAt: now.addingTimeInterval(retention)
        )
        try write(record, in: folder)
        do {
            try FileManager.default.moveItem(at: file, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return record
    }

    public static func restorableRecord(findingID: UUID, root: URL, now: Date = Date()) -> UndoRecord? {
        records(in: root).first { $0.findingID == findingID && !$0.isExpired(at: now) && cachedFileExists($0, root: root) }
    }

    public static func restore(_ record: UndoRecord, root: URL) throws -> URL {
        let folder = root.appendingPathComponent(record.id.uuidString, isDirectory: true)
        let cached = payloadURL(record, root: root)
        guard FileManager.default.fileExists(atPath: cached.path) else {
            throw UndoArchiveError.missingCache(record.cachedFileName)
        }
        let original = URL(fileURLWithPath: record.originalPath)
        try FileManager.default.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
        var parked: URL?
        if FileManager.default.fileExists(atPath: original.path) {
            let parkedName = "replacement-\(original.lastPathComponent)"
            let destination = folder.appendingPathComponent("payload", isDirectory: true).appendingPathComponent(parkedName)
            if FileManager.default.fileExists(atPath: destination.path) {
                throw UndoArchiveError.missingCache(parkedName)
            }
            try FileManager.default.moveItem(at: original, to: destination)
            parked = destination
        }
        do {
            try FileManager.default.moveItem(at: cached, to: original)
        } catch {
            if let parked {
                try? FileManager.default.moveItem(at: parked, to: original)
            }
            throw error
        }
        if let parked {
            // Keep a manifest so the parked replacement is still deleted when the 6 hours are up.
            var updated = record
            updated.cachedFileName = parked.lastPathComponent
            updated.findingID = nil
            try write(updated, in: folder)
        } else {
            try? FileManager.default.removeItem(at: folder)
        }
        return original
    }

    @discardableResult
    public static func purgeExpired(root: URL, now: Date = Date()) throws -> Int {
        var removed = 0
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for folder in folders {
            guard let record = readRecord(in: folder) else { continue }
            if record.isExpired(at: now) {
                do {
                    try FileManager.default.removeItem(at: folder)
                    removed += 1
                } catch {
                    continue
                }
            }
        }
        return removed
    }

    private static func records(in root: URL) -> [UndoRecord] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { readRecord(in: $0) }
    }

    private static func readRecord(in folder: URL) -> UndoRecord? {
        let url = folder.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(UndoRecord.self, from: data)
    }

    private static func payloadURL(_ record: UndoRecord, root: URL) -> URL {
        root.appendingPathComponent(record.id.uuidString)
            .appendingPathComponent("payload", isDirectory: true)
            .appendingPathComponent(record.cachedFileName)
    }

    private static func cachedFileExists(_ record: UndoRecord, root: URL) -> Bool {
        FileManager.default.fileExists(atPath: payloadURL(record, root: root).path)
    }

    private static func write(_ record: UndoRecord, in folder: URL) throws {
        let data = try JSONEncoder().encode(record)
        try data.write(to: folder.appendingPathComponent("manifest.json"), options: .atomic)
    }
}

public enum UndoArchiveError: Error, Equatable {
    case missingCache(String)
}
