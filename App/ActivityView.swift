import AppKit
import DriveMonitorCore
import SwiftUI

public enum ActivityFilter: String, CaseIterable, Identifiable, Hashable, Sendable {
    case needsAttention, checking, repairing, recent
    case recovery
    case all, existing, earlier, ignored, compatibility
    public var id: String { rawValue }

    static let queues: [ActivityFilter] = [.needsAttention, .checking, .repairing, .recent]
    static let history: [ActivityFilter] = [.all, .existing, .earlier, .ignored, .compatibility]

    public init(queue: FindingQueue) {
        switch queue {
        case .attention: self = .needsAttention
        case .checking: self = .checking
        case .repairing: self = .repairing
        case .recent: self = .recent
        }
    }

    /// The most specific list that shows a finding, used when jumping to one file.
    static func containing(_ finding: FindingSnapshot) -> ActivityFilter {
        (queues + [.existing, .earlier, .ignored]).first { $0.includes(finding) } ?? .all
    }

    var title: String {
        switch self {
        case .needsAttention: "Needs Attention"
        case .checking: "Checking"
        case .repairing: "Repairing"
        case .recent: "Recent"
        case .recovery: "Retained Files"
        case .all: "All Activity"
        case .existing: "Found at Setup"
        case .earlier: "Earlier Versions"
        case .ignored: "Ignored"
        case .compatibility: "Errors"
        }
    }

    var symbolName: String {
        switch self {
        case .needsAttention: "exclamationmark.triangle"
        case .checking: "clock"
        case .repairing: "arrow.triangle.2.circlepath"
        case .recent: "checkmark.circle"
        case .recovery: "archivebox"
        case .all: "list.bullet.rectangle"
        case .existing: "flag"
        case .earlier: "clock.arrow.circlepath"
        case .ignored: "eye.slash"
        case .compatibility: "exclamationmark.bubble"
        }
    }

    /// The menu queue a list mirrors, so it keeps the model's urgency order.
    var queue: FindingQueue? {
        switch self {
        case .needsAttention: .attention
        case .checking: .checking
        case .repairing: .repairing
        case .recent: .recent
        default: nil
        }
    }

    /// History lists are event logs; the rest list files.
    var showsEvents: Bool { self == .all || self == .compatibility }

    func includes(_ finding: FindingSnapshot) -> Bool {
        switch self {
        case .needsAttention: FindingQueue.attention.includes(finding)
        case .checking: FindingQueue.checking.includes(finding)
        case .repairing: FindingQueue.repairing.includes(finding)
        case .recent: FindingQueue.recent.includes(finding)
        case .recovery: finding.disposition == .recoveryRequired
        case .existing: finding.disposition == .existingNeedsReview
        case .earlier: finding.disposition == .sourceChanged
        case .ignored: finding.disposition == .ignored
        case .compatibility: finding.disposition == .compatibilityBlocked
        case .all: true
        }
    }

    func includes(_ event: ActivityEvent) -> Bool {
        switch self {
        case .compatibility: [.compatibility, .requeueFailed, .requeueBlocked].contains(event.kind)
        default: true
        }
    }

    var emptyTitle: String {
        switch self {
        case .needsAttention: "Nothing Needs Attention"
        case .checking: "Nothing Is Being Checked"
        case .repairing: "No Repairs Running"
        case .recent: "No Recent Repairs"
        case .existing: "Nothing Found at Setup"
        case .earlier: "No Earlier Versions"
        case .ignored: "No Ignored Files"
        case .recovery: "No Retained Files"
        case .all: "No Activity Yet"
        case .compatibility: "No Errors"
        }
    }

