import AppKit
import DriveMonitorCore
import Foundation
import Observation
import ServiceManagement

/// All engine integration is optional until the production interpreter is supplied.
@MainActor
public struct MonitorCallbacks {
    public var start: (([WatchedRootSnapshot]) async throws -> Void)?
    public var scan: (() async throws -> [FindingSnapshot])?
    public var loadRoots: (() async throws -> [WatchedRootSnapshot])?
    public var loadEvents: (() async throws -> [ActivityEvent])?
    public var resetQueueStore: (() async throws -> Void)?
    public var pause: ((Bool) async throws -> Void)?
    public var recheck: ((UUID) async throws -> FindingSnapshot?)?
    public var requeue: ((UUID) async throws -> FindingSnapshot?)?
    public var saveFinding: ((FindingSnapshot) async throws -> Void)?
    public var saveRoot: ((WatchedRootSnapshot) async throws -> Void)?
    public var acknowledgeBaseline: ((UUID, Date) async throws -> Void)?
    public var exportDiagnostic: ((String) throws -> Void)?
    public init() {}
}

@MainActor
@Observable
public final class AppModel {
    public var status: MonitorStatus = .paused
    public var clientStatusText = "Client status unavailable"
    public var providerStatusText = "Provider evaluation is not connected"
    public var historicalProviderCountText = "Historical provider count unavailable"
    public var activeUploadCount = 0
    public var diskFreeSpaceText = "Disk free space unavailable"
    public var lastScanText = "Not scanned yet"
    public var findings: [FindingSnapshot] = []
    public var recentActivity: [ActivityEvent] = []
    public private(set) var isPaused = true
    public private(set) var isScanning = false
    public private(set) var monitoringEnabled = false
    public private(set) var automaticRequeueEnabled = false
    public var desktopNotificationsEnabled = UserDefaults.standard.object(forKey: "desktopNotificationsEnabled") as? Bool ?? true
    public var watchedRoots: [WatchedRootSnapshot] = []
    public var enabledFormatPresets: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "formatPresets") ?? ["video"])
    public var customExtensionsText: String = UserDefaults.standard.string(forKey: "customExtensions") ?? ""
    public var ignorePatternsText = "*_segment_*,*__requeued-*,* conflicted copy*,*(conflict*"
    public var minimumStableAge: Double = 300
    public var reconciliationInterval: Double = 300
    public var lowDiskWarningThresholdGiB: Double = 100
    public var showRawPaths = true
    public var needsRootConfirmation = true
    public private(set) var launchAtLogin = false
    public private(set) var launchAtLoginNeedsApproval = false
    public private(set) var launchAtLoginStatusText = "Not registered"
    public private(set) var changingLaunchAtLogin = false
    public var lastErrorText: String?
    public private(set) var availableDiskBytes: Int64?
    public private(set) var acknowledgingBaseline = false
    public private(set) var isRestoring = true

    @ObservationIgnored private let pickFolder: () -> URL?
    @ObservationIgnored private let callbacks: MonitorCallbacks

    public init(pickFolder: @escaping () -> URL? = { nil }, callbacks: MonitorCallbacks = MonitorCallbacks()) {
        self.pickFolder = pickFolder
        self.callbacks = callbacks
        refreshLaunchAtLoginStatus()
    }

    public var attentionFindings: [FindingSnapshot] {
        findings.filter { [.actionable, .existingNeedsReview, .requeueFailed, .compatibilityBlocked].contains($0.disposition) }
    }
    public var watchingFindings: [FindingSnapshot] {
        findings.filter { $0.disposition == .observing }
    }
    public var discoveredFindings: [FindingSnapshot] {
        findings.filter { $0.disposition != .resolved && $0.disposition != .ignored }.sorted { lhs, rhs in
            let rank = outcomeRank(lhs) - outcomeRank(rhs)
            if rank != 0 { return rank < 0 }
            return lhs.filename.localizedStandardCompare(rhs.filename) == .orderedAscending
        }
    }
    public var badgeCount: Int { attentionFindings.count + watchingFindings.count }

    public func fileLocation(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let folder = url.deletingLastPathComponent().lastPathComponent
        if folder.isEmpty { return url.lastPathComponent }
        return "\(folder)/\(url.lastPathComponent)"
    }

    public func fileActionTitle(_ finding: FindingSnapshot) -> String {
        if requeueInFlight.contains(finding.id) || finding.disposition == .requeuePreparing {
            return "Fixing…"
        }
        if finding.disposition == .requeueUploading, finding.retryPath != nil {
            return "Check upload"
        }
        if canRequeue(finding) { return "Fix" }
        return outcomeLabel(finding)
    }

    public func outcomeLabel(_ finding: FindingSnapshot) -> String {
        switch finding.disposition {
        case .requeueSucceeded: "Fixed"
        case .requeueFailed: "Failed"
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
        findings = []
        recentActivity = []
        requeueInFlight = []
        lastErrorText = nil
        refreshStatus()
        Task {
            do {
                try await callbacks.resetQueueStore?()
                append(.settings, "Local queue reset. Synology files were not deleted.")
            } catch {
                lastErrorText = error.localizedDescription
                append(.compatibility, "The local queue could not be reset.", details: lastErrorText)
            }
            refreshStatus()
        }
    }

    private func outcomeRank(_ finding: FindingSnapshot) -> Int {
        switch finding.disposition {
        case .requeueFailed, .compatibilityBlocked: 0
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
        defer { isRestoring = false }
        guard let loadRoots = callbacks.loadRoots else {
            needsRootConfirmation = watchedRoots.isEmpty
            return
        }
        do {
            let roots = try await loadRoots()
            guard !roots.isEmpty else {
                needsRootConfirmation = true
                return
            }
            watchedRoots = roots
            needsRootConfirmation = false
            monitoringEnabled = true
            isPaused = false
            try await callbacks.start?(roots)
            if let findings = try await callbacks.scan?() {
                assignFindings(findings)
            }
            if let events = try await callbacks.loadEvents?() {
                recentActivity = Array(events.prefix(100))
            }
            lastScanText = Date().formatted(date: .omitted, time: .shortened)
            refreshDiskFreeSpace()
            refreshStatus()
        } catch {
            lastErrorText = error.localizedDescription
            needsRootConfirmation = watchedRoots.isEmpty
        }
    }

    public func applyStoreUpdate(findings: [FindingSnapshot], events: [ActivityEvent]) {
        assignFindings(findings)
        recentActivity = Array(events.prefix(100))
        refreshStatus()
    }

    public func setNotificationsEnabled(_ enabled: Bool) {
        desktopNotificationsEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "desktopNotificationsEnabled")
        if enabled { FindingNotifier.prepare() }
    }

    public func chooseFolder() {
        guard let folder = pickFolder() else { return }
        confirmRoot(folder)
    }

    public func confirmRoot(_ url: URL) {
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        guard url.isFileURL else { lastErrorText = "Choose a local folder."; return }
        guard !FileManager.default.fileExists(atPath: canonical.appendingPathComponent(".git").path) else {
            lastErrorText = "A repository cannot be used as a watched folder."
            return
        }
        do {
            guard try canonical.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                lastErrorText = "The selected folder is unavailable."
                return
            }
        } catch { lastErrorText = "The selected folder cannot be read: \(error.localizedDescription)"; return }
        let root = WatchedRootSnapshot(id: UUID(), path: canonical.path, displayName: canonical.lastPathComponent,
            enabled: true, extensions: extensions, ignorePatterns: ignorePatterns, minimumStableAge: minimumStableAge,
            automaticRequeueEnabled: false)
        watchedRoots = [root]
        needsRootConfirmation = false
        monitoringEnabled = true
        isPaused = false
        lastErrorText = nil
        refreshDiskFreeSpace()
        Task {
            do {
                try await callbacks.saveRoot?(root)
                if let start = callbacks.start {
                    try await start(watchedRoots)
                    refreshStatus()
                } else {
                    status = .compatibilityError
                    append(.compatibility, "Watched folder confirmed. Monitoring awaits provider integration.")
                }
            } catch {
                monitoringEnabled = false
                isPaused = true
                status = .compatibilityError
                lastErrorText = error.localizedDescription
            }
        }
    }

    public func scanNow() {
        guard !needsRootConfirmation, !isScanning else { return }
        isScanning = true
        status = .scanning
        refreshDiskFreeSpace()
        Task {
            defer { isScanning = false; refreshStatus() }
            do {
                if let scan = callbacks.scan {
                    assignFindings(try await scan())
                    lastScanText = Date().formatted(date: .abbreviated, time: .shortened)
                    append(.scan, "Recent-file scan completed.")
                } else {
                    lastScanText = "Requested; provider integration unavailable"
                    append(.compatibility, "Scan blocked: the monitoring engine is not connected.")
                }
            } catch { lastErrorText = error.localizedDescription; append(.compatibility, "Scan blocked.", details: lastErrorText) }
        }
    }

    public func togglePause() {
        guard !needsRootConfirmation else { return }
        setMonitoringEnabled(isPaused)
    }

    public func setMonitoringEnabled(_ enabled: Bool) {
        guard !needsRootConfirmation else { return }
        let previous = monitoringEnabled
        monitoringEnabled = enabled
        isPaused = !enabled
        refreshStatus()
        append(.settings, enabled ? "Monitoring resumed." : "Monitoring paused.")
        Task {
            do { try await callbacks.pause?(!enabled) }
            catch {
                monitoringEnabled = previous
                isPaused = !previous
                lastErrorText = error.localizedDescription
                refreshStatus()
            }
        }
    }

    public func recheck(id: UUID) {
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
        guard !requeueInFlight.contains(finding.id) else { return false }
        switch finding.disposition {
        case .requeueUploading:
            return finding.retryPath != nil
        case .actionable, .existingNeedsReview, .requeueFailed:
            return true
        case .observing where finding.errorCode == -2005:
            let anchor = finding.lastConfirmedAt ?? finding.firstDetectedAt
            return Date().timeIntervalSince(anchor) >= 60
        default:
            return false
        }
    }

    public func canUndo(_ finding: FindingSnapshot) -> Bool {
        guard let root = try? UndoArchive.supportRoot() else { return false }
        return UndoArchive.restorableRecord(findingID: finding.id, root: root) != nil
    }

    public func undo(id: UUID) {
        guard let finding = findings.first(where: { $0.id == id }), canUndo(finding) else { return }
        Task {
            do {
                guard let root = try? UndoArchive.supportRoot(),
                      let record = UndoArchive.restorableRecord(findingID: id, root: root) else { return }
                _ = try UndoArchive.restore(record, root: root)
                if let index = findings.firstIndex(where: { $0.id == id }) {
                    findings[index].disposition = .existingNeedsReview
                    findings[index].providerState = "Original restored from the undo cache"
                    findings[index].eligibilityBlockReason = "The previous file is back at its original name. The uploaded copy was kept in the undo cache until it expires."
                    let updated = findings[index]
                    try await callbacks.saveFinding?(updated)
                }
                append(.recovery, "\(finding.filename): original restored from the undo cache.")
            } catch {
                lastErrorText = error.localizedDescription
            }
            refreshStatus()
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
        guard let index = findings.firstIndex(where: { $0.id == id }), canRequeue(findings[index]) else { return }
        let previous = findings[index]
        findings[index].disposition = .requeuePreparing
        findings[index].providerState = "Creating a complete retry copy. The original is removed only after Synology reports the copy uploaded."
        findings[index].eligibilityBlockReason = nil
        status = .requeueing
        requeueInFlight.insert(id)
        append(.requeueStarted, "\(previous.filename): preparing a sibling retry copy.", findingID: id)
        Task {
            defer { requeueInFlight.remove(id); refreshStatus() }
            do {
                guard let requeue = callbacks.requeue else {
                    findings[indexOrCurrent(id, fallback: index)] = previous
                    append(.requeueBlocked, "Requeue is not connected.", findingID: id)
                    return
                }
                if let updated = try await requeue(id) {
                    replaceFinding(updated)
                }
            } catch {
                if let current = findings.firstIndex(where: { $0.id == id }), findings[current].disposition == .requeuePreparing {
                    findings[current] = previous
                }
                lastErrorText = error.localizedDescription
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
        assignFindings(updated)
    }

    private func assignFindings(_ updated: [FindingSnapshot]) {
        announce(from: findings, to: updated)
        findings = updated
    }

    private func announce(from previous: [FindingSnapshot], to updated: [FindingSnapshot]) {
        guard desktopNotificationsEnabled else { return }
        for finding in updated {
            let before = previous.first { $0.id == finding.id }?.disposition
            guard before != finding.disposition else { continue }
            switch finding.disposition {
            case .actionable, .existingNeedsReview:
                guard before != .actionable, before != .existingNeedsReview else { continue }
                FindingNotifier.notify(title: finding.filename, body: "Permanent upload failure. Open Synology Drive Unstuckerator and choose Fix This File.")
            case .requeueSucceeded:
                FindingNotifier.notify(title: finding.filename, body: "Fixed. Synology reported the replacement uploaded.")
            case .requeueFailed:
                FindingNotifier.notify(title: finding.filename, body: finding.eligibilityBlockReason ?? "The retry failed.")
            default:
                break
            }
        }
    }

    private func indexOrCurrent(_ id: UUID, fallback: Int) -> Int {
        findings.firstIndex(where: { $0.id == id }) ?? fallback
    }

    public func canDismiss(_ finding: FindingSnapshot) -> Bool {
        switch finding.disposition {
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
        guard let index = findings.firstIndex(where: { $0.id == id }) else { return }
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

    public func acknowledgeBaseline() {
        guard !acknowledgingBaseline else { return }
        let pending = watchedRoots.filter { $0.enabled && $0.baselineCompletedAt == nil }
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
        guard minimumStableAge.isFinite, minimumStableAge >= 0,
              lowDiskWarningThresholdGiB.isFinite, lowDiskWarningThresholdGiB >= 0, !extensions.isEmpty else {
            lastErrorText = "Enter a valid minimum stable age, a warning threshold, and at least one extension."
            return
        }
        for index in watchedRoots.indices {
            watchedRoots[index].extensions = extensions
            watchedRoots[index].ignorePatterns = ignorePatterns
            watchedRoots[index].minimumStableAge = minimumStableAge
            watchedRoots[index].automaticRequeueEnabled = false
        }
        let roots = watchedRoots
        Task {
            do {
                for root in roots { try await callbacks.saveRoot?(root) }
                try await callbacks.start?(roots)
                append(.settings, "Monitoring settings updated.")
            } catch { lastErrorText = error.localizedDescription }
        }
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
        Provider item: \(finding.fileProviderItemIdentifier ?? "Unavailable")
        Provider state: \(finding.providerState)
        Error: \(finding.errorDomain ?? "None") / \(finding.errorCode.map(String.init) ?? "None")
        Confirmations: \(finding.confirmationCount)
        Disposition: \(finding.disposition.rawValue)
        Retry eligibility: \(canRequeue(finding) ? "Fix can publish one verified copy" : "Fix is not available for this row")
        Block reason: \(finding.eligibilityBlockReason ?? "None")
        Attempts: \(finding.attemptCount)
        Retry: \(finding.retryPath.map(pathText) ?? "None")
        Retry item: \(finding.retryItemIdentifier ?? "None")
        Upload verified: \(finding.uploadVerifiedAt?.ISO8601Format() ?? "Not verified")
        Source SHA-256: \(finding.sourceSHA256 ?? "Not calculated")
        Retry SHA-256: \(finding.retrySHA256 ?? "Not calculated")
        Diagnostic: \(rawDiagnostic(for: finding))
        """
    }

    public func exportDiagnostic() {
        let diagnostic = (["Synology Drive Unstuckerator", historicalProviderCountText, "Active uploads: \(activeUploadCount)"]
            + findings.map { copyDiagnostic(id: $0.id) }).joined(separator: "\n\n")
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
        if findings.contains(where: { $0.disposition == .requeuePreparing || $0.disposition == .requeueUploading }) {
            status = .requeueing
        } else if isPaused { status = .paused }
        else if findings.contains(where: { $0.disposition == .compatibilityBlocked }) || callbacks.scan == nil { status = .compatibilityError }
        else { status = (attentionFindings.isEmpty && watchingFindings.isEmpty) ? .healthy : .needsAttention }
    }

    private func append(_ kind: ActivityKind, _ summary: String, findingID: UUID? = nil, details: String? = nil, result: String? = nil) {
        recentActivity.insert(ActivityEvent(id: UUID(), timestamp: Date(), kind: kind, findingID: findingID,
            summary: summary, details: details, result: result), at: 0)
        if recentActivity.count > 100 { recentActivity = Array(recentActivity.prefix(100)) }
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

    public static func preview() -> AppModel {
        let model = AppModel()
        let date = Date()
        let rootURL = URL(fileURLWithPath: "/Users/example/Library/CloudStorage/SynologyDrive-Example/Example Media", isDirectory: true)
        let root = WatchedRootSnapshot(id: UUID(), path: rootURL.path, displayName: "Example Media", enabled: true,
            extensions: ["mp4"], ignorePatterns: ["*_segment_*"], minimumStableAge: 300, automaticRequeueEnabled: false)
        model.watchedRoots = [root]
        model.findings = [FindingSnapshot(id: UUID(), canonicalPath: rootURL.appendingPathComponent("example.mp4").path,
            filename: "example.mp4", rootIdentifier: root.id, inode: 123,
            fileProviderItemIdentifier: "preview-item", fileSize: 2_613_855_666, modificationDate: date.addingTimeInterval(-3600),
            firstDetectedAt: date.addingTimeInterval(-120), lastCheckedAt: date, lastConfirmedAt: date,
            errorDomain: "NSFileProviderErrorDomain", errorCode: -2005, providerState: "Permanent upload failure",
            confirmationCount: 2, attemptCount: 0, disposition: .existingNeedsReview,
            eligibilityBlockReason: "Existing at first launch; review this source version.",
            rawDiagnostic: "Preview fixture: isUploaded = 0; isDownloaded = 1; Error Domain=NSFileProviderErrorDomain Code=-2005")]
        model.append(.findingDetected, "Existing upload failure needs review.", findingID: model.findings[0].id)
        model.status = .needsAttention
        model.needsRootConfirmation = false
        model.monitoringEnabled = true
        model.isPaused = false
        model.clientStatusText = "Preview: client available"
        model.providerStatusText = "Preview: permanent upload failure"
        return model
    }
}
