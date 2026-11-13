import AppKit
import DriveMonitorCore
import SwiftUI

/// Details for one file, shown in the Activity inspector beside the list instead of a modal sheet.
public struct FindingDetailView: View {
    @Bindable var model: AppModel
    let findingID: UUID
    @State private var recoveryChoice: RecoveryChoice?
    @State private var confirmRecovery = false
    @State private var closingStoppedRepair = false
    @State private var closingOperationID: UUID?
    @State private var showsTechnicalDetails = false
    public init(model: AppModel, findingID: UUID) { self.model = model; self.findingID = findingID }

    public var body: some View {
        if let finding = model.findings.first(where: { $0.id == findingID }) {
            Form {
                Section { header(finding) }
                Section("What Happened") {
                    Text(explanation(finding)).fixedSize(horizontal: false, vertical: true)
                    if let reason = finding.eligibilityBlockReason {
                        Text(model.diagnosticText(reason)).foregroundStyle(.secondary).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Section("What Happens Next") {
                    Text(nextStep(finding)).fixedSize(horizontal: false, vertical: true)
                    if offersFix(finding) {
                        Text("Synology’s upload acknowledgment does not independently verify the copy on your NAS.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if model.canUndo(finding) {
                        Button("Undo Replacement") { model.undo(id: findingID) }
                            .help("Restore the original and keep the replacement in Recovery")
                    }
                }
                if finding.hasRepairEvidence || [.requeueFailed, .recoveryRequired].contains(finding.disposition)
                    || model.hasRetainedStagedCopy(finding) {
                    recoveryInventory(finding)
                }
                Section("File") {
                    StackedValue(title: "Location", value: model.pathText(finding.canonicalPath))
                    LabeledContent("Size", value: finding.sizeText)
                    LabeledContent("Modified", value: date(finding.modificationDate))
                    LabeledContent("First detected", value: date(finding.firstDetectedAt))
                    LabeledContent("Last checked", value: date(finding.lastCheckedAt))
                    LabeledContent("Confirmed checks", value: "\(finding.confirmationCount) of 2")
                    if finding.uploadVerifiedAt != nil {
                        LabeledContent("Retry upload acknowledged", value: date(finding.uploadVerifiedAt))
                    }
                }
                let history = model.events(for: findingID)
                if !history.isEmpty {
                    Section("History") {
                        ForEach(history.prefix(20)) { event in
                            EventRow(model: model, event: event)
                        }
                    }
                }
                Section {
                    DisclosureGroup("Technical Details", isExpanded: $showsTechnicalDetails) {
                        LabeledContent("Provider item", value: model.showRawPaths ? finding.fileProviderItemIdentifier ?? "Unavailable" : "Hidden")
                        LabeledContent("Error", value: "\(finding.errorDomain ?? "None") \(finding.errorCode.map(String.init) ?? "")")
                        LabeledContent("Last confirmed", value: date(finding.lastConfirmedAt))
                        LabeledContent("Attempts", value: String(finding.attemptCount))
                        StackedValue(title: "Source SHA-256", value: finding.sourceSHA256 ?? "Not calculated", monospaced: true)
                        StackedValue(title: "Retry SHA-256", value: finding.retrySHA256 ?? "Not calculated", monospaced: true)
                        Text(model.rawDiagnostic(for: finding))
                            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .formStyle(.grouped)
            .confirmationDialog("Close the earlier stopped attempt?", isPresented: Binding(
                get: { closingOperationID != nil }, set: { if !$0 { closingOperationID = nil } })) {
                Button("Retain Staged Copy and Close") { if let id = closingOperationID { model.closeStoppedRepair(id) } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The staged copy moves to Retained Files, where you can export or remove it. This file and any later repair, including its Undo, are not changed.")
            }
            .confirmationDialog(closingStoppedRepair ? "Close this stopped repair?" : "Resolve this interrupted repair?", isPresented: $confirmRecovery) {
                Button(closingStoppedRepair ? "Close Stopped Repair"
                       : recoveryChoice == .restoreArchivedOriginal ? "Restore Archived Original" : "Keep Current Original") {
                    if let recoveryChoice { model.resolveRecovery(id: findingID, choice: recoveryChoice) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(closingStoppedRepair
                    ? "Any staged copy moves to Retained Files, where you can export or remove it. This file’s current status does not change."
                    : recoveryChoice == .restoreArchivedOriginal
                    ? "The verified archive moves to the empty original path. Other retained copies move into Recovery."
                    : "The current original stays in place. Retry and staged copies move into Recovery. Monitoring then checks the kept file again.")
            }
        } else {
            ContentUnavailableView("File Unavailable", systemImage: "doc.badge.ellipsis",
                description: Text("This file is no longer in the local history."))
        }
    }

    private func header(_ finding: FindingSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(nsImage: finding.typeIcon).resizable().frame(width: 40, height: 40).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(finding.filename).font(.headline).textSelection(.enabled).lineLimit(3)
                    Text(model.fileLocation(finding.canonicalPath)).font(.caption).foregroundStyle(.secondary)
                    StatusLabel(text: finding.statusText, symbol: finding.statusSymbol, tint: finding.statusTint)
                        .font(.callout).padding(.top, 2)
                }
            }
            // A narrow inspector keeps every button whole by dropping Reveal's title before truncating anything.
            ViewThatFits(in: .horizontal) {
                actionRow(finding, revealStyle: .titleAndIcon)
                actionRow(finding, revealStyle: .iconOnly)
            }
        }
        .padding(.vertical, 4)
    }

    private func actionRow(_ finding: FindingSnapshot, revealStyle: some LabelStyle) -> some View {
        HStack(spacing: 8) {
            if model.canRequeue(finding) || offersFix(finding) || finding.disposition == .requeuePreparing {
                Button(model.fileActionTitle(finding)) { model.requeue(id: findingID) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canRequeue(finding))
                    .help(model.repairBlockReason(finding) ?? "Applies only to this version of the file")
                    .fixedSize()
            }
            Button { Finder.reveal(finding) } label: { Label("Reveal in Finder", systemImage: "folder") }
                .labelStyle(revealStyle).fixedSize()
                .help("Reveal in Finder")
            Menu {
                FindingActions(model: model, finding: finding)
            } label: {
                Label("More Actions", systemImage: "ellipsis.circle")
            }
            .menuIndicator(.hidden).labelStyle(.iconOnly).fixedSize()
            .help("More actions")
        }
        .controlSize(.regular)
    }

    /// A plain description of the state. The engine's specific reason, if any, follows it.
    private func explanation(_ finding: FindingSnapshot) -> String {
        switch finding.disposition {
        case .observing where finding.errorCode != nil && finding.errorCode != -2005:
            "Synology reports a different upload error for this file, often temporary (offline, storage full, or sign-in). Fix is not offered for it; the file is checked again later."
        case .observing where finding.errorCode != nil:
            "Synology reported an upload failure. A second matching check at least 60 seconds later confirms it; you can choose Fix once 60 seconds have passed."
        case .observing: "The file is being checked. Files that are still changing are checked again after the stability wait."
        case .actionable: "Synology Drive stopped uploading this file with a permanent error. The file is on this Mac."
        case .existingNeedsReview: "This file already had a permanent upload failure when its folder was added. It is never fixed automatically."
        case .requeuePreparing: "A copy of the file is being staged and verified outside Synology Drive."
        case .requeueUploading: "A verified retry copy was published next to the original, and its upload is being checked. The original is still kept."
        case .requeueSucceeded where finding.finalNameFailed:
            "The verified copy took the original’s name, but Synology reports it failed to upload under that name. No further copy was made, and the original is kept so you can undo."
        case .requeueSucceeded: "The verified copy took the original’s name. The original is kept so you can undo."
        case .requeueFailed: "The repair stopped before it finished. The original was not deleted."
        case .recoveryRequired: "A repair was interrupted or a file changed during it. Review the copies below and choose what to keep."
        case .compatibilityBlocked: "Synology’s report for this file could not be read safely, so repair is blocked."
        case .resolved: "This file no longer needs a decision. Its last known state is shown above."
        case .ignored: "You chose to ignore this version of the file."
        case .sourceChanged where finding.providerState == MonitoringEngine.movedOrDeletedState:
            "The file is no longer at this path. This observation is kept as history."
        case .sourceChanged: "The file changed after this observation. Its newer version is tracked separately."
        }
    }

    /// States where Fix is shown, enabled or with the reason it is not available yet.
    private func offersFix(_ finding: FindingSnapshot) -> Bool {
        [.observing, .actionable, .existingNeedsReview, .compatibilityBlocked].contains(finding.disposition)
    }

    private func nextStep(_ finding: FindingSnapshot) -> String {
        switch finding.disposition {
        case .observing, .actionable, .existingNeedsReview, .compatibilityBlocked:
            model.repairBlockReason(finding)
                ?? "Fix publishes one verified copy next to the original for Synology to upload. The original is archived only after Synology reports that copy uploaded."
        case .requeuePreparing: "When the copy is verified, it is published next to the original and its upload is checked."
        case .requeueUploading: "The upload is checked again automatically. Choose Check Upload to check now."
        case .requeueSucceeded where finding.finalNameFailed:
            "Choose Check Final Name to check again, or Undo to put the original back. Undo stays available until the final filename reports uploaded."
        case .requeueSucceeded:
            // From the operation itself, not from whether a button is enabled (another repair can disable it).
            model.repairOperations.first(where: { $0.finding?.id == finding.id && $0.phase == .succeeded })?.finalPathVerifiedAt == nil
                ? "Choose Check Final Name to confirm the final filename uploaded. The 6-hour Undo window starts after that."
                : "The 6-hour Undo window started when the final filename reported uploaded."
        case .requeueFailed: "Review the copies below. Check Again reads Synology’s status for the original again."
        case .recoveryRequired: "Choose which copy to keep below. Other copies move into Recovery; nothing is deleted."
        case .ignored: "Nothing. Ignored versions keep this status, even after Clear History."
        case .resolved, .sourceChanged: "Nothing. This row stays in history until you clear it."
        }
    }

    private func recoveryInventory(_ finding: FindingSnapshot) -> some View {
        let originalExists = (try? FileIntegrity.identity(URL(fileURLWithPath: finding.canonicalPath)).exists) == true
        // A folder or link at the original path is not a file to keep, and it blocks Restore.
        let originalOccupied = (try? FileManager.default.attributesOfItem(atPath: finding.canonicalPath)) != nil
        // The same order RepairRecovery.resolve uses (an interrupted operation, else the newest), so the copies shown
        // are the ones a choice acts on. An older stopped attempt is closed from its row in Retained Files.
        let operations = model.repairOperations.filter { $0.finding?.id == findingID }
        let operation = operations.first { $0.phase == .recoveryRequired } ?? operations.first
        // A stopped repair whose row moved on, or whose original is gone, has nothing to keep or restore.
        let closesStoppedRepair = operation?.phase == .failed && (finding.disposition != .requeueFailed || !originalExists)
        let archive = model.recoveryFiles.first { $0.record.id == operation?.archiveID }
        let restoreAvailable = !originalOccupied && archive?.exists == true
            && archive?.record.archivedSHA256 != nil && archive?.record.archivedSHA256 == operation?.sourceSHA256
        return Section {
            copyLocation("Current original", finding.canonicalPath)
            if let path = operation?.publishedPath, path != finding.canonicalPath { copyLocation("Published retry", path) }
            if let path = operation?.stagedPath { copyLocation("Staged copy", path) }
            // The copy "Retain Staged Copy and Close…" acts on, when it belongs to an earlier stopped attempt.
            if let stopped = operations.first(where: AppModel.retainsStagedCopy), stopped.id != operation?.id,
               let path = stopped.stagedPath {
                copyLocation("Staged copy from an earlier attempt", path)
            }
            if let archive {
                copyLocation("Archived original", archive.url.path)
                Text(archive.record.purgeAllowed == true ? "Undo expires \(archive.record.expiresAt.formatted(date: .abbreviated, time: .shortened))." : "Retained without automatic expiry.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Recorded digest: \(archive.record.archivedSHA256 ?? "Unavailable"). Restore rechecks the bytes before moving them.")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            // Keep/Restore act on this row's own operation, so they appear only while that operation needs a decision.
            // A leftover staged copy from an older stop on a row that later succeeded is closed on its own.
            if !closesStoppedRepair && ![.recoveryRequired, .requeueFailed, .requeueUploading].contains(finding.disposition),
               let stopped = operations.first(where: AppModel.retainsStagedCopy) {
                Button("Retain Staged Copy and Close…") { closingOperationID = stopped.id }
                    .disabled(!model.requeueInFlight.isEmpty)
                Text("An earlier attempt stopped before publishing and kept a staged copy. Closing it moves that copy to Retained Files; this file and its later repair are not changed.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if [.recoveryRequired, .requeueFailed, .requeueUploading].contains(finding.disposition) || closesStoppedRepair {
                if closesStoppedRepair {
                    Button("Close Stopped Repair…") {
                        recoveryChoice = .keepCurrentOriginal; closingStoppedRepair = true; confirmRecovery = true
                    }
                    .disabled(!model.requeueInFlight.isEmpty)
                    Text("This repair stopped before publishing. Closing it moves any staged copy to Retained Files; this file is not changed.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    HStack {
                        Button("Keep Current Original…") { recoveryChoice = .keepCurrentOriginal; closingStoppedRepair = false; confirmRecovery = true }
                            .disabled(!originalExists || !model.requeueInFlight.isEmpty)
                        Button("Restore Archived Original…") { recoveryChoice = .restoreArchivedOriginal; closingStoppedRepair = false; confirmRecovery = true }
                            .disabled(!restoreAvailable || !model.requeueInFlight.isEmpty)
                    }
                    Text(originalOccupied && !originalExists
                         ? "A folder or link occupies the original path. Move it away before restoring; nothing is overwritten."
                         : originalExists ? "Restore needs an empty original path; no choice overwrites an existing file."
                         : "The original path is empty. Restore needs a matching, available archive.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Copies")
        }
    }

    private func copyLocation(_ title: String, _ path: String) -> some View {
        let identity = try? FileIntegrity.identity(URL(fileURLWithPath: path))
        return HStack(alignment: .firstTextBaseline) {
            StackedValue(title: title, value: model.pathText(path) + "\n"
                + (identity?.exists == true ? "Present · \(ByteCountFormatter.string(fromByteCount: identity?.fileSize ?? 0, countStyle: .file))" : "Missing or unavailable"))
            Button("Reveal") { Finder.reveal(path) }.controlSize(.small)
                .accessibilityLabel("Reveal \(title.lowercased()) in Finder")
        }
    }

    private func date(_ value: Date?) -> String { value?.formatted(date: .abbreviated, time: .shortened) ?? "Not verified" }
}
