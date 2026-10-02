import Foundation

/// Owns dispatch policy independently of SwiftUI. Durable journals/finding evidence
/// enforce committed attempts across launches; transient preflight deferrals may retry.
@MainActor
public final class AutomaticRepairCoordinator {
    private var attempted: Set<SourceVersionKey> = []
    private var deferredUntil: [SourceVersionKey: Date] = [:]
    private var active: SourceVersionKey?
    private let now: () -> Date
    public init(now: @escaping () -> Date = Date.init) { self.now = now }

    public func reserve(findings: [FindingSnapshot], roots: [WatchedRootSnapshot], permittedRootIDs: Set<UUID>,
                        eligible: (FindingSnapshot) -> Bool) -> FindingSnapshot? {
        guard active == nil else { return nil }
        let date = now()
        guard let finding = findings.first(where: { finding in
            let source = version(finding)
            return permittedRootIDs.contains(finding.rootIdentifier)
                && finding.disposition == .actionable && finding.confirmationCount >= 2
                && finding.attemptCount == 0 && !finding.hasRepairEvidence
                && !attempted.contains(source) && (deferredUntil[source] ?? .distantPast) <= date
                && roots.contains { $0.id == finding.rootIdentifier && $0.enabled && $0.automaticRequeueEnabled
                    && !Self.predatesReview(finding, root: $0)
                    // The executor refuses young files; selecting one would only log a refusal every minute.
                    && date.timeIntervalSince(finding.modificationDate) >= $0.minimumStableAge }
                && eligible(finding)
        }) else { return nil }
        active = version(finding)
        attempted.insert(version(finding))
        return finding
    }

    public func finish(result: FindingSnapshot?) {
        guard let source = active else { return }
        active = nil
        if let result, result.attemptCount == 0, !result.hasRepairEvidence,
           ![.requeueFailed, .recoveryRequired].contains(result.disposition) {
            attempted.remove(source)
            deferredUntil[source] = now().addingTimeInterval(60)
        }
    }
    private func version(_ finding: FindingSnapshot) -> SourceVersionKey {
        SourceVersionKey(canonicalPath: finding.canonicalPath, inode: finding.inode ?? 0,
                         fileSize: finding.fileSize, modificationTime: finding.modificationDate)
    }

    /// Finding rows can be recreated (Clear History, a rename, a recovery choice) and then look newly
    /// detected. The file's own modification time still shows it existed before the setup review, so
    /// it stays a manual decision.
    public nonisolated static func predatesReview(_ finding: FindingSnapshot, root: WatchedRootSnapshot) -> Bool {
        guard let baseline = root.baselineCompletedAt else { return true }
        return finding.firstDetectedAt < baseline || finding.modificationDate < baseline
    }

    /// Any earlier operation on this exact content version used its one automatic attempt, whatever the
    /// outcome and whatever the file is called now. Path is ignored so a rename cannot reset it.
    public nonisolated static func hasOperation(for finding: FindingSnapshot, in records: [RequeueJournal]) -> Bool {
        guard let inode = finding.inode else { return true }
        return records.contains {
            $0.source.inode == inode && $0.source.fileSize == finding.fileSize
                && abs($0.source.modificationTime.timeIntervalSince(finding.modificationDate)) < 1
        }
    }
}
