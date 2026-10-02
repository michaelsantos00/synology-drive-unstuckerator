import AppKit
import DriveMonitorCore
import Foundation
import Observation
import ServiceManagement
import SwiftUI

/// All engine integration is optional until the production interpreter is supplied.
@MainActor
public struct MonitorCallbacks {
    public var start: (([WatchedRootSnapshot]) async throws -> Void)?
    public var startPaused: (([WatchedRootSnapshot], Bool) async throws -> Void)?
    public var saveRoots: (([WatchedRootSnapshot]) async throws -> Void)?
    public var loadUnavailableRoots: (() async -> Set<UUID>)?
    public var loadMonitoringPaused: (() -> Bool)?
    public var saveMonitoringPaused: ((Bool) -> Void)?
    public var loadAutomaticRevocation: (() -> Bool)?
    public var saveAutomaticRevocation: ((Bool) throws -> Void)?
    public var loadEventPage: ((Int, Int) async throws -> [ActivityEvent])?
    public var scan: (() async throws -> [FindingSnapshot])?
    public var loadRoots: (() async throws -> [WatchedRootSnapshot])?
    public var loadEvents: (() async throws -> [ActivityEvent])?
    public var resetQueueStore: (() async throws -> [FindingSnapshot])?
    public var restoreOperations: (() async throws -> Void)?
    public var loadFindings: (() async throws -> [FindingSnapshot])?
    public var loadUnreadableOperations: (() async throws -> [URL])?
    public var loadOperations: (() async throws -> [RequeueJournal])?
    public var loadUnreadableArchives: (() async throws -> [URL])?
    public var loadRecovery: (() async throws -> [RecoveryFile])?
    public var resolveRecovery: ((UUID, RecoveryChoice) async throws -> FindingSnapshot?)?
    public var undo: ((UUID) async throws -> FindingSnapshot?)?
    public var pause: ((Bool) async throws -> Void)?
    public var recheck: ((UUID) async throws -> FindingSnapshot?)?
    public var requeue: ((UUID) async throws -> FindingSnapshot?)?
    public var automaticRequeue: ((UUID, @escaping @Sendable () async -> Bool) async throws -> FindingSnapshot?)?
    public var saveFinding: ((FindingSnapshot) async throws -> Void)?
    public var saveRoot: ((WatchedRootSnapshot) async throws -> Void)?
    public var acknowledgeBaseline: ((UUID, Date) async throws -> Void)?
    public var exportDiagnostic: ((String) throws -> Void)?
    public init() {}
}

/// Windows the menu-bar app opens on demand.
public enum AppWindowID: String, Sendable {
    case activity, welcome
}

