import Foundation

public struct FileFormatPreset: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var detail: String
    public var extensions: [String]

    public init(id: String, title: String, detail: String, extensions: [String]) {
        self.id = id
        self.title = title
        self.detail = detail
        self.extensions = extensions
    }
}

public enum FileFormatCatalog {
    public static let presets: [FileFormatPreset] = [
        FileFormatPreset(id: "video", title: "Video", detail: "mp4, mov, m4v, mkv", extensions: ["mp4", "mov", "m4v", "mkv"]),
        FileFormatPreset(id: "archives", title: "Archives", detail: "zip, 7z, rar, tar, gz", extensions: ["zip", "7z", "rar", "tar", "gz"]),
        FileFormatPreset(id: "documents", title: "PDFs", detail: "pdf", extensions: ["pdf"]),
        FileFormatPreset(id: "disk", title: "Disk images", detail: "dmg, iso, pkg", extensions: ["dmg", "iso", "pkg"]),
        FileFormatPreset(id: "audio", title: "Large audio", detail: "wav, aiff, flac", extensions: ["wav", "aiff", "flac"])
    ]

    public static func extensions(enabledPresetIDs: Set<String>, customText: String) -> [String] {
        let presetExtensions = presets
            .filter { enabledPresetIDs.contains($0.id) }
            .flatMap(\.extensions)
        let custom = customText
            .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased() }
            .filter { !$0.isEmpty }
        return Array(Set(presetExtensions + custom)).sorted()
    }
}
