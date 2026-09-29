import Foundation

/// Reads the first `fileproviderItems` dictionary from `fileproviderctl evaluate`.
/// Unknown output is incompatible. Exit status is not success.

public enum FileProviderParser {
    public static func parse(_ output: String) -> EvaluationParseResult {
        guard let itemsRange = output.range(of: "fileproviderItems") else {
            if isMissingItemMessage(output) {
                return .missingItem
            }
            return .incompatible(reason: "fileproviderItems is missing")
        }

        var cursor = Cursor(output, start: itemsRange.upperBound)
        cursor.skipWhitespace()
        guard cursor.consume("=") else {
            return .incompatible(reason: "fileproviderItems is missing a value")
        }
        cursor.skipWhitespace()
        guard cursor.consume("(") else {
            return .incompatible(reason: "fileproviderItems is not a list")
        }

        var items: [FileProviderItemState] = []
        var failure: EvaluationParseResult?
        while !cursor.isAtEnd {
            cursor.skipWhitespace()
            if cursor.consume(")") {
                break
            }
            if cursor.consume(",") {
                continue
            }
            guard cursor.peek() == "{" else {
                return .incompatible(reason: "fileproviderItems contains an unexpected value")
            }
            switch parseItem(from: &cursor) {
            case .item(let item):
                items.append(item)
            case .failed(let result):
                failure = result
            }
        }

        if let failure, items.isEmpty {
            return failure
        }
        if items.count > 1 {
            return .incompatible(reason: "fileproviderItems contains more than one item")
        }
        if let failure {
            return failure
        }
        guard let item = items.first else {
            return .missingItem
        }
        if item.isUploaded == nil {
            return .incompatible(reason: "isUploaded is missing")
        }
        if item.uploadingErrorRaw != nil, item.uploadingErrorDomain == nil || item.uploadingErrorCode == nil {
            return .incompatible(reason: "uploadingError has no numeric code")
        }
        return .item(item)
    }

    public static func isActionablePermanentFailure(_ item: FileProviderItemState) -> Bool {
        item.isDownloaded == true
            && item.isUploaded == false
            && item.isExcludedFromSync != true
            && item.isSyncPaused != true
            && item.uploadingErrorDomain == "NSFileProviderErrorDomain"
            && item.uploadingErrorCode == -2005
    }

    private static func isMissingItemMessage(_ output: String) -> Bool {
        let folded = output.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        return folded.contains("couldn't find a file")
            || folded.contains("could not find a file")
            || folded.contains("no such file")
    }

    private static func parseItem(from cursor: inout Cursor) -> ItemParse {
        guard cursor.consume("{") else {
            return .failed(.incompatible(reason: "item dictionary did not open"))
        }
        var item = FileProviderItemState()
        while !cursor.isAtEnd {
            cursor.skipWhitespace()
            if cursor.consume("}") {
                return .item(item)
            }
            guard let key = cursor.readIdentifier() else {
                return .failed(.incompatible(reason: "item dictionary has an unreadable key"))
            }
            cursor.skipWhitespace()
            guard cursor.consume("=") else {
                return .failed(.incompatible(reason: "item key \(key) has no value"))
            }
            cursor.skipWhitespace()
            switch cursor.readValue() {
            case .text(let raw):
                apply(key: key, text: raw, to: &item)
            case .skipped where Self.isSafetyField(key):
                // A dictionary or list where a flag or error string was expected must not look like success.
                return .failed(.incompatible(reason: "item key \(key) has an unsupported value"))
            case .string(let raw):
                apply(key: key, text: raw, to: &item)
                if key == "uploadingError" {
                    item.uploadingErrorRaw = raw
                    applyError(raw, to: &item)
                }
            case .skipped:
                break
            case .invalid:
                return .failed(.incompatible(reason: "item key \(key) has an unreadable value"))
            }
            cursor.skipWhitespace()
            guard cursor.consume(";") else {
                return .failed(.incompatible(reason: "item key \(key) is missing a terminator"))
            }
        }
        return .failed(.incompatible(reason: "item dictionary did not close"))
    }

    private static func isSafetyField(_ key: String) -> Bool {
        ["isUploaded", "isUploading", "isDownloaded", "uploadingError"].contains(key)
    }