@MainActor
@Observable
public final class AppModel {
    public var status: MonitorStatus = .paused
    public var clientStatusText = "Client status unavailable"
    public private(set) var unavailableRootIDs: Set<UUID> = []
    public var providerStatusText = "Provider evaluation is not connected"
    public var historicalProviderCountText = "Historical provider count unavailable"
    public var activeUploadCount = 0
    public var diskFreeSpaceText = "Disk free space unavailable"
    /// Time of the last completed scan; nil until one finishes.
    public private(set) var lastScanDate: Date?
    public var findings: [FindingSnapshot] = [] { didSet { rebuildQueues(); revealPendingFinding() } }
    private var queueSnapshots: [FindingQueue: [FindingSnapshot]] = [:]
    private var discoveredSnapshot: [FindingSnapshot] = []
    public var activityFilter: ActivityFilter = .needsAttention
    /// The finding shown in the Activity inspector. Activity is a single window, so this is app state.
    public var activitySelection: UUID?
    public var activityInspectorShown = true
    public private(set) var notificationAuthorization: FindingNotifier.Authorization = .notDetermined
    public var recentActivity: [ActivityEvent] = []
    public private(set) var unreadableOperationFiles: [URL] = []
    public private(set) var repairOperations: [RequeueJournal] = []
    public private(set) var unreadableArchiveFiles: [URL] = []
    public private(set) var exportProgress: (copied: Int64, total: Int64)?
    @ObservationIgnored private var exportTask: Task<Void, Never>?
    public private(set) var recoveryFiles: [RecoveryFile] = []
    public private(set) var isPaused = true
    public private(set) var isScanning = false
    public private(set) var monitoringEnabled = false
    public private(set) var automaticRequeueEnabled = false
    public private(set) var savingAutomaticSetting = false
    public private(set) var savingConfiguration = false
    public private(set) var changingMonitoring = false
    public private(set) var loadingMoreHistory = false
    public private(set) var hasMoreHistory = true
    public private(set) var editingRootID: UUID?
    @ObservationIgnored private var automaticRevoked = false
    @ObservationIgnored private let automaticCoordinator = AutomaticRepairCoordinator()
    @ObservationIgnored private var needsEngineRestart = false
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var persistedEventIDs: Set<UUID> = []
    @ObservationIgnored private var historyLimit = 100
    @ObservationIgnored private var automaticInFlight: UUID?
    /// Saved findings are stale until a scan finishes in this session; auto-fix waits for one.
    @ObservationIgnored private var freshScanRequiredSince: Date?
    public var desktopNotificationsEnabled = UserDefaults.standard.object(forKey: "desktopNotificationsEnabled") as? Bool ?? false
    public var notificationStatusText = "Permission not requested"
    public var watchedRoots: [WatchedRootSnapshot] = []
    public var enabledFormatPresets: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "formatPresets") ?? ["video"])
    public var customExtensionsText: String = UserDefaults.standard.string(forKey: "customExtensions") ?? ""
    public var ignorePatternsText = "*_segment_*,*__requeued-*,* conflicted copy*,*(conflict*"
    public var minimumStableAge: Double = 300
    public var reconciliationInterval: Double = 300
    public var lowDiskWarningThresholdGiB: Double = UserDefaults.standard.object(forKey: "lowDiskWarningThresholdGiB") as? Double ?? 100
    public var showRawPaths = true
    public var needsRootConfirmation = true
    public private(set) var launchAtLogin = false
    public private(set) var launchAtLoginNeedsApproval = false
    public private(set) var launchAtLoginStatusText = "Not registered"
    public private(set) var changingLaunchAtLogin = false
    public var lastErrorText: String? {
        didSet {
            // Errors appear in a notice; VoiceOver users hear them while they are using the app.
            guard let text = lastErrorText, text != oldValue else { return }
            announce(diagnosticText(text))
        }
    }
    public private(set) var availableDiskBytes: Int64?
    public private(set) var acknowledgingBaseline = false
    public private(set) var isRestoring = true

    @ObservationIgnored private let pickFolder: () -> URL?
    @ObservationIgnored private let callbacks: MonitorCallbacks
    @ObservationIgnored private var pendingPresentation: AppWindowID?
    /// Installed by the always-visible menu-bar label, which owns an `openWindow` action.
    @ObservationIgnored public var windowPresenter: ((AppWindowID) -> Void)? {
        didSet {
            guard windowPresenter != nil, let pending = pendingPresentation else { return }
            pendingPresentation = nil
            present(pending)
        }
    }

    public init(pickFolder: @escaping () -> URL? = { nil }, callbacks: MonitorCallbacks = MonitorCallbacks()) {
        self.pickFolder = pickFolder
        self.callbacks = callbacks
        automaticRevoked = callbacks.loadAutomaticRevocation?() ?? false
        refreshLaunchAtLoginStatus()
    }

    /// Opens or focuses a window. A menu-bar app must activate itself or the window stays behind others.
    public func present(_ window: AppWindowID) {
        guard let windowPresenter else { pendingPresentation = window; return }
        windowPresenter(window)
        NSApp?.activate()
    }

    /// Shows Activity, optionally focused on one file and the list that contains it.
    public func showActivity(selecting findingID: UUID? = nil, filter: ActivityFilter? = nil) {
        if let filter { activityFilter = filter }
        if let findingID {
            activitySelection = findingID
            activityInspectorShown = true
            if filter == nil {
                if let finding = findings.first(where: { $0.id == findingID }) {
                    if !activityFilter.includes(finding) { activityFilter = .containing(finding) }
                } else {
                    pendingReveal = findingID
                }
            }
        }
        present(.activity)
    }

    /// A file asked for before its row loaded (a notification click at launch) gets its list once it arrives.
    @ObservationIgnored private var pendingReveal: UUID?

    private func revealPendingFinding() {
        guard let id = pendingReveal, let finding = findings.first(where: { $0.id == id }) else { return }
        pendingReveal = nil
        if activitySelection == id, !activityFilter.includes(finding) { activityFilter = .containing(finding) }
    }

    /// Opening the app again while it runs shows something instead of silently doing nothing.
    public func handleReopen() {
        present(needsRootConfirmation ? .welcome : .activity)
    }

    public func dismissError() { lastErrorText = nil }

    /// Speaks a short update for VoiceOver, only while the app is in use, so background work stays quiet.
    private func announce(_ text: String) {
        guard NSApp?.isActive == true else { return }
        AccessibilityNotification.Announcement(text).post()
    }

    /// Operations that stopped or were interrupted; in-flight repairs are not something to review.
    public static func needsReview(_ operation: RequeueJournal) -> Bool {
        [.recoveryRequired, .failed].contains(operation.phase)
    }

    /// What the Recovery badge counts: repairs to review, plus review rows no operation lists.
    public var recoveryReviewCount: Int {
        let listed = Set(repairOperations.filter(Self.needsReview).compactMap { $0.finding?.id })
        return listed.count + repairOperations.filter { Self.needsReview($0) && $0.finding == nil }.count
            + findings.filter { $0.disposition == .recoveryRequired && !listed.contains($0.id) }.count
    }

    public func events(for findingID: UUID) -> [ActivityEvent] {
        recentActivity.filter { $0.findingID == findingID }
    }

    public var watchedFolderSummary: String {
        let enabled = watchedRoots.filter(\.enabled)
        switch enabled.count {
        case 0: return watchedRoots.isEmpty ? "No folder chosen" : "All folders are off"
        case 1: return enabled[0].displayName
        default: return "\(enabled[0].displayName) and \(enabled.count - 1) more"
        }
    }

    /// One plain sentence for the current state, used in the menu header and the welcome window.
    public var statusTitle: String {
        if isRestoring { return "Starting…" }
        if needsRootConfirmation { return "Choose a folder to watch" }
        switch status {
        case .scanning: return "Scanning…"
        case .requeueing:
            let count = queueFindings(.repairing).count
            return count > 1 ? "Repairing \(count) files" : "Repairing a file"
        case .paused: return "Monitoring paused"
        case .synologyUnavailable: return "Waiting for folder access"
        case .compatibilityError: return callbacks.scan == nil ? "Monitoring isn’t connected" : "Synology status can’t be read safely"
        case .needsAttention:
            let count = attentionFindings.count
            return count == 1 ? "1 file needs attention" : "\(count) files need attention"
        case .healthy: return lastScanDate == nil ? "Not checked yet" : "No stuck uploads found"
        }
    }

    public var menuBarAccessibilityLabel: String {
        "Synology Drive Unstuckerator, " + statusTitle
    }

    /// The small overlay on the menu-bar mark. Attention is shown by the count instead.
    public var menuBarBadge: MenuBarBadge {
        if isRestoring || needsRootConfirmation { return .none }
        switch status {
        case .paused: return .paused
        case .synologyUnavailable, .compatibilityError: return .alert
        default: return .none
        }
    }

    private func rebuildQueues() {
        let ordered = findings.sorted { lhs, rhs in
            let rank = outcomeRank(lhs) - outcomeRank(rhs)
            if rank != 0 { return rank < 0 }
            let names = lhs.filename.localizedStandardCompare(rhs.filename)
            if names != .orderedSame { return names == .orderedAscending }
            return lhs.canonicalPath < rhs.canonicalPath
        }
        var groups: [FindingQueue: [FindingSnapshot]] = [:]
        for queue in FindingQueue.allCases { groups[queue] = ordered.filter(queue.includes) }
        groups[.recent] = (groups[.recent] ?? []).sorted { $0.lastCheckedAt > $1.lastCheckedAt }
        queueSnapshots = groups
        discoveredSnapshot = ordered.filter { ![.resolved, .ignored, .sourceChanged].contains($0.disposition) }
    }
    public var attentionFindings: [FindingSnapshot] { queueSnapshots[.attention] ?? [] }
    public var watchingFindings: [FindingSnapshot] { queueSnapshots[.checking] ?? [] }
    public var discoveredFindings: [FindingSnapshot] { discoveredSnapshot }
    public var recentFindings: [FindingSnapshot] { queueSnapshots[.recent] ?? [] }
    public func queueFindings(_ queue: FindingQueue) -> [FindingSnapshot] { queueSnapshots[queue] ?? [] }
    public var badgeCount: Int { attentionFindings.count }
    public var rootAvailabilityText: String? {
        let names = watchedRoots.filter { $0.enabled && unavailableRootIDs.contains($0.id) }.map(\.displayName)
        return names.isEmpty ? nil : "Waiting for folder access: " + names.joined(separator: ", ") + ". Monitoring will retry automatically."
    }
    public func applyRootAvailability(_ ids: Set<UUID>) { unavailableRootIDs = ids; refreshStatus() }
    public var automaticScopeText: String {
        let enabled = watchedRoots.filter { $0.enabled && $0.automaticRequeueEnabled && !automaticRevoked }
        guard !enabled.isEmpty else { return "Auto-fix: off" }
        return "Auto-fix: \(isPaused ? "paused" : "on") · " + enabled.map(\.displayName).joined(separator: ", ")
    }
    public var automaticSummary: String {
        guard watchedRoots.contains(where: { $0.enabled && $0.automaticRequeueEnabled && !automaticRevoked }) else { return "Auto-fix off" }
        return isPaused ? "Auto-fix paused" : "Auto-fix on"
    }
    public func selectSettingsRoot(_ id: UUID) {
        guard let root = watchedRoots.first(where: { $0.id == id }) else { return }
        editingRootID = id
        minimumStableAge = root.minimumStableAge
        ignorePatternsText = root.ignorePatterns.joined(separator: ",")
        // Select only complete presets; keep partial presets as explicit extensions.
        let saved = Set(root.extensions.map { $0.lowercased() })
        enabledFormatPresets = Set(FileFormatCatalog.presets.filter { Set($0.extensions).isSubset(of: saved) }.map(\.id))
        let preset = Set(FileFormatCatalog.presets.filter { enabledFormatPresets.contains($0.id) }.flatMap(\.extensions))
        customExtensionsText = saved.subtracting(preset).sorted().joined(separator: ", ")
    }

    public var hasPendingFolderSettings: Bool {
        guard let root = watchedRoots.first(where: { $0.id == editingRootID }) else { return false }
        return Set(root.extensions) != Set(extensions) || root.ignorePatterns != ignorePatterns
            || root.minimumStableAge != minimumStableAge
    }

    public var automaticControlsAvailable: Bool { !automaticRevoked }

    public func fileLocation(_ path: String) -> String {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        if let root = watchedRoots.filter({ parent == $0.path || parent.hasPrefix($0.path + "/") }).max(by: { $0.path.count < $1.path.count }) {
            let relative = String(parent.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return relative.isEmpty ? root.displayName : relative
        }
        return URL(fileURLWithPath: parent).lastPathComponent
    }

    public func fileActionTitle(_ finding: FindingSnapshot) -> String {
        if requeueInFlight.contains(finding.id) || finding.disposition == .requeuePreparing {
            return "Fixing…"
        }
        if finding.disposition == .requeueUploading, finding.retryPath != nil {
            return "Check Upload"
        }
        if finding.disposition == .requeueSucceeded { return "Check Final Name" }
        if canRequeue(finding) || [.observing, .actionable, .existingNeedsReview].contains(finding.disposition) { return "Fix" }
        return outcomeLabel(finding)
    }

    public func outcomeLabel(_ finding: FindingSnapshot) -> String {
        switch finding.disposition {
        case .requeueSucceeded: "Placed"
        case .requeueFailed: "Stopped"
        case .recoveryRequired: "Review recovery"
        case .requeuePreparing, .requeueUploading: "Fixing"
        case .observing: "Confirming"
        case .actionable, .existingNeedsReview: "Needs attention"
        case .resolved: "Resolved"
        case .ignored: "Ignored"
        case .sourceChanged: "File changed"
        case .compatibilityBlocked: "Could not read"
        }
    }

    public func resetQueue() {
        // Keep ownership until the actual task finishes; Reset only clears unprotected history.
        let protected = Set(recoveryFiles.compactMap { $0.record.findingID })
        findings.removeAll {
            !$0.hasRepairEvidence && !protected.contains($0.id) && !requeueInFlight.contains($0.id)
                && !FindingRepository.isDecision($0.disposition)
        }
        recentActivity = []; persistedEventIDs = []; historyLimit = 100; hasMoreHistory = true
        lastErrorText = nil
        refreshStatus()
        Task {
            do {
                if let retained = try await callbacks.resetQueueStore?() { assignFindings(retained) }
                // Events tied to protected repairs survive in the store; show them again.
                if let events = try await callbacks.loadEvents?() { applyEventUpdate(events) }
                await refreshRecovery()
                append(.settings, "Unprotected history cleared. Repair and recovery records were kept.")
            } catch {
                lastErrorText = error.localizedDescription
                append(.compatibility, "The local queue could not be reset.", details: lastErrorText)
            }
            refreshStatus()
        }
    }

    private func outcomeRank(_ finding: FindingSnapshot) -> Int {
        switch finding.disposition {
        case .requeueFailed, .recoveryRequired, .compatibilityBlocked: 0
        case .actionable, .existingNeedsReview: 1
        case .requeuePreparing, .requeueUploading, .observing: 2
        case .requeueSucceeded, .resolved: 3
        case .sourceChanged, .ignored: 4
        }
    }
    public var baselineNeedsReview: Bool { watchedRoots.contains { $0.enabled && $0.baselineCompletedAt == nil } }
    public var lowDiskWarning: String? {
        guard let availableDiskBytes else { return nil }
        let threshold = max(100, lowDiskWarningThresholdGiB) * 1_073_741_824
        guard Double(availableDiskBytes) < threshold else { return nil }
        return availableDiskBytes < 100 * 1_073_741_824
            ? "Less than 100 GiB free on the watched volume. This warning is display only."
            : "Free space is below your \(Int(max(100, lowDiskWarningThresholdGiB))) GiB warning threshold."
    }

    public func restoreSavedMonitoring() async {
        defer {
            isRestoring = false
            scheduleAutomaticRepair()
            // A menu-bar app shows nothing at launch; first-run setup needs a window to be found.
            if needsRootConfirmation { present(.welcome) }
        }
        if callbacks.scan != nil { freshScanRequiredSince = Date() }
        guard let loadRoots = callbacks.loadRoots else {
            needsRootConfirmation = watchedRoots.isEmpty
            return
        }
        do {
            try await callbacks.restoreOperations?()
            if let saved = try await callbacks.loadFindings?() { assignFindings(saved) }
            if let events = try await callbacks.loadEvents?() { applyEventUpdate(events) }
            await refreshRecovery()
            let roots = try await loadRoots()
            guard !roots.isEmpty else {
                needsRootConfirmation = true
                return
            }
            watchedRoots = roots
            selectSettingsRoot(roots[0].id)
            automaticRequeueEnabled = !automaticRevoked && roots.contains { $0.enabled && $0.automaticRequeueEnabled }
            needsRootConfirmation = false
            isPaused = callbacks.loadMonitoringPaused?() ?? false
            monitoringEnabled = !isPaused
            try await startMonitoring(roots, paused: isPaused)
            if !isPaused, let scan = callbacks.scan {
                // The engine is running; a startup scan that loses a race (a settings change restarts the
                // engine, or another scan holds it) is not a reason to pause monitoring for the session.
                do {
                    let scanned = try await scan()
                    freshScanRequiredSince = nil
                    assignFindings(scanned)
                    lastScanDate = Date()
                } catch is CancellationError {
                } catch {
                    append(.compatibility, "The startup scan did not finish. Monitoring continues.", details: error.localizedDescription)
                }
            }
            if let events = try await callbacks.loadEvents?() {
                applyEventUpdate(events)
            }
            refreshDiskFreeSpace()
            refreshStatus()
        } catch {
            try? await callbacks.pause?(true)
            needsEngineRestart = true
            monitoringEnabled = false
            isPaused = true
            lastErrorText = error.localizedDescription
            needsRootConfirmation = watchedRoots.isEmpty
        }
    }

    public func applyRepairUpdate(_ finding: FindingSnapshot) {
        let previous = findings.first { $0.id == finding.id }
        replaceFinding(finding)
        refreshStatus()
        // Background verification can archive the original; Undo needs the retained-files list to see it.
        if previous?.disposition != finding.disposition || previous?.providerState != finding.providerState {
            Task { await refreshRecovery() }
        }
    }

    public func applyStoreUpdate(findings: [FindingSnapshot], events: [ActivityEvent]) {
        assignFindings(findings)
        applyEventUpdate(events)
        refreshStatus()
    }
    public func applyPathUpdate(path: String, findings updated: [FindingSnapshot]) {
        assignFindings(findings.filter { $0.canonicalPath != path } + updated)
        refreshStatus()
    }
    public func applyEventUpdate(_ events: [ActivityEvent]) {
        let incoming = Set(events.map(\.id))
        recentActivity = Array((events + recentActivity.filter { !incoming.contains($0.id) })
            .sorted { $0.timestamp > $1.timestamp }.prefix(historyLimit))
        persistedEventIDs.formUnion(incoming)
        persistedEventIDs.formIntersection(Set(recentActivity.map(\.id)))
        if let scan = events.first(where: { $0.kind == .scan }), scan.timestamp > lastScanDate ?? .distantPast {
            lastScanDate = scan.timestamp
        }
        // A scheduled reconcile that finished after launch counts as the fresh scan auto-fix waits for.
        if let since = freshScanRequiredSince, events.contains(where: { $0.kind == .scan && $0.timestamp >= since }) {
            freshScanRequiredSince = nil
            scheduleAutomaticRepair()
        }
    }

    public func setNotificationsEnabled(_ enabled: Bool) {
        desktopNotificationsEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "desktopNotificationsEnabled")
        Task {
            // Read the status after the system prompt is answered, not before.
            applyNotificationAuthorization(enabled ? await FindingNotifier.requestAuthorization() : await FindingNotifier.authorization())
        }
    }

    public func refreshNotificationStatus() async {
        applyNotificationAuthorization(await FindingNotifier.authorization())
    }

    private func applyNotificationAuthorization(_ authorization: FindingNotifier.Authorization) {
        notificationAuthorization = authorization
        notificationStatusText = authorization.description
    }

    public func setLowDiskWarningThreshold(_ value: Double) {
        guard value.isFinite, value >= 0 else { lastErrorText = "Enter a valid disk warning threshold."; return }
        lowDiskWarningThresholdGiB = value
        UserDefaults.standard.set(value, forKey: "lowDiskWarningThresholdGiB")
    }

    public func chooseFolder() {
        guard !savingConfiguration, !savingAutomaticSetting, !changingMonitoring else { return }
        guard let folder = pickFolder() else { return }
        confirmRoot(folder)
    }

    public func addFolder() {
        guard !savingConfiguration, !savingAutomaticSetting, !changingMonitoring else { return }
        guard let folder = pickFolder() else { return }
        addRoot(folder)
    }

    public func addRoot(_ url: URL) {
        guard !savingConfiguration, !savingAutomaticSetting, !changingMonitoring else { return }
        guard let canonical = validatedFolder(url) else { return }
        for existing in watchedRoots {
            let path = URL(fileURLWithPath: existing.path).standardizedFileURL.resolvingSymlinksInPath().path
            if canonical.path == path || canonical.path.hasPrefix(path == "/" ? "/" : path + "/") {
                lastErrorText = "This folder is already covered by \(existing.displayName). Nested folders are included automatically."
                return
            }
            if path.hasPrefix(canonical.path == "/" ? "/" : canonical.path + "/") {
                lastErrorText = "This folder includes \(existing.displayName), which is already monitored. Choose a separate folder."
                return
            }
        }
        let root = WatchedRootSnapshot(id: UUID(), path: canonical.path, displayName: canonical.lastPathComponent,
            enabled: true, extensions: FileFormatCatalog.extensions(enabledPresetIDs: ["video"], customText: ""),
            ignorePatterns: ["*_segment_*", "*__requeued-*", "* conflicted copy*", "*(conflict*"],
            minimumStableAge: 300, automaticRequeueEnabled: false)
        applyConfiguration(watchedRoots + [root], selecting: root.id)
    }

    public func removeRoot(_ id: UUID) {
        guard watchedRoots.count > 1, watchedRoots.contains(where: { $0.id == id }) else { return }
        let roots = watchedRoots.filter { $0.id != id }
        let selection = editingRootID == id ? roots.first?.id : editingRootID
        applyConfiguration(roots, selecting: selection)
    }

    private func validatedFolder(_ url: URL) -> URL? {
        guard url.isFileURL else { lastErrorText = "Choose a local folder."; return nil }
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        guard !FileManager.default.fileExists(atPath: canonical.appendingPathComponent(".git").path) else {
            lastErrorText = "A repository cannot be used as a watched folder."
            return nil
        }
        do {
            guard try canonical.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                lastErrorText = "The selected folder is unavailable."
                return nil
            }
        } catch { lastErrorText = "The selected folder cannot be read: \(error.localizedDescription)"; return nil }
        return canonical
    }

    public func confirmRoot(_ url: URL) {
        guard let canonical = validatedFolder(url) else { return }
        let root = WatchedRootSnapshot(id: UUID(), path: canonical.path, displayName: canonical.lastPathComponent,
            enabled: true, extensions: extensions, ignorePatterns: ignorePatterns, minimumStableAge: minimumStableAge,
            automaticRequeueEnabled: false)
        guard !savingConfiguration, !savingAutomaticSetting, !changingMonitoring else { return }
        savingConfiguration = true
        let paused = !needsRootConfirmation && isPaused
        // Root replacement is a new opt-in scope. Revoke prior automatic dispatch now.
        automaticRequeueEnabled = false
        Task {
            defer { savingConfiguration = false; refreshStatus() }
            do {
                try await saveConfiguration([root])
                watchedRoots = [root]
                selectSettingsRoot(root.id)
                needsRootConfirmation = false
                try await startMonitoring([root], paused: paused)
                monitoringEnabled = !paused
                isPaused = paused
                callbacks.saveMonitoringPaused?(paused)
                lastErrorText = nil
                refreshDiskFreeSpace()
            } catch {
                try? await callbacks.pause?(true)
                needsEngineRestart = true
                monitoringEnabled = false
                isPaused = true
                lastErrorText = error.localizedDescription
            }
        }
    }

    private func saveConfiguration(_ roots: [WatchedRootSnapshot]) async throws {
        if let save = callbacks.saveRoots { try await save(roots) }
        else if let save = callbacks.saveRoot { for root in roots { try await save(root) } }
        else { throw MonitoringError.blocked(reason: "Monitoring settings are not connected.") }
    }

    private func startMonitoring(_ roots: [WatchedRootSnapshot], paused: Bool) async throws {
        if let start = callbacks.startPaused { try await start(roots, paused) }
        else if let start = callbacks.start {
            try await start(roots)
            if paused { try await callbacks.pause?(true) }
        } else { throw MonitoringError.blocked(reason: "Monitoring is not connected.") }
        if let load = callbacks.loadUnavailableRoots { applyRootAvailability(await load()) }
    }

    public func scanNow() {
        guard !needsRootConfirmation, !isScanning else { return }
        isScanning = true
        status = .scanning
        refreshDiskFreeSpace()
        scanTask = Task {
            var finished = false
            defer {
                isScanning = false; scanTask = nil; refreshStatus()
                if finished { announce("Scan finished. \(statusTitle).") }
            }
            do {
                if let scan = callbacks.scan {
                    let scanned = try await scan()
                    freshScanRequiredSince = nil
                    assignFindings(scanned)
                    lastScanDate = Date()
                    finished = true
                    append(.scan, "Recent-file scan completed.")
                } else {
                    append(.compatibility, "Scan blocked: the monitoring engine is not connected.")
                }
            } catch is CancellationError { append(.scan, "Scan cancelled.") }
            catch { lastErrorText = error.localizedDescription; append(.compatibility, "Scan blocked.", details: lastErrorText) }
        }
    }
    public func cancelScan() { scanTask?.cancel() }

    public func togglePause() {
        guard !needsRootConfirmation else { return }
        setMonitoringEnabled(isPaused)
    }

    public func setMonitoringEnabled(_ enabled: Bool) {
        guard !needsRootConfirmation, !changingMonitoring, !savingConfiguration, !savingAutomaticSetting else { return }
        changingMonitoring = true
        // Revokes automatic dispatch immediately while the engine acknowledges Pause.
        let previous = monitoringEnabled
        monitoringEnabled = enabled
        isPaused = !enabled
        refreshStatus()
        Task {
            defer { changingMonitoring = false; refreshStatus(); scheduleAutomaticRepair() }
            do {
                if enabled && needsEngineRestart {
                    try await startMonitoring(watchedRoots, paused: false)
                    needsEngineRestart = false
                } else { try await callbacks.pause?(!enabled) }
                callbacks.saveMonitoringPaused?(!enabled)
                append(.settings, enabled ? "Monitoring resumed." : "Monitoring paused.")
            } catch {
                monitoringEnabled = previous
                isPaused = !previous
                lastErrorText = error.localizedDescription
            }
        }
    }

    public func recheck(id: UUID) {
        if let finding = findings.first(where: { $0.id == id }), finding.disposition == .requeueUploading {
            requeue(id: id)
            return
        }
        guard let finding = findings.first(where: { $0.id == id }) else { return }
        append(.scan, "Recheck requested for \(finding.filename).", findingID: id)
        Task {
            do {
                guard let recheck = callbacks.recheck else {
                    append(.compatibility, "Recheck blocked: the monitoring engine is not connected.", findingID: id)
                    return
                }
                if let refreshed = try await recheck(id), let index = findings.firstIndex(where: { $0.id == id }) {
                    findings[index] = refreshed
                }
            } catch { lastErrorText = error.localizedDescription; append(.compatibility, "Recheck blocked.", findingID: id, details: lastErrorText) }
            refreshStatus()
        }
    }

    public private(set) var requeueInFlight: Set<UUID> = []

    public func canRequeue(_ finding: FindingSnapshot) -> Bool {
        guard !isBusy(finding), requeueInFlight.isEmpty, unreadableOperationFiles.isEmpty else { return false }
        if finding.disposition == .requeueUploading { return finding.retryPath != nil }
        if finding.disposition == .requeueSucceeded { return repairOperations.first { $0.finding?.id == finding.id }?.finalPathVerifiedAt == nil }
        guard !findings.contains(where: {
            $0.id != finding.id && $0.canonicalPath == finding.canonicalPath && $0.hasRepairEvidence
                && ![.requeueSucceeded, .resolved, .ignored].contains($0.disposition)
        }) else { return false }
        return ManualRepairEligibility.canStart(finding)
    }

    private func isBusy(_ finding: FindingSnapshot) -> Bool {
        requeueInFlight.contains(finding.id) || findings.contains {
            $0.canonicalPath == finding.canonicalPath && requeueInFlight.contains($0.id)
        }
    }

    public func canUndo(_ finding: FindingSnapshot) -> Bool {
        unreadableOperationFiles.isEmpty && finding.disposition == .requeueSucceeded && !isBusy(finding) && recoveryFiles.contains {
            $0.record.findingID == finding.id && !$0.record.isExpired(at: Date())
                && $0.record.expectedReplacementSHA256 != nil && $0.exists
        }
    }

    public func refreshRecovery() async {
        do {
            if let unreadable = try await callbacks.loadUnreadableArchives?() { unreadableArchiveFiles = unreadable }
            if let files = try await callbacks.loadRecovery?() { recoveryFiles = files }
            if let operations = try await callbacks.loadOperations?() { repairOperations = operations }
            // The menu and Recovery show a persistent notice while these exist; a dismissible error would hide it.
            if let unreadable = try await callbacks.loadUnreadableOperations?() { unreadableOperationFiles = unreadable }
        }
        catch { lastErrorText = error.localizedDescription }
    }

    public func undo(id: UUID) {
        guard let finding = findings.first(where: { $0.id == id }), canUndo(finding) else { return }
        requeueInFlight.insert(id)
        Task {
            defer { requeueInFlight.remove(id); refreshStatus() }
            do {
                if let updated = try await callbacks.undo?(id) { replaceFinding(updated) }
                append(.recovery, "\(finding.filename): original restored; retained copy is in Recovery.")
            } catch { lastErrorText = error.localizedDescription }
            // A failed Undo may have written durable recovery intent. Load that instead of stale Fixed.
            // Read after Undo finished, so it is authoritative for this row.
            if let saved = try? await callbacks.loadFindings?() { assignFindings(saved, fromSnapshot: false) }
            await refreshRecovery()
        }
    }

    public func resolveRecovery(id: UUID, choice: RecoveryChoice) {
        guard let finding = findings.first(where: { $0.id == id }), !isBusy(finding) else { return }
        requeueInFlight.insert(id)
        Task {
            defer { requeueInFlight.remove(id); refreshStatus() }
            do {
                if let updated = try await callbacks.resolveRecovery?(id, choice) { replaceFinding(updated) }
                if let saved = try await callbacks.loadFindings?() { assignFindings(saved, fromSnapshot: false) }
            } catch { lastErrorText = error.localizedDescription }
            await refreshRecovery()
        }
    }

    public func setFormatPreset(_ id: String, enabled: Bool) {
        if enabled { enabledFormatPresets.insert(id) } else { enabledFormatPresets.remove(id) }
        UserDefaults.standard.set(Array(enabledFormatPresets), forKey: "formatPresets")
    }

    public func setCustomExtensions(_ text: String) {
        customExtensionsText = text
        UserDefaults.standard.set(text, forKey: "customExtensions")
    }

    public func requeue(id: UUID) {
        startRepair(id: id, automatic: false)
    }

    private func startRepair(id: UUID, automatic: Bool) {
        guard let index = findings.firstIndex(where: { $0.id == id }), canRequeue(findings[index]) else { return }
        let previous = findings[index]
        findings[index].disposition = .requeuePreparing
        findings[index].providerState = previous.retryPath == nil ? "Preparing and verifying a retry copy" : "Checking the existing retry upload"
        findings[index].eligibilityBlockReason = nil
        status = .requeueing
        requeueInFlight.insert(id)
        let step = previous.disposition == .requeueSucceeded ? "checking the final filename"
            : previous.retryPath == nil ? "preparing a sibling retry copy" : "checking the existing retry upload"
        append(.requeueStarted, "\(previous.filename): \(automatic ? "auto-fix" : "manual fix") \(step).", findingID: id)
        Task {
            defer {
                requeueInFlight.remove(id)
                if automatic {
                    automaticInFlight = nil
                    automaticCoordinator.finish(result: findings.first { $0.id == id })
                }
                refreshStatus()
                scheduleAutomaticRepair()
            }
            do {
                let updated: FindingSnapshot?
                if automatic, let run = callbacks.automaticRequeue {
                    updated = try await run(id, { [self] in
                        await automaticPermission(rootID: previous.rootIdentifier)
                    })
                } else if !automatic, let run = callbacks.requeue {
                    updated = try await run(id)
                } else {
                    throw MonitoringError.blocked(reason: "Repair is not connected.")
                }
                replaceFinding(updated ?? previous)
                await refreshRecovery()
            } catch {
                if let current = findings.firstIndex(where: { $0.id == id }), findings[current].disposition == .requeuePreparing {
                    findings[current] = previous
                }
                lastErrorText = error.localizedDescription
                if let index = findings.firstIndex(where: { $0.id == id }) { findings[index].eligibilityBlockReason = error.localizedDescription }
                append(.requeueBlocked, "\(previous.filename): requeue stopped.", findingID: id, details: lastErrorText)
            }
        }
    }

    private func replaceFinding(_ finding: FindingSnapshot) {
        var updated = findings
        if let index = updated.firstIndex(where: { $0.id == finding.id }) {
            updated[index] = finding
        } else {
            updated.append(finding)
        }
        assignFindings(updated, fromSnapshot: false)
    }

    /// `fromSnapshot` rows were read from the store and may predate a repair that has since started.
    private func assignFindings(_ updated: [FindingSnapshot], fromSnapshot: Bool = true) {
        var incoming = updated
        if fromSnapshot && !requeueInFlight.isEmpty {
            // While a repair, Undo, or recovery runs, its row comes only from that operation's own updates.
            // An older snapshot could put it back to a stale state and announce that again.
            let live = Dictionary(findings.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for index in incoming.indices where requeueInFlight.contains(incoming[index].id) {
                if let current = live[incoming[index].id] { incoming[index] = current }
            }
        }
        announce(from: findings, to: incoming)
        findings = incoming
        scheduleAutomaticRepair()
    }

    private func automaticPermission(rootID: UUID) -> Bool {
        freshScanRequiredSince == nil
            && !unavailableRootIDs.contains(rootID) && !automaticRevoked && automaticRequeueEnabled && monitoringEnabled && !isPaused && !isRestoring
            && !needsRootConfirmation && !savingAutomaticSetting && !savingConfiguration && !changingMonitoring && unreadableOperationFiles.isEmpty
            && watchedRoots.contains { $0.id == rootID && $0.enabled && $0.automaticRequeueEnabled && $0.baselineCompletedAt != nil }
    }

    private func scheduleAutomaticRepair() {
        guard automaticInFlight == nil, requeueInFlight.isEmpty, callbacks.automaticRequeue != nil else { return }
        let permitted = Set(watchedRoots.filter { automaticPermission(rootID: $0.id) }.map(\.id))
        let operations = repairOperations
        guard let finding = automaticCoordinator.reserve(findings: findings, roots: watchedRoots, permittedRootIDs: permitted,
            eligible: { self.canRequeue($0) && !AutomaticRepairCoordinator.hasOperation(for: $0, in: operations) }) else { return }
        automaticInFlight = finding.id
        startRepair(id: finding.id, automatic: true)
    }

    public func setAutomaticRequeueEnabled(_ enabled: Bool, rootID: UUID? = nil) {
        guard !savingAutomaticSetting, !savingConfiguration, !changingMonitoring, !needsRootConfirmation else { return }
        guard !enabled || !watchedRoots.contains(where: { $0.enabled && (rootID == nil || $0.id == rootID) && $0.baselineCompletedAt == nil }) else {
            lastErrorText = "Review files found at setup before enabling auto-fix."
            return
        }
        var updated = watchedRoots
        let previouslyRevoked = automaticRevoked
        if enabled && rootID != nil && previouslyRevoked {
            // Re-enabling one folder must not restore other stale opt-ins after a failed opt-out save.
            for index in updated.indices { updated[index].automaticRequeueEnabled = false }
        }
        for index in updated.indices where rootID.map({ $0 == updated[index].id }) ?? (enabled ? updated[index].enabled : true) {
            updated[index].automaticRequeueEnabled = enabled
        }
        if !enabled {
            automaticRevoked = true
            do { try callbacks.saveAutomaticRevocation?(true) }
            catch { lastErrorText = "Auto-fix is off in this session, but revocation storage could not be updated. \(error.localizedDescription)" }
        }
        savingAutomaticSetting = true
        automaticRequeueEnabled = false
        // Do not undo revoked permission if persistence or restart subsequently fails.
        if !enabled { watchedRoots = updated }
        let paused = isPaused
        Task {
            defer { savingAutomaticSetting = false; scheduleAutomaticRepair() }
            do {
                try await saveConfiguration(updated)
                watchedRoots = updated
                if enabled {
                    try callbacks.saveAutomaticRevocation?(false)
                    automaticRevoked = false
                } else if rootID != nil && !previouslyRevoked {
                    // Keep the barrier until the folder-specific opt-out is durably saved.
                    try callbacks.saveAutomaticRevocation?(false)
                    automaticRevoked = false
                }
                automaticRequeueEnabled = !automaticRevoked && updated.contains { $0.enabled && $0.automaticRequeueEnabled }
                append(.settings, enabled ? "Auto-fix enabled for new confirmed failures." : "Auto-fix disabled.")
                // Revocation remains durable even if monitoring cannot restart.
                try await startMonitoring(updated, paused: paused)
            } catch {
                if enabled { automaticRequeueEnabled = false }
                try? await callbacks.pause?(true)
                needsEngineRestart = true
                monitoringEnabled = false
                isPaused = true
                lastErrorText = "Settings could not be fully applied. Monitoring is paused. \(error.localizedDescription)"
            }
        }
    }

    private func announce(from previous: [FindingSnapshot], to updated: [FindingSnapshot]) {
        // The first load at launch is saved history, not news.
        guard desktopNotificationsEnabled, !(isRestoring && previous.isEmpty) else { return }
        let earlier = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for finding in updated {
            // A re-check you started yourself (the row was preparing) shows its result in place.
            if finding.finalNameFailed, let before = earlier[finding.id], !before.finalNameFailed,
               before.disposition != .requeuePreparing {
                FindingNotifier.notify(title: finding.filename,
                    body: "Synology reports the final filename failed to upload. The original is kept for Undo.", findingID: finding.id)
                continue
            }
            let before = earlier[finding.id]?.disposition
            guard before != finding.disposition else { continue }
            // An outcome for a row this session never saw is history from another session.
            if before == nil, [.requeueSucceeded, .requeueFailed, .recoveryRequired].contains(finding.disposition) { continue }
            switch finding.disposition {
            case .actionable, .existingNeedsReview:
                guard before != .actionable, before != .existingNeedsReview else { continue }
                FindingNotifier.notify(title: finding.filename,
                    body: "Synology Drive stopped uploading this file. Click to review it and choose Fix.", findingID: finding.id)
            case .requeueSucceeded:
                FindingNotifier.notify(title: finding.filename, body: finding.providerState, findingID: finding.id)
            case .requeueFailed:
                FindingNotifier.notify(title: finding.filename, body: finding.eligibilityBlockReason ?? "The repair stopped.", findingID: finding.id)
            case .recoveryRequired:
                FindingNotifier.notify(title: finding.filename,
                    body: "A repair was interrupted. Click to review the retained copies.", findingID: finding.id)
            default:
                break
            }
        }
    }

    private func indexOrCurrent(_ id: UUID, fallback: Int) -> Int {
        findings.firstIndex(where: { $0.id == id }) ?? fallback
    }

    public func canDismiss(_ finding: FindingSnapshot) -> Bool {
        guard !isBusy(finding), !finding.hasRepairEvidence else { return false }
        return switch finding.disposition {
        case .requeueSucceeded, .requeueFailed, .resolved, .sourceChanged, .compatibilityBlocked:
            true
        default:
            false
        }
    }

    public func dismiss(id: UUID) { changeDisposition(id: id, to: .resolved) }

    public func ignore(id: UUID) { changeDisposition(id: id, to: .ignored) }
    public func markResolved(id: UUID) { changeDisposition(id: id, to: .resolved) }

    private func changeDisposition(id: UUID, to disposition: FindingDisposition) {
        guard let index = findings.firstIndex(where: { $0.id == id }), !isBusy(findings[index]), !findings[index].hasRepairEvidence else { return }
        let previous = findings[index]
        findings[index].disposition = disposition
        let updated = findings[index]
        append(.settings, "\(updated.filename): \(disposition == .ignored ? "source version ignored" : "marked resolved locally").",
               findingID: id, result: disposition.rawValue)
        refreshStatus()
        Task {
            do { try await callbacks.saveFinding?(updated) }
            catch {
                if let current = findings.firstIndex(where: { $0.id == id }), findings[current] == updated { findings[current] = previous }
                lastErrorText = error.localizedDescription
                append(.compatibility, "Local disposition could not be saved.", findingID: id, details: lastErrorText)
                refreshStatus()
            }
        }
    }

    public func acknowledgeBaseline(rootID: UUID? = nil) {
        guard !acknowledgingBaseline else { return }
        let pending = watchedRoots.filter { $0.enabled && $0.baselineCompletedAt == nil && (rootID == nil || rootID == $0.id) }
        guard !pending.isEmpty else { return }
        acknowledgingBaseline = true
        Task {
            defer { acknowledgingBaseline = false }
            for root in pending {
                let timestamp = Date()
                do {
                    if let acknowledge = callbacks.acknowledgeBaseline { try await acknowledge(root.id, timestamp) }
                    else if let save = callbacks.saveRoot {
                        var updated = root
                        updated.baselineCompletedAt = timestamp
                        try await save(updated)
                    }
                    if let index = watchedRoots.firstIndex(where: { $0.id == root.id }) { watchedRoots[index].baselineCompletedAt = timestamp }
                    append(.baseline, "First-launch baseline reviewed for \(root.displayName). Existing findings keep their disposition.")
                } catch { lastErrorText = error.localizedDescription; return }
            }
        }
    }

    public func refreshDiskFreeSpace() {
        guard let root = watchedRoots.first(where: \.enabled) else { return }
        do {
            availableDiskBytes = try URL(fileURLWithPath: root.path)
                .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
            diskFreeSpaceText = availableDiskBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .binary) + " available" }
                ?? "Disk free space unavailable"
        } catch { availableDiskBytes = nil; diskFreeSpaceText = "Disk free space unavailable" }
    }

    public func setLaunchAtLogin(_ enabled: Bool) {
        guard !changingLaunchAtLogin else { return }
        let previous = launchAtLogin
        launchAtLogin = enabled
        changingLaunchAtLogin = true
        Task {
            defer { changingLaunchAtLogin = false }
            do {
                if enabled { try SMAppService.mainApp.register() }
                else { try await SMAppService.mainApp.unregister() }
                refreshLaunchAtLoginStatus()
                if launchAtLoginNeedsApproval {
                    SMAppService.openSystemSettingsLoginItems()
                }
            } catch {
                launchAtLogin = previous
                refreshLaunchAtLoginStatus()
                lastErrorText = "Launch at Login could not be changed. \(error.localizedDescription)"
            }
        }
    }

    public func refreshLaunchAtLoginStatus() {
        let status = SMAppService.mainApp.status
        launchAtLoginNeedsApproval = status == .requiresApproval
        launchAtLogin = status == .enabled || status == .requiresApproval
        launchAtLoginStatusText = Self.loginStatus(status)
    }

    public func applyRootSettings() {
        guard !savingAutomaticSetting, !savingConfiguration, !changingMonitoring else { return }
        guard minimumStableAge.isFinite, minimumStableAge >= 0,
              lowDiskWarningThresholdGiB.isFinite, lowDiskWarningThresholdGiB >= 0, !extensions.isEmpty else {
            lastErrorText = "Enter a valid minimum stable age, a warning threshold, and at least one extension."
            return
        }
        var roots = watchedRoots
        for index in roots.indices where editingRootID == nil || roots[index].id == editingRootID {
            roots[index].extensions = extensions
            roots[index].ignorePatterns = ignorePatterns
            roots[index].minimumStableAge = minimumStableAge
        }
        applyConfiguration(roots)
    }

    public func setRootEnabled(_ id: UUID, enabled: Bool) {
        var roots = watchedRoots
        guard let index = roots.firstIndex(where: { $0.id == id }) else { return }
        roots[index].enabled = enabled
        applyConfiguration(roots)
    }

    private func applyConfiguration(_ roots: [WatchedRootSnapshot], selecting selectedID: UUID? = nil) {
        guard !savingConfiguration, !savingAutomaticSetting, !changingMonitoring else { return }
        savingConfiguration = true
        let paused = !needsRootConfirmation && isPaused
        Task {
            defer { savingConfiguration = false; refreshStatus(); scheduleAutomaticRepair() }
            do {
                try await saveConfiguration(roots)
                watchedRoots = roots
                if let selectedID { selectSettingsRoot(selectedID) }
                needsRootConfirmation = roots.isEmpty
                automaticRequeueEnabled = !automaticRevoked && roots.contains { $0.enabled && $0.automaticRequeueEnabled }
                try await startMonitoring(roots, paused: paused)
                needsEngineRestart = false
                monitoringEnabled = !paused
                isPaused = paused
                callbacks.saveMonitoringPaused?(paused)
                append(.settings, "Monitoring settings updated.")
                lastErrorText = nil
                refreshDiskFreeSpace()
                if selectedID != nil && !paused { scanNow() }
            } catch {
                try? await callbacks.pause?(true)
                needsEngineRestart = true
                monitoringEnabled = false
                isPaused = true
                lastErrorText = error.localizedDescription
            }
        }
    }

    public func loadMoreHistory() {
        guard !loadingMoreHistory, hasMoreHistory, let load = callbacks.loadEventPage else { return }
        loadingMoreHistory = true
        let offset = persistedEventIDs.count
        Task {
            defer { loadingMoreHistory = false }
            do {
                let page = try await load(100, offset)
                historyLimit += 100
                applyEventUpdate(page)
                hasMoreHistory = page.count == 100
            } catch { lastErrorText = error.localizedDescription }
        }
    }

    public func repairBlockReason(_ finding: FindingSnapshot) -> String? {
        if !requeueInFlight.isEmpty { return "A repair is already running. Other repairs wait for it to finish." }
        if !unreadableOperationFiles.isEmpty { return "Review unreadable records in Activity → Recovery." }
        if canRequeue(finding) { return nil }
        return finding.eligibilityBlockReason ?? "Waiting for a stable file and a confirmed upload failure."
    }

    public func diagnosticText(_ text: String) -> String {
        guard !showRawPaths, text.contains("/") else { return text }
        return "Details hidden while paths are redacted."
    }

    public func exportRecovery(_ file: RecoveryFile, to destination: URL) {
        guard exportTask == nil else { return }
        exportProgress = (0, file.size)
        exportTask = Task.detached(priority: .utility) { [weak self] in
            do {
                try await RecoveryExport.copy(source: file.url, destination: destination, expectedSHA256: file.record.archivedSHA256) { copied, total in
                    await MainActor.run { self?.exportProgress = (copied, total) }
                }
                await self?.finishExport(error: nil)
            } catch is CancellationError { await self?.finishExport(error: nil) }
            catch { await self?.finishExport(error: error.localizedDescription) }
        }
    }
    public func cancelExport() { exportTask?.cancel() }
    private func finishExport(error: String?) {
        exportTask = nil; exportProgress = nil
        if let error { lastErrorText = error }
    }

    public func copyDiagnostic(id: UUID) -> String {
        guard let finding = findings.first(where: { $0.id == id }) else { return "Finding unavailable." }
        return """
        Synology Drive Unstuckerator
        File: \(finding.filename)
        Path: \(pathText(finding.canonicalPath))
        Size: \(finding.fileSize) bytes
        Modified: \(finding.modificationDate.ISO8601Format())
        First detected: \(finding.firstDetectedAt.ISO8601Format())
        Last checked: \(finding.lastCheckedAt.ISO8601Format())
        Last confirmed: \(finding.lastConfirmedAt?.ISO8601Format() ?? "Unavailable")
        Provider item: \(showRawPaths ? finding.fileProviderItemIdentifier ?? "Unavailable" : "Hidden")
        Provider state: \(diagnosticText(finding.providerState))
        Error: \(finding.errorDomain ?? "None") / \(finding.errorCode.map(String.init) ?? "None")
        Confirmations: \(finding.confirmationCount)
        Disposition: \(finding.disposition.rawValue)
        Retry eligibility: \(canRequeue(finding) ? "Fix can publish one verified copy" : "Fix is not available for this row")
        Block reason: \(diagnosticText(finding.eligibilityBlockReason ?? "None"))
        Attempts: \(finding.attemptCount)
        Retry: \(finding.retryPath.map(pathText) ?? "None")
        Retry item: \(showRawPaths ? finding.retryItemIdentifier ?? "None" : "Hidden")
        Upload verified: \(finding.uploadVerifiedAt?.ISO8601Format() ?? "Not verified")
        Source SHA-256: \(finding.sourceSHA256 ?? "Not calculated")
        Retry SHA-256: \(finding.retrySHA256 ?? "Not calculated")
        Diagnostic: \(rawDiagnostic(for: finding))
        """
    }

    public func diagnosticSummary() -> String {
        (["Synology Drive Unstuckerator", diagnosticText(historicalProviderCountText), "Active uploads: \(activeUploadCount)"]
            + findings.map { copyDiagnostic(id: $0.id) }).joined(separator: "\n\n")
    }

    public func exportDiagnostic() {
        let diagnostic = diagnosticSummary()
        do {
            guard let export = callbacks.exportDiagnostic else { lastErrorText = "Diagnostic export is unavailable in this preview."; return }
            try export(diagnostic)
        } catch { lastErrorText = error.localizedDescription }
    }

    public func pathText(_ path: String) -> String { showRawPaths ? path : "…/" + URL(fileURLWithPath: path).lastPathComponent }
    public func rawDiagnostic(for finding: FindingSnapshot) -> String {
        showRawPaths ? (finding.rawDiagnostic ?? "No raw diagnostic available.") : "Raw diagnostic hidden while paths are redacted."
    }

    private var extensions: [String] {
        FileFormatCatalog.extensions(enabledPresetIDs: enabledFormatPresets, customText: customExtensionsText)
    }
    private var ignorePatterns: [String] { ignorePatternsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }

    private func refreshStatus() {
        if isScanning { status = .scanning; return }
        if findings.contains(where: { $0.disposition == .requeuePreparing || $0.disposition == .requeueUploading }) {
            status = .requeueing
        } else if isPaused { status = .paused }
        else if rootAvailabilityText != nil { status = .synologyUnavailable }
        else if findings.contains(where: { $0.disposition == .compatibilityBlocked }) || callbacks.scan == nil { status = .compatibilityError }
        else { status = attentionFindings.isEmpty ? .healthy : .needsAttention }
    }

    private func append(_ kind: ActivityKind, _ summary: String, findingID: UUID? = nil, details: String? = nil, result: String? = nil) {
        recentActivity.insert(ActivityEvent(id: UUID(), timestamp: Date(), kind: kind, findingID: findingID,
            summary: summary, details: details, result: result), at: 0)
        if recentActivity.count > historyLimit { recentActivity = Array(recentActivity.prefix(historyLimit)) }
    }

    private static func loginStatus(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered: "Not registered"
        case .enabled: "Enabled"
        case .requiresApproval: "Requires approval in System Settings"
        case .notFound: "App service not found"
        @unknown default: "Unknown service status"
        }
    }

    /// Sample data covering each queue, for previews and screenshots. Paths are fictional.
    public static func preview() -> AppModel {
        let model = AppModel()
        let date = Date()
        let rootURL = URL(fileURLWithPath: "/Users/example/Library/CloudStorage/SynologyDrive-Example/Example Media", isDirectory: true)
        let root = WatchedRootSnapshot(id: UUID(), path: rootURL.path, displayName: "Example Media", enabled: true,
            extensions: ["mp4", "mov"], ignorePatterns: ["*_segment_*"], minimumStableAge: 300, automaticRequeueEnabled: false,
            baselineCompletedAt: date.addingTimeInterval(-86_400))
        let projects = WatchedRootSnapshot(id: UUID(), path: rootURL.deletingLastPathComponent().appendingPathComponent("Projects").path,
            displayName: "Projects", enabled: true, extensions: ["zip"], ignorePatterns: ["*_segment_*"], minimumStableAge: 600,
            automaticRequeueEnabled: false)
        model.watchedRoots = [root, projects]
        func sample(_ name: String, in folder: String = "", root: WatchedRootSnapshot = root, size: Int64, _ disposition: FindingDisposition,
                    state: String, checks: Int = 2, minutesAgo: Double = 2, reason: String? = nil, retry: Bool = false) -> FindingSnapshot {
            let parent = URL(fileURLWithPath: root.path).appendingPathComponent(folder, isDirectory: true)
            let path = parent.appendingPathComponent(name).path
            return FindingSnapshot(id: UUID(), canonicalPath: path, filename: name, rootIdentifier: root.id, inode: UInt64(name.count),
                fileProviderItemIdentifier: "preview-\(name.count)", fileSize: size, modificationDate: date.addingTimeInterval(-7200),
                firstDetectedAt: date.addingTimeInterval(-minutesAgo * 60 - 600), lastCheckedAt: date.addingTimeInterval(-minutesAgo * 60),
                lastConfirmedAt: checks >= 2 ? date.addingTimeInterval(-minutesAgo * 60) : nil,
                errorDomain: "NSFileProviderErrorDomain", errorCode: -2005, providerState: state,
                confirmationCount: checks, attemptCount: retry ? 1 : 0, disposition: disposition, eligibilityBlockReason: reason,
                sourceSHA256: retry ? "9f2c…preview" : nil,
                retryPath: retry ? parent.appendingPathComponent(name + ".__requeued-20261001-091500").path : nil,
                rawDiagnostic: "Preview fixture: isUploaded = 0; isDownloaded = 1; Error Domain=NSFileProviderErrorDomain Code=-2005")
        }
        model.findings = [
            sample("Episode 12 Final.mov", in: "Shows", size: 8_143_000_000, .actionable, state: "Permanent upload failure"),
            sample("Interview A-cam.mp4", in: "Interviews", size: 2_613_855_666, .existingNeedsReview, state: "Permanent upload failure",
                   reason: "Existing at first launch; review this source version."),
            sample("Client archive 2025.zip", root: projects, size: 1_204_000_000, .recoveryRequired, state: "Recovery review required",
                   reason: "The operation was interrupted. Review the retained files.", retry: true),
            sample("B-roll 04.mp4", in: "Shows", size: 940_000_000, .observing, state: "Awaiting confirmation", checks: 1, minutesAgo: 1),
            sample("Render v3.mp4", in: "Exports", size: 5_310_000_000, .requeueUploading, state: "Retry published; awaiting verification",
                   minutesAgo: 4, retry: true),
            sample("Trailer.mp4", in: "Exports", size: 612_000_000, .requeueSucceeded,
                   state: "Final filename reports uploaded; local content verified", minutesAgo: 95),
            sample("Rough cut.mp4", in: "Exports", size: 4_020_000_000, .sourceChanged, state: "Earlier version", minutesAgo: 300),
        ]
        model.append(.scan, "Recent-file scan completed.", details: "Seven-day window; 214 candidate paths inspected.")
        model.append(.requeueStarted, "Render v3.mp4: manual fix preparing a sibling retry copy.", findingID: model.findings[4].id)
        model.append(.findingConfirmed, "Episode 12 Final.mov: permanent upload failure confirmed.", findingID: model.findings[0].id)
        model.append(.findingDetected, "Existing upload failure needs review.", findingID: model.findings[1].id)
        model.status = .needsAttention
        model.lastScanDate = date.addingTimeInterval(-240)
        model.needsRootConfirmation = false
        model.isRestoring = false
        model.monitoringEnabled = true
        model.isPaused = false
        model.selectSettingsRoot(root.id)
        model.activitySelection = model.findings[0].id
        model.clientStatusText = "Preview: client available"
        model.providerStatusText = "Preview: permanent upload failure"
        return model
    }
}