    var emptyDescription: String {
        switch self {
        case .needsAttention: "Files with a confirmed upload failure or an interrupted repair appear here."
        case .checking: "Files waiting for a stable size or a second matching check appear here."
        case .repairing: "Files with a retry copy being prepared or uploaded appear here."
        case .recent: "Files that were fixed or marked resolved appear here."
        case .existing: "Upload failures that existed when a folder was added appear here for review."
        case .earlier: "When a tracked file changes, moves, or is deleted, its older observation is kept here."
        case .ignored: "Versions you chose to ignore appear here."
        case .recovery: "Originals replaced by Fix are kept here for Undo and recovery."
        case .all: "Scans, repairs, and setting changes are recorded here."
        case .compatibility: "Blocked checks and stopped repairs are recorded here."
        }
    }
}

public struct ActivityView: View {
    @Bindable var model: AppModel
    @State private var search = ""
    public init(model: AppModel) { self.model = model }

    private var filter: ActivityFilter { model.activityFilter }

    private func matches(_ values: String...) -> Bool {
        search.isEmpty || values.contains { $0.localizedCaseInsensitiveContains(search) }
    }

    private var visibleFindings: [FindingSnapshot] {
        // Queues keep the model's order (most urgent first); history lists show the newest first.
        let base = filter.queue.map(model.queueFindings)
            ?? model.findings.filter(filter.includes).sorted { $0.lastCheckedAt > $1.lastCheckedAt }
        return base.filter { matches($0.filename, $0.canonicalPath) }
    }

    private var visibleEvents: [ActivityEvent] {
        model.recentActivity.filter { filter.includes($0) && matches($0.summary, $0.details ?? "") }
    }

