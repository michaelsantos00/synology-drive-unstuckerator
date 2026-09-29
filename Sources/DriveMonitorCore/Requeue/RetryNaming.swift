import Foundation

public enum RetryNaming {
    public static func fileName(
        stem: String,
        extension ext: String,
        now: Date,
        takenNames: Set<String>,
        randomSuffix: String? = nil,
        timeZone: TimeZone = .current
    ) -> String {
        let cleanedExtension = ext.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let stamp = timestamp(now, timeZone: timeZone)
        let base = "\(stem).__requeued-\(stamp).\(cleanedExtension)"
        if !takenNames.contains(base) {
            return base
        }
        let suffix = sanitizedSuffix(randomSuffix) ?? fallbackSuffix()
        return "\(stem).__requeued-\(stamp)-\(suffix).\(cleanedExtension)"
    }

    private static func timestamp(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    private static func sanitizedSuffix(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let filtered = raw.lowercased().filter(\.isHexDigit)
        guard !filtered.isEmpty else { return nil }
        return String(filtered.prefix(8))
    }

    private static func fallbackSuffix() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(8))
    }
}

private extension Character {
    var isHexDigit: Bool {
        ("0"..."9").contains(self) || ("a"..."f").contains(self) || ("A"..."F").contains(self)
    }
}
