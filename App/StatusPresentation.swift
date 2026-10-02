import AppKit
import DriveMonitorCore
import SwiftUI
import UniformTypeIdentifiers

/// One vocabulary for file states across the menu, Activity, and notifications.
extension FindingSnapshot {
    var statusText: String {
        switch disposition {
        case .requeueSucceeded, .requeuePreparing, .requeueUploading: providerState
        case .recoveryRequired: "Recovery review required"
        case .requeueFailed: "Repair stopped"
        case .sourceChanged: providerState == MonitoringEngine.movedOrDeletedState ? providerState : "Earlier version"
        case .observing where errorCode == -2005: "Confirming failure"
        case .actionable, .existingNeedsReview: "Confirmed upload failure"
        default: providerState
        }
    }

    var statusSymbol: String {
        if finalNameFailed { return "exclamationmark.triangle.fill" }
        return switch disposition {
        case .actionable, .existingNeedsReview: "exclamationmark.triangle.fill"
        case .requeueFailed: "xmark.octagon.fill"
        case .recoveryRequired: "lifepreserver.fill"
        case .compatibilityBlocked: "questionmark.diamond.fill"
        case .requeuePreparing: "arrow.triangle.2.circlepath"
        case .requeueUploading: "arrow.up.circle.fill"
        case .requeueSucceeded, .resolved: "checkmark.circle.fill"
        case .ignored: "eye.slash"
        case .sourceChanged: "clock.arrow.circlepath"
        case .observing: "clock"
        }
    }

    var statusTint: Color {
        if finalNameFailed { return .orange }
        return switch disposition {
        case .actionable, .existingNeedsReview: .orange
        case .requeueFailed, .recoveryRequired, .compatibilityBlocked: .red
        case .requeuePreparing, .requeueUploading: .blue
        case .requeueSucceeded, .resolved: .green
        case .observing, .ignored, .sourceChanged: .secondary
        }
    }

    @MainActor var typeIcon: NSImage { TypeIcons.icon(for: filename) }

    var sizeText: String { ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file) }
}

/// Type icons from the extension only; reading the file could wake a dataless File Provider item.
@MainActor
enum TypeIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for filename: String) -> NSImage {
        let key = URL(fileURLWithPath: filename).pathExtension.lowercased()
        if let cached = cache[key] { return cached }
        let image = NSWorkspace.shared.icon(for: UTType(filenameExtension: key) ?? .data)
        cache[key] = image
        return image
    }
}

extension RequeuePhase {
    var displayName: String {
        switch self {
        case .planned: "Planned"
        case .stagingPrepared: "Staging"
        case .clonedOrCopied: "Copied"
        case .hashed: "Copy verified"
        case .publishing: "Publishing"
        case .published: "Published"
        case .verifying: "Verifying upload"
        case .uploadAcknowledged: "Upload acknowledged"
        case .archiving: "Archiving original"
        case .archived: "Original archived"
        case .finalizing: "Finalizing"
        case .recoveryRequired: "Needs recovery review"
        case .succeeded: "Completed"
        case .failed: "Stopped"
        case .ignored: "Ignored"
        case .undone: "Undone"
        }
    }
}

extension MonitorStatus {
    var tint: Color {
        switch self {
        case .healthy: .green
        case .needsAttention, .synologyUnavailable: .orange
        case .compatibilityError: .red
        case .scanning, .requeueing: .blue
        case .paused: .secondary
        }
    }

    var filledSymbolName: String {
        switch self {
        case .healthy: "checkmark.circle.fill"
        case .needsAttention: "exclamationmark.triangle.fill"
        case .scanning: "arrow.triangle.2.circlepath"
        case .requeueing: "arrow.up.circle.fill"
        case .paused: "pause.circle.fill"
        case .synologyUnavailable: "externaldrive.badge.exclamationmark"
        case .compatibilityError: "exclamationmark.octagon.fill"
        }
    }
}

extension ActivityKind {
    var symbolName: String {
        switch self {
        case .scan: "magnifyingglass"
        case .findingDetected: "exclamationmark.triangle"
        case .findingConfirmed: "checkmark.seal"
        case .requeueStarted: "arrow.triangle.2.circlepath"
        case .requeueSucceeded: "checkmark.circle"
        case .requeueFailed, .requeueBlocked: "xmark.octagon"
        case .lifecycle: "externaldrive"
        case .compatibility: "exclamationmark.bubble"
        case .baseline: "flag"
        case .recovery: "lifepreserver"
        case .settings: "gearshape"
        }
    }

    var tint: Color {
        switch self {
        case .findingDetected, .findingConfirmed: .orange
        case .requeueFailed, .requeueBlocked, .compatibility: .red
        case .requeueSucceeded: .green
        case .requeueStarted, .recovery: .blue
        default: .secondary
        }
    }
}

/// A state symbol with its meaning spelled out, so color is never the only signal.
struct StatusLabel: View {
    var text: String
    var symbol: String
    var tint: Color

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
    }
}

/// A label above a long value. Paths and digests wrap badly when right-aligned beside their label.
struct StackedValue: View {
    var title: String
    var value: String
    var monospaced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
            Text(value)
                .font(monospaced ? .system(.callout, design: .monospaced) : .callout)
                .foregroundStyle(.secondary).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A short notice with an icon, used for conditions that need the user's eye but not a decision.
struct NoticeView<Actions: View>: View {
    var symbol: String
    var tint: Color
    var text: String
    var lineLimit: Int?
    var actions: Actions

    init(symbol: String, tint: Color, text: String, lineLimit: Int? = nil, @ViewBuilder actions: () -> Actions) {
        self.symbol = symbol; self.tint = tint; self.text = text; self.lineLimit = lineLimit; self.actions = actions()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint).accessibilityHidden(true)
            Text(text).lineLimit(lineLimit).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                .help(text)
            Spacer(minLength: 0)
            actions
        }
        .font(.callout)
        .padding(.vertical, 7).padding(.horizontal, 10)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

extension NoticeView where Actions == EmptyView {
    init(symbol: String, tint: Color, text: String, lineLimit: Int? = nil) {
        self.init(symbol: symbol, tint: tint, text: text, lineLimit: lineLimit) { EmptyView() }
    }
}

enum Finder {
    @MainActor static func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// Reveals the original if it is present, otherwise the published retry.
    @MainActor static func reveal(_ finding: FindingSnapshot) {
        let path = FileManager.default.fileExists(atPath: finding.canonicalPath) ? finding.canonicalPath : finding.retryPath ?? finding.canonicalPath
        reveal(path)
    }
}