    public var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            content
                .navigationTitle(filter.title)
                .navigationSubtitle(subtitle)
                .searchable(text: $search, placement: .toolbar, prompt: "Search")
                .toolbar { toolbar }
                .inspector(isPresented: $model.activityInspectorShown) {
                    inspector.inspectorColumnWidth(min: 300, ideal: 340, max: 520)
                }
        }
        .frame(minWidth: 960, minHeight: 500)
        .task { await model.refreshRecovery() }
        .onChange(of: model.activityFilter) { _, filter in
            // Keep the inspector on a file only while the list still shows it. Event logs link to any file.
            if let id = model.activitySelection, let finding = model.findings.first(where: { $0.id == id }),
               !filter.includes(finding), !filter.showsEvents {
                model.activitySelection = nil
            }
        }
    }

    private var sidebar: some View {
        List(selection: Binding<ActivityFilter?>(get: { model.activityFilter }, set: { if let value = $0 { model.activityFilter = value } })) {
            Section("Queues") {
                ForEach(FindingQueue.allCases) { queue in
                    let item = ActivityFilter(queue: queue)
                    Label(item.title, systemImage: item.symbolName)
                        .badge(model.queueFindings(queue).count)
                        .tag(item)
                }
            }
            Section("Recovery") {
                Label(ActivityFilter.recovery.title, systemImage: ActivityFilter.recovery.symbolName)
                    .badge(model.recoveryReviewCount)
                    .tag(ActivityFilter.recovery)
            }
            Section("History") {
                ForEach(ActivityFilter.history) { item in
                    Label(item.title, systemImage: item.symbolName).tag(item)
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
    }

    @ViewBuilder private var content: some View {
        if filter == .recovery {
            RecoveryList(model: model, search: search)
        } else if filter.showsEvents {
            EventLog(model: model, events: visibleEvents)
                .overlay { if visibleEvents.isEmpty { emptyState } }
        } else {
            FindingsTable(model: model, findings: visibleFindings)
                .overlay { if visibleFindings.isEmpty { emptyState } }
        }
    }

    @ViewBuilder private var emptyState: some View {
        if search.isEmpty {
            ContentUnavailableView(filter.emptyTitle, systemImage: filter.symbolName, description: Text(filter.emptyDescription))
        } else {
            ContentUnavailableView.search(text: search)
        }
    }

    private var subtitle: String {
        if filter == .recovery { return "\(model.recoveryFiles.count) retained" }
        if filter.showsEvents { return visibleEvents.count == 1 ? "1 event" : "\(visibleEvents.count) events" }
        return visibleFindings.count == 1 ? "1 file" : "\(visibleFindings.count) files"
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.isScanning ? model.cancelScan() : model.scanNow() } label: {
                Label(model.isScanning ? "Stop Scan" : "Scan Now", systemImage: model.isScanning ? "stop.circle" : "arrow.clockwise")
            }
            .keyboardShortcut(model.isScanning ? "." : "r", modifiers: .command)
            .disabled(!model.isScanning && (model.needsRootConfirmation || model.savingConfiguration))
            .help(model.isScanning ? "Stop the scan in progress (⌘.)" : "Check watched folders now (⌘R)")
            Button { model.togglePause() } label: {
                Label(model.isPaused ? "Resume Monitoring" : "Pause Monitoring", systemImage: model.isPaused ? "play" : "pause")
            }
            .disabled(model.needsRootConfirmation || model.changingMonitoring || model.savingConfiguration || model.savingAutomaticSetting)
            .help(model.isPaused ? "Resume scans and repairs" : "Pause scans and new repairs")
            Button { model.activityInspectorShown.toggle() } label: {
                Label(model.activityInspectorShown ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.trailing")
            }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .help("Show or hide file details (⌥⌘I)")
        }
    }

    @ViewBuilder private var inspector: some View {
        if let id = model.activitySelection, model.findings.contains(where: { $0.id == id }) {
            FindingDetailView(model: model, findingID: id)
        } else {
            ContentUnavailableView("No File Selected", systemImage: "doc.text.magnifyingglass",
                description: Text("Select a file to see its checks, copies, and history."))
        }
    }
}

/// Files as a sortable table. Model order (most urgent first) is kept until a column is sorted.
struct FindingsTable: View {
    @Bindable var model: AppModel
    let findings: [FindingSnapshot]
    @State private var sortOrder: [KeyPathComparator<FindingRow>] = []

    var body: some View {
        let rows = findings.map { FindingRow(finding: $0, location: model.fileLocation($0.canonicalPath)) }
        Table(sortOrder.isEmpty ? rows : rows.sorted(using: sortOrder), selection: $model.activitySelection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { row in
                HStack(spacing: 6) {
                    Image(nsImage: row.finding.typeIcon).resizable().frame(width: 16, height: 16).accessibilityHidden(true)
                    Text(row.name).lineLimit(1).truncationMode(.middle)
                }
                .help(model.pathText(row.finding.canonicalPath))
            }
            .width(min: 150, ideal: 210)
            TableColumn("Status", value: \.status) { row in
                StatusLabel(text: row.status, symbol: row.finding.statusSymbol, tint: row.finding.statusTint)
                    .lineLimit(1).help(row.status)
            }
            .width(min: 120, ideal: 175)
            TableColumn("Folder", value: \.location) { row in
                Text(row.location).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            .width(min: 70, ideal: 100)
            TableColumn("Size", value: \.size) { row in
                Text(row.finding.sizeText).monospacedDigit()
            }
            .width(min: 56, ideal: 70)
            TableColumn("Last Checked", value: \.lastChecked) { row in
                Text(row.lastChecked, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            .width(min: 90, ideal: 115)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            if let id = ids.first, let finding = model.findings.first(where: { $0.id == id }) {
                FindingActions(model: model, finding: finding)
            }
        } primaryAction: { ids in
            if let id = ids.first, let finding = model.findings.first(where: { $0.id == id }) { Finder.reveal(finding) }
        }
    }
}

struct FindingRow: Identifiable {
    let finding: FindingSnapshot
    let location: String
    var id: UUID { finding.id }
    var name: String { finding.filename }
    var status: String { finding.statusText }
    var size: Int64 { finding.fileSize }
    var lastChecked: Date { finding.lastCheckedAt }
}

/// The event log. Choosing an event about a file shows that file in the inspector.
struct EventLog: View {
    @Bindable var model: AppModel
    let events: [ActivityEvent]
    @State private var selection: UUID?

    var body: some View {
        List(selection: Binding(get: { selection }, set: { id in
            selection = id
            if let findingID = events.first(where: { $0.id == id })?.findingID,
               model.findings.contains(where: { $0.id == findingID }) {
                model.activitySelection = findingID
            }
        })) {
            ForEach(events) { event in
                EventRow(model: model, event: event).tag(event.id)
            }
            if model.hasMoreHistory {
                Button(model.loadingMoreHistory ? "Loading…" : "Load Older Activity") { model.loadMoreHistory() }
                    .disabled(model.loadingMoreHistory)
                    .buttonStyle(.link)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .selectionDisabled()
            }
        }
    }
}

struct EventRow: View {
    let model: AppModel
    let event: ActivityEvent

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: event.kind.symbolName).foregroundStyle(event.kind.tint).frame(width: 18).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.summary).textSelection(.enabled)
                if let details = event.details {
                    Text(model.diagnosticText(details)).font(.caption).foregroundStyle(.secondary).lineLimit(4)
                        .textSelection(.enabled).help(model.diagnosticText(details))
                }
            }
            Spacer(minLength: 8)
            Text(event.timestamp, format: .dateTime.month(.abbreviated).day().hour().minute().second())
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// Retained originals, interrupted repairs, and records that could not be read.
struct RecoveryList: View {
    @Bindable var model: AppModel
    let search: String

    private func matches(_ values: String...) -> Bool {
        search.isEmpty || values.contains { $0.localizedCaseInsensitiveContains(search) }
    }
    /// Stopped or interrupted operations. Healthy in-flight repairs are listed under Repairing instead.
    private var operations: [RequeueJournal] {
        model.repairOperations.filter { AppModel.needsReview($0) && matches($0.source.canonicalPath, $0.message ?? "") }
    }
    private var files: [RecoveryFile] {
        model.recoveryFiles.filter { matches($0.record.originalPath, $0.url.lastPathComponent) }
    }
    private var unreadable: [URL] { model.unreadableOperationFiles + model.unreadableArchiveFiles.filter { matches($0.lastPathComponent) } }
    /// Rows waiting for recovery review that no operation record lists, such as migrated older repairs.
    private var reviews: [FindingSnapshot] {
        let listed = Set(operations.compactMap { $0.finding?.id })
        return model.findings.filter { $0.disposition == .recoveryRequired && !listed.contains($0.id) && matches($0.filename, $0.canonicalPath) }
    }

    var body: some View {
        List(selection: $model.activitySelection) {
            if !reviews.isEmpty {
                Section("Needs Review") {
                    ForEach(reviews) { finding in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: finding.statusSymbol).foregroundStyle(finding.statusTint).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(finding.filename).font(.headline)
                                Text(model.diagnosticText(finding.eligibilityBlockReason ?? finding.statusText))
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                        .tag(finding.id)
                    }
                }
            }
            if !unreadable.isEmpty {
                Section("Unreadable Records") {
                    if !model.unreadableOperationFiles.isEmpty {
                        NoticeView(symbol: "lock.trianglebadge.exclamationmark", tint: .orange,
                                   text: "Repair is blocked until these operation records are restored or reviewed. Monitoring continues.")
                    }
                    ForEach(unreadable, id: \.self) { url in
                        LabeledContent(url.lastPathComponent) {
                            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        }
                    }
                }
            }
            if !operations.isEmpty {
                Section("Repairs to Review") {
                    ForEach(operations, id: \.id) { operation in
                        OperationRow(model: model, operation: operation).findingTag(operation.finding?.id, in: model)
                    }
                }
            }
            if !files.isEmpty {
                Section {
                    ForEach(files) { file in
                        RecoveryFileRow(model: model, file: file, export: export).findingTag(file.record.findingID, in: model)
                    }
                } header: {
                    Text("Retained Originals")
                } footer: {
                    let bytes = model.recoveryFiles.filter(\.exists).reduce(Int64(0)) { $0 + $1.size }
                    Text("\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) retained (logical size). Copies without an Undo window stay until you review them in Finder.")
                }
            }
        }
        .overlay {
            if unreadable.isEmpty && operations.isEmpty && files.isEmpty && reviews.isEmpty {
                if search.isEmpty {
                    ContentUnavailableView(ActivityFilter.recovery.emptyTitle, systemImage: ActivityFilter.recovery.symbolName,
                                           description: Text(ActivityFilter.recovery.emptyDescription))
                } else {
                    ContentUnavailableView.search(text: search)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let progress = model.exportProgress {
                HStack(spacing: 12) {
                    ProgressView("Exporting retained copy…", value: Double(progress.copied), total: Double(max(1, progress.total)))
                    Button("Cancel") { model.cancelExport() }
                }
                .padding(12)
                .background(.bar)
            }
        }
    }

    private func export(_ file: RecoveryFile) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.url.lastPathComponent
        panel.message = "Choose where to save a verified copy of this retained file."
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        model.exportRecovery(file, to: destination)
    }
}

struct OperationRow: View {
    @Bindable var model: AppModel
    let operation: RequeueJournal

    private var paths: [String] {
        Array(Set([operation.source.canonicalPath, operation.publishedPath, operation.stagedPath].compactMap { $0 })).sorted()
    }
    private var name: String { URL(fileURLWithPath: operation.source.canonicalPath).lastPathComponent }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Label(name, systemImage: "lifepreserver")
                    .font(.headline)
                Spacer()
                Text(operation.phase.displayName).font(.caption).foregroundStyle(.secondary)
            }
            Text(model.diagnosticText(operation.message ?? "Review these locations before changing any retained files."))
                .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if let findingID = operation.finding?.id, model.findings.contains(where: { $0.id == findingID }) {
                    Button("Show Recovery Options") { model.activitySelection = findingID; model.activityInspectorShown = true }
                        .accessibilityLabel("Show recovery options for \(name)")
                }
                Menu("Reveal in Finder") {
                    ForEach(paths, id: \.self) { path in
                        Button(model.pathText(path)) { Finder.reveal(path) }
                    }
                }
                .fixedSize()
                .accessibilityLabel("Reveal files for \(name) in Finder")
            }
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }
}

