import Foundation

public enum MonitorStatus: String, Equatable, Sendable, CaseIterable {
    case healthy
    case needsAttention
    case scanning
    case requeueing
    case paused
    case synologyUnavailable
    case compatibilityError

    public var symbolName: String {
        switch self {
        case .healthy:
            "checkmark.circle"
        case .needsAttention:
            "exclamationmark.triangle"
        case .scanning:
            "arrow.triangle.2.circlepath"
        case .requeueing:
            "arrow.up.circle"
        case .paused:
            "pause.circle"
        case .synologyUnavailable:
            "externaldrive.badge.xmark"
        case .compatibilityError:
            "wrench.and.screwdriver"
        }
    }

    public var accessibilityLabel: String {
        switch self {
        case .healthy:
            "Monitoring active, no actionable findings"
        case .needsAttention:
            "One or more actionable findings"
        case .scanning:
            "Scan or status refresh in progress"
        case .requeueing:
            "A safe retry is being prepared or uploaded"
        case .paused:
            "Monitoring manually paused"
        case .synologyUnavailable:
            "Synology Drive Client or provider root unavailable"
        case .compatibilityError:
            "File Provider output cannot be interpreted safely"
        }
    }
}
