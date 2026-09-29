import AppKit
import DriveMonitorCore
import SwiftUI

public struct FindingDetailView: View {
    @Bindable var model: AppModel
    let findingID: UUID
    @Environment(\.dismiss) private var dismiss

    public init(model: AppModel, findingID: UUID) { self.model = model; self.findingID = findingID }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let finding = model.findings.first(where: { $0.id == findingID }) {
                Text(finding.filename).font(.title2.bold()).textSelection(.enabled)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        field("Full path", model.pathText(finding.canonicalPath))
                        field("Size", "\(ByteCountFormatter.string(fromByteCount: finding.fileSize, countStyle: .binary)) (\(finding.fileSize) bytes)")
                        field("Modification date", date(finding.modificationDate))
                        field("First detected", date(finding.firstDetectedAt))
                        field("Last checked", date(finding.lastCheckedAt))
                        field("Last confirmed", date(finding.lastConfirmedAt))
                        field("Provider item identifier", finding.fileProviderItemIdentifier ?? "Unavailable")
                        field("Provider state", finding.providerState)
                        field("Error domain", finding.errorDomain ?? "None")
                        field("Error code", finding.errorCode.map(String.init) ?? "None")
                        field("Confirmation count", String(finding.confirmationCount))
                        field("Local disposition", finding.disposition.rawValue)
                        Divider()
                        field("Retry eligibility", model.canRequeue(finding) ? "Ready. After the copy uploads, the failed original is removed and the copy takes its name." : "Not available for this source version")
                        field("Block reason", finding.eligibilityBlockReason ?? "None")
                        field("Attempt count", String(finding.attemptCount))
                        field("Retry filename", finding.retryPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "None")
                        field("Retry status", retryStatus(finding))
                        field("Retry provider item", finding.retryItemIdentifier ?? "None")
                        field("Source SHA-256", finding.sourceSHA256 ?? "Not calculated")
                        field("Retry SHA-256", finding.retrySHA256 ?? "Not calculated")
                        DisclosureGroup("Raw diagnostic") {
                            Text(model.rawDiagnostic(for: finding))
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                HStack {
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: finding.canonicalPath)]) }
                    Button("Copy Diagnostic Summary") {
                        let summary = model.copyDiagnostic(id: findingID)
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(summary, forType: .string)
                    }
                    Button("Recheck Now") { model.recheck(id: findingID) }
                    Button(model.fileActionTitle(finding)) { model.requeue(id: findingID) }
                        .disabled(!model.canRequeue(finding))
                        .help("This action applies only to \(finding.filename).")
                }
                HStack {
                    Button("Ignore This Source Version") { model.ignore(id: findingID) }
                    Button("Mark Resolved") { model.markResolved(id: findingID) }
                    Spacer()
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
                Text("Ignore and Mark Resolved change the local finding only. The original file is preserved.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("This finding is unavailable.")
                Button("Done") { dismiss() }
            }
        }
        .padding(24)
        .frame(minWidth: 690, idealWidth: 730, minHeight: 560, idealHeight: 720)
    }

    private func field(_ title: String, _ value: String) -> some View {
        LabeledContent(title) { Text(value).multilineTextAlignment(.trailing).textSelection(.enabled) }
    }

    private func date(_ date: Date?) -> String { date?.formatted(date: .abbreviated, time: .standard) ?? "Not confirmed" }
    private func retryStatus(_ finding: FindingSnapshot) -> String {
        if let verified = finding.uploadVerifiedAt, finding.retryPath != nil { return "Synology reports uploaded · \(date(verified))" }
        return finding.retryPath == nil ? "No retry created" : finding.disposition.rawValue
    }
}