struct RecoveryFileRow: View {
    @Bindable var model: AppModel
    let file: RecoveryFile
    let export: (RecoveryFile) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(nsImage: TypeIcons.icon(for: file.record.originalPath))
                .resizable().frame(width: 32, height: 32).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.headline)
                Text(retention).font(.caption).foregroundStyle(.secondary)
                Text("\(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)) · archived \(file.record.archivedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
                if !file.exists {
                    Label {
                        Text("The retained file is missing. Review its record in Finder.")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    }
                    .font(.caption)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
                    .accessibilityLabel("Reveal retained \(name) in Finder")
                Button("Export Copy…") { export(file) }
                    .disabled(!file.exists || model.exportProgress != nil)
                    .accessibilityLabel("Export a copy of retained \(name)")
            }
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }

    private var name: String { URL(fileURLWithPath: file.record.originalPath).lastPathComponent }

    private var retention: String {
        guard file.record.purgeAllowed == true else { return "Kept until you review it · no automatic expiry" }
        return file.record.isExpired(at: Date())
            ? "Undo window ended · removed at the next hourly cleanup"
            : "Undo available until \(file.record.expiresAt.formatted(date: .abbreviated, time: .shortened))"
    }
}

extension View {
    /// Selecting a recovery row shows its file in the inspector; rows without a known file are not selectable.
    @ViewBuilder func findingTag(_ id: UUID?, in model: AppModel) -> some View {
        if let id, model.findings.contains(where: { $0.id == id }) { tag(id) } else { selectionDisabled() }
    }
}