    private static func apply(key: String, text: String, to item: inout FileProviderItemState) {
        switch key {
        case "displayName", "filename":
            if item.displayName == nil || key == "displayName" {
                item.displayName = text
            }
        case "documentSize":
            item.documentSize = Int64(text)
        case "itemIdentifier":
            item.itemIdentifier = text
        case "parentItemIdentifier":
            item.parentItemIdentifier = text
        case "isDownloaded":
            item.isDownloaded = boolean(text)
        case "isExcludedFromSync":
            item.isExcludedFromSync = boolean(text)
        case "isSyncPaused":
            item.isSyncPaused = boolean(text)
        case "isUploaded":
            item.isUploaded = boolean(text)
        case "isUploading":
            item.isUploading = boolean(text)
        default:
            break
        }
    }

    private static func applyError(_ raw: String, to item: inout FileProviderItemState) {
        guard let match = raw.firstMatch(of: /Error Domain=([A-Za-z0-9.]+) Code=(-?[0-9]+)/) else {
            return
        }
        item.uploadingErrorDomain = String(match.1)
        item.uploadingErrorCode = Int(match.2)
    }

    private static func boolean(_ text: String) -> Bool? {
        switch text {
        case "1", "true", "YES":
            true
        case "0", "false", "NO":
            false
        default:
            nil
        }
    }
}

extension EvaluationClassification {
    public static func classify(_ result: EvaluationParseResult) -> EvaluationClassification {
        switch result {
        case .missingItem:
            return .missingItem
        case .incompatible(let reason):
            return .incompatible(reason: reason)
        case .item(let item):
            if item.isExcludedFromSync == true {
                return .excluded
            }
            if item.isSyncPaused == true {
                return .syncPaused
            }
            if let domain = item.uploadingErrorDomain, let code = item.uploadingErrorCode {
                if domain == "NSFileProviderErrorDomain", code == -2005, item.isUploaded == false {
                    return .permanentFailure(domain: domain, code: code)
                }
                return .incompatible(reason: "upload error \(domain) \(code) is not a permanent sync failure")
            }
            if item.uploadingErrorRaw != nil {
                return .incompatible(reason: "uploadingError has no numeric code")
            }
            if item.isUploaded == true {
                return .uploaded
            }
            if item.isUploading == true {
                return .uploading
            }
            return .notUploaded
        }
    }
}

private struct Cursor {
    let text: String
    var index: String.Index

    init(_ text: String, start: String.Index) {
        self.text = text
        self.index = start
    }

    var isAtEnd: Bool { index >= text.endIndex }

    func peek() -> Character? {
        isAtEnd ? nil : text[index]
    }

    mutating func advance() {
        guard !isAtEnd else { return }
        index = text.index(after: index)
    }

    mutating func skipWhitespace() {
        while let character = peek(), character.isWhitespace {
            advance()
        }
    }

    mutating func consume(_ expected: Character) -> Bool {
        guard peek() == expected else { return false }
        advance()
        return true
    }

    mutating func consume(_ expected: String) -> Bool {
        guard text[index...].hasPrefix(expected) else { return false }
        index = text.index(index, offsetBy: expected.count)
        return true
    }

    mutating func readIdentifier() -> String? {
        guard let first = peek(), first.isLetter || first == "_" else { return nil }
        var value = ""
        while let character = peek(), character.isLetter || character.isNumber || character == "_" {
            value.append(character)
            advance()
        }
        return value
    }

    mutating func readValue() -> RawValue {
        if peek() == "\"" {
            guard let string = readString() else { return .invalid }
            return .string(string)
        }
        if peek() == "{" || peek() == "(" {
            guard skipBalanced() else { return .invalid }
            return .skipped
        }
        var value = ""
        while let character = peek(), character != ";" && !character.isWhitespace {
            value.append(character)
            advance()
        }
        guard !value.isEmpty else { return .invalid }
        return .text(value)
    }

    mutating func readString() -> String? {
        guard consume("\"") else { return nil }
        var value = ""
        while !isAtEnd {
            let character = text[index]
            advance()
            if character == "\\" {
                guard !isAtEnd else { return nil }
                value.append(text[index])
                advance()
            } else if character == "\"" {
                return value
            } else {
                value.append(character)
            }
        }
        return nil
    }

    mutating func skipBalanced() -> Bool {
        guard let opening = peek(), opening == "{" || opening == "(" else { return false }
        let closing: Character = opening == "{" ? "}" : ")"
        var depth = 0
        while !isAtEnd {
            if peek() == "\"" {
                guard readString() != nil else { return false }
                continue
            }
            let character = text[index]
            advance()
            if character == opening {
                depth += 1
            } else if character == closing {
                depth -= 1
                if depth == 0 {
                    return true
                }
            }
        }
        return false
    }
}

private enum ItemParse {
    case item(FileProviderItemState)
    case failed(EvaluationParseResult)
}

private enum RawValue {
    case text(String)
    case string(String)
    case skipped
    case invalid
}
