import DriveMonitorCore
import SwiftUI

public enum ActivityFilter: String, CaseIterable, Identifiable {
    case needsAttention = "Needs attention"
    case requeueing = "Requeueing"
    case resolved = "Resolved"
    case ignored = "Ignored"
    case existing = "Existing at first launch"
    case lifecycle = "Synology lifecycle"
    case compatibility = "Compatibility and parsing errors"
    public var id: String { rawValue }

    func includes(_ finding: FindingSnapshot) -> Bool {
        switch self {
        case .needsAttention: [.actionable, .existingNeedsReview, .requeueFailed, .compatibilityBlocked].contains(finding.disposition)
        case .requeueing: [.requeuePreparing, .requeueUploading].contains(finding.disposition)
        case .resolved: [.resolved, .requeueSucceeded].contains(finding.disposition)
        case .ignored: finding.disposition == .ignored
        case .existing: finding.disposition == .existingNeedsReview
        case .lifecycle: false
        case .compatibility: finding.disposition == .compatibilityBlocked
        }
    }

    func includes(_ event: ActivityEvent, findings: [FindingSnapshot]) -> Bool {
        switch self {
        case .lifecycle: return event.kind == .lifecycle
        case .compatibility: return event.kind == .compatibility
        case .requeueing: return event.kind == .requeueStarted
        case .resolved: return event.kind == .requeueSucceeded || event.result == FindingDisposition.resolved.rawValue
        case .ignored: return event.result == FindingDisposition.ignored.rawValue
        case .existing: return event.kind == .baseline || event.result == FindingDisposition.existingNeedsReview.rawValue
        case .needsAttention:
            return event.kind == .compatibility || event.kind == .requeueFailed || findings.contains { $0.id == event.findingID && includes($0) }
        }
    }
}

public struct ActivityView: View {
    @Bindable var model: AppModel
    @State private var filter: ActivityFilter = .needsAttention
    @State private var selectedFinding: FindingSnapshot?
    public init(model: AppModel) { self.model = model }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Activity").font(.largeTitle.bold())
            Picker("Filter", selection: $filter) {
                ForEach(ActivityFilter.allCases) { filter in Text(filter.rawValue).tag(filter) }
            }
            .pickerStyle(.menu)
            List {
                Section("Findings") {
                    ForEach(model.findings.filter(filter.includes)) { finding in
                        AttentionRow(
                            finding: finding,
                            location: model.fileLocation(finding.canonicalPath),
                            actionTitle: model.fileActionTitle(finding),
                            actionEnabled: model.canRequeue(finding),
                            action: { model.requeue(id: finding.id) },
                            undoEnabled: model.canUndo(finding),
                            undo: { model.undo(id: finding.id) }
                        )
                            .padding(.vertical, 4)
                    }
                }
                Section("Activity") {
                    ForEach(model.recentActivity.filter { filter.includes($0, findings: model.findings) }) { event in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(event.summary)
                            Text(event.timestamp.formatted(date: .abbreviated, time: .standard)).font(.caption).foregroundStyle(.secondary)
                            if let details = event.details { Text(model.showRawPaths ? details : "Details hidden while paths are redacted.").font(.caption) }
                        }
                    }
                }
            }
            .overlay {
                if model.findings.filter(filter.includes).isEmpty && model.recentActivity.filter({ filter.includes($0, findings: model.findings) }).isEmpty {
                    Text("No activity in this category.").foregroundStyle(.secondary)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 660, minHeight: 460)
        .sheet(item: $selectedFinding) { FindingDetailView(model: model, findingID: $0.id) }
    }
}
