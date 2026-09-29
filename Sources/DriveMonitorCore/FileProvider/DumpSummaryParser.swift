import Foundation

public enum DumpSummaryParser {
    public static func parse(_ output: String) -> DumpParseResult {
        if let match = output.firstMatch(of: /(?i)permanent error count:\s*([0-9]+)/) {
            if let count = Int(match.1) {
                return .count(count)
            }
        }
        return .unavailable(reason: "permanent job count is not present in this dump")
    }
}
