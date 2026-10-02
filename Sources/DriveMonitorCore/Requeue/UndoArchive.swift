import Foundation

public struct UndoRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var findingID: UUID?
    public var originalPath: String
    public var cachedFileName: String
    public var archivedAt: Date
    public var expiresAt: Date
    public var operationID: UUID?
    public var expectedReplacementSHA256: String?
    public var archivedSHA256: String?
    /// Absent on older manifests: keep those bytes for explicit recovery.
    public var purgeAllowed: Bool?

    public init(id: UUID, findingID: UUID?, originalPath: String, cachedFileName: String, archivedAt: Date, expiresAt: Date) {
        self.id = id; self.findingID = findingID; self.originalPath = originalPath
        self.cachedFileName = cachedFileName; self.archivedAt = archivedAt; self.expiresAt = expiresAt
    }
    public func isExpired(at now: Date) -> Bool { purgeAllowed == true && now >= expiresAt }
}

public enum UndoArchive {
    public static let retention: TimeInterval = 6 * 60 * 60

    public static func supportRoot() throws -> URL {
        let root = try AppStorage.folderURL().appendingPathComponent("Undo", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// New archives stay outside expiry until the operation has durably completed.
    public static func store(file: URL, findingID: UUID?, root: URL, now: Date = Date(), id: UUID = UUID(),
                             operationID: UUID? = nil, expectedReplacementSHA256: String? = nil,
                             archivedSHA256: String? = nil) throws -> UndoRecord {
        do {
            let folder = root.appendingPathComponent(id.uuidString, isDirectory: true)
            guard !FileManager.default.fileExists(atPath: folder.path) else { throw UndoArchiveError.conflict }
            let payload = folder.appendingPathComponent("payload", isDirectory: true)
            try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
            var record = UndoRecord(id: id, findingID: findingID, originalPath: file.standardizedFileURL.resolvingSymlinksInPath().path,
                cachedFileName: file.lastPathComponent, archivedAt: now, expiresAt: now.addingTimeInterval(retention))
            record.operationID = operationID
            record.expectedReplacementSHA256 = expectedReplacementSHA256
            record.archivedSHA256 = try archivedSHA256 ?? FileIntegrity.sha256(file)
            record.purgeAllowed = false
            try write(record, root: root)
            // A failed move keeps its manifest: uncertainty must not destroy recovery evidence.
            try FileIntegrity.moveExclusively(file, payload.appendingPathComponent(file.lastPathComponent))
            return record
        }
    }

    public static func armExpiry(id: UUID, root: URL, now: Date = Date()) throws {
        do {
            var record = try read(id: id, root: root)
            guard record.operationID != nil, record.expectedReplacementSHA256 != nil else { throw UndoArchiveError.unverified }
            record.purgeAllowed = true
            record.expiresAt = now.addingTimeInterval(retention)
            try write(record, root: root)
        }
    }

    public static func restorableRecord(findingID: UUID, root: URL, now: Date = Date()) -> UndoRecord? {
        do {
            return records(in: root).first {
                $0.findingID == findingID && !$0.isExpired(at: now)
                    && FileManager.default.fileExists(atPath: payloadURL($0, root: root).path)
            }
        }
    }

    /// Refuses changed occupants. A parked payload gets its own manifest and no automatic expiry.
    public static func restore(_ record: UndoRecord, root: URL, now: Date = Date(), requireEmptyDestination: Bool = false,
                               beforeMove: @Sendable () throws -> Void = {}) throws -> URL {
        do {
            var current = try read(id: record.id, root: root)
            guard current.findingID != nil, !current.isExpired(at: now) else { throw UndoArchiveError.unverified }
            let cached = payloadURL(current, root: root)
            let original = URL(fileURLWithPath: current.originalPath)
            return try FileIntegrity.coordinated(original: original, retry: cached) { original, cached in
                guard FileManager.default.fileExists(atPath: original.deletingLastPathComponent().path),
                      let archivedHash = current.archivedSHA256,
                      try FileIntegrity.sha256(cached) == archivedHash else { throw UndoArchiveError.unverified }
                let occupied = try FileIntegrity.identity(original).exists
                guard !requireEmptyDestination || !occupied else { throw UndoArchiveError.changedOccupant }
                if occupied {
                    guard let expected = current.expectedReplacementSHA256,
                          try FileIntegrity.sha256(original) == expected else { throw UndoArchiveError.changedOccupant }
                }
                // Validation failures above leave operation state and expiry unchanged.
                try beforeMove()
                current.purgeAllowed = false
                try write(current, root: root)
                if occupied {
                    _ = try store(file: original, findingID: nil, root: root, now: now,
                        operationID: current.operationID, archivedSHA256: current.expectedReplacementSHA256)
                }
                // Never roll back over a newly created occupant. Both archives survive failure.
                try FileIntegrity.moveExclusively(cached, original)
                guard try FileIntegrity.sha256(original) == archivedHash else { throw UndoArchiveError.unverified }
                current.findingID = nil
                try write(current, root: root)
                return original
            }
        }
    }

    @discardableResult
    public static func purgeExpired(root: URL, now: Date = Date()) throws -> Int {
        do {
            var removed = 0
            for record in records(in: root) where record.isExpired(at: now) {
                let original = URL(fileURLWithPath: record.originalPath)
                let cached = payloadURL(record, root: root)
                do {
                    let purged = try FileIntegrity.coordinated(original: original, retry: cached) { original, cached in
                        // Manifests may change while coordination is acquired. Re-read under coordination.
                        var current = try read(id: record.id, root: root)
                        guard current.isExpired(at: now), current.findingID != nil,
                              let expected = current.expectedReplacementSHA256,
                              let archived = current.archivedSHA256 else { return false }
                        if try FileIntegrity.sha256(original) != expected || FileIntegrity.sha256(cached) != archived {
                            current.purgeAllowed = false
                            try write(current, root: root)
                            return false
                        }
                        try FileManager.default.removeItem(at: root.appendingPathComponent(record.id.uuidString))
                        return true
                    }
                    if purged { removed += 1 }
                } catch {
                    // An unavailable/busy file is unknown, not a mismatch. Retry at the next purge.
                    continue
                }
            }
            return removed
        }
    }

    public static func inventory(in root: URL) throws -> (records: [UndoRecord], unreadable: [URL]) {
        var records: [UndoRecord] = [], unreadable: [URL] = []
        for folder in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) {
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                unreadable.append(folder); continue
            }
            do {
                let record = try JSONDecoder().decode(UndoRecord.self, from: Data(contentsOf: folder.appendingPathComponent("manifest.json")))
                guard folder.lastPathComponent == record.id.uuidString,
                      record.originalPath.hasPrefix("/"), !record.cachedFileName.isEmpty,
                      record.cachedFileName != ".", record.cachedFileName != "..", !record.cachedFileName.contains("/") else {
                    throw UndoArchiveError.unverified
                }
                records.append(record)
            } catch { unreadable.append(folder) }
        }
        return (records.sorted {
            $0.archivedAt == $1.archivedAt ? $0.id.uuidString < $1.id.uuidString : $0.archivedAt > $1.archivedAt
        }, unreadable.sorted { $0.path < $1.path })
    }

    public static func records(in root: URL) -> [UndoRecord] { (try? inventory(in: root).records) ?? [] }

    public static func payloadURL(_ record: UndoRecord, root: URL) -> URL {
        root.appendingPathComponent(record.id.uuidString).appendingPathComponent("payload").appendingPathComponent(record.cachedFileName)
    }

    private static func read(id: UUID, root: URL) throws -> UndoRecord {
        try JSONDecoder().decode(UndoRecord.self, from: Data(contentsOf: root.appendingPathComponent(id.uuidString).appendingPathComponent("manifest.json")))
    }
    private static func write(_ record: UndoRecord, root: URL) throws {
        try DurableFile.write(JSONEncoder().encode(record), to: root.appendingPathComponent(record.id.uuidString).appendingPathComponent("manifest.json"))
    }
}

public enum UndoArchiveError: Error, Equatable, LocalizedError {
    case missingCache(String)
    case changedOccupant
    case unverified
    case conflict
    public var errorDescription: String? {
        switch self {
        case .changedOccupant: "The file at the original path has changed. Both versions were kept; review them in Recovery."
        case .unverified: "The archive or destination could not be verified. Recovery files were kept."
        case .conflict: "A recovery archive already exists at this location."
        case .missingCache(let name): "The recovery file is missing: \(name)."
        }
    }
}
