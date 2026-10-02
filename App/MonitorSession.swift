import AppKit
import DriveMonitorCore
import Foundation

@MainActor
public final class MonitorSession {
    private let repository: FindingRepository
    private let engine: MonitoringEngine
    private let progress = RepairProgress()
    private let environment: ManualRequeueAction.Environment
    private let verificationTask: Task<Void, Never>
    private let purgeTask: Task<Void, Never>
    private var wakeTask: Task<Void, Never>?

    public init() throws {
        let repository = try FindingRepository(inMemory: false)
        self.repository = repository
        let support = try AppStorage.folderURL()
        let operations = try RepairOperationStore(root: support.appendingPathComponent("Journals"))
        let access = RepairAccess(lockRoot: operations.root.appendingPathComponent("Locks"))
        let undoRoot = try UndoArchive.supportRoot()
        let progress = self.progress
        environment = ManualRequeueAction.Environment(onProgress: { await progress.emit($0) }, operations: operations, access: access,
            stagingRoot: support.appendingPathComponent("Staging"), undoRoot: undoRoot)
        let lockRoot = operations.root.appendingPathComponent("Locks")
        purgeTask = Task.detached(priority: .utility) {
            RepairAccess.pruneStaleLocks(in: lockRoot)
            while !Task.isCancelled {
                _ = try? UndoArchive.purgeExpired(root: undoRoot)
                do { try await Task.sleep(for: .seconds(60 * 60)) } catch { return }
            }
        }
        let env = environment
        verificationTask = Task.detached(priority: .utility) {
            // Each check re-hashes the original and the retry, so a quiet upload is checked less often:
            // every minute at first, doubling to every 10 minutes while its phase does not change.
            var schedule: [UUID: (due: Date, interval: TimeInterval, phase: RequeuePhase)] = [:]
            while !Task.isCancelled {
                // Complete published work even when monitoring or automatic dispatch is paused.
                let pending = (try? env.operations.knownRecords())?.filter {
                    [.published, .verifying, .uploadAcknowledged, .succeeded].contains($0.phase)
                        && $0.requiresRecovery && $0.sourceSHA256 != nil && $0.retrySHA256 != nil
                        // A record with no finding cannot be checked here; left in, it would hold a slot every pass.
                        && $0.finding != nil
                } ?? []
                // Least recently changed first among those due, so no pending repair waits behind two others.
                let due = pending.filter { (schedule[$0.id]?.due ?? .distantPast) <= Date() }.sorted { $0.updatedAt < $1.updatedAt }
                for operation in due.prefix(2) {
                    guard !Task.isCancelled else { break }
                    guard let id = operation.finding?.id else { continue }
                    var check = env
                    check.maxPolls = 1
                    _ = try? await ManualRequeueAction.perform(id: id, repository: repository, environment: check)
                    let phase = (try? env.operations.knownRecords().first { $0.id == operation.id }?.phase) ?? operation.phase
                    let interval = schedule[operation.id].map { $0.phase == phase ? min($0.interval * 2, 600) : 60 } ?? 60
                    schedule[operation.id] = (Date().addingTimeInterval(interval), interval, phase)
                }
                schedule = schedule.filter { entry in pending.contains { $0.id == entry.key } }
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
        engine = MonitoringEngine(store: repository, repairAccess: access,
            pendingRepair: { try operations.knownPending(path: $0) != nil },
            saveRoot: { try await repository.save(root: $0) },
            saveBaseline: { try await repository.setBaseline(rootID: $0, at: $1) }, runner: ProcessCommandRunner(),
            interpreting: ProductionInterpretation.standard, schedulesReconciliation: true)
    }

    public func callbacks() -> MonitorCallbacks {
        var callbacks = MonitorCallbacks()
        let env = environment
        callbacks.loadUnavailableRoots = { [engine] in await engine.unavailableRootIDs }
        callbacks.startPaused = { [engine] roots, paused in try await engine.start(roots: roots, paused: paused, persist: false, allowUnavailable: true) }
        callbacks.saveRoots = { [repository] roots in
            try MonitoringEngine.validateConfiguration(roots)
            try await repository.replaceRoots(roots)
        }
        callbacks.loadMonitoringPaused = { UserDefaults.standard.bool(forKey: "monitoringPaused") }
        callbacks.saveMonitoringPaused = { UserDefaults.standard.set($0, forKey: "monitoringPaused") }
        let permissions = try? AutomaticPermissionStore(root: env.operations.root.deletingLastPathComponent())
        callbacks.loadAutomaticRevocation = {
            guard let permissions else { return true }
            return (try? permissions.isRevoked()) ?? true
        }
        callbacks.saveAutomaticRevocation = { revoked in
            guard let permissions else { throw MonitoringError.blocked(reason: "Automatic permission storage is unavailable.") }
            try permissions.saveRevocation(revoked)
        }
        callbacks.loadEventPage = { [repository] limit, offset in try await repository.events(limit: limit, offset: offset) }
        callbacks.start = { [engine] in try await engine.start(roots: $0) }
        callbacks.scan = { [engine, repository] in
            try await engine.scanNow()
            return try await repository.findings(matching: nil)
        }
        callbacks.pause = { [engine] paused in
            if paused { await engine.pause() } else { try await engine.resume() }
        }
        callbacks.requeue = { [repository] id in
            try await ManualRequeueAction.perform(id: id, repository: repository, environment: env)
        }
        callbacks.automaticRequeue = { [repository] id, allowed in
            try await ManualRequeueAction.perform(id: id, repository: repository, environment: env,
                                                  mode: .automatic, automaticAllowed: allowed)
        }
        let recovery = RepairRecovery(operations: env.operations, access: env.access, undoRoot: env.undoRoot)
        callbacks.undo = { [repository] id in
            guard let finding = try await repository.finding(id: id) else { return nil }
            do {
                let result = try await recovery.undo(finding)
                try await repository.upsert(result)
                if let next = try await offMainActor({ try env.operations.records().first(where: { $0.finding?.id == id })?.nextFinding }) {
                    try await repository.upsert(next)
                }
                return result
            } catch {
                if let record = try await offMainActor({ try env.operations.records().first(where: { $0.finding?.id == id }) }),
                   let snapshot = record.finding {
                    try await repository.upsert(FindingRequeue.snapshot(for: record, fallback: snapshot))
                }
                throw error
            }
        }
        callbacks.resolveRecovery = { [repository] id, choice in
            guard let finding = try await repository.finding(id: id) else { return nil }
            let result = try await recovery.resolve(finding, choice: choice)
            if let closed = try await offMainActor({ try env.operations.records().first(where: { $0.finding?.id == id })?.finding }) {
                try await repository.upsert(closed)
            }
            try await repository.upsert(result)
            return result
        }
        callbacks.recheck = { [engine, repository] id in
            guard let finding = try await repository.finding(id: id) else { return nil }
            _ = try await engine.evaluateFile(finding.canonicalPath)
            return try await repository.finding(id: id)
        }
        callbacks.saveFinding = { [repository] in try await repository.upsert($0) }
        callbacks.saveRoot = { [repository] in try await repository.save(root: $0) }
        callbacks.acknowledgeBaseline = { [engine] id, _ in try await engine.acknowledgeBaseline(rootID: id) }
        callbacks.loadRoots = { [repository] in try await repository.roots() }
        callbacks.loadEvents = { [repository] in try await repository.events(limit: 100) }
        callbacks.restoreOperations = { [repository] in
            try await restoreRepairOperations(env, repository)
            // History retention is housekeeping; it must never stop monitoring from starting.
            try? await repository.pruneEvents()
        }
        callbacks.loadFindings = { [repository] in try await repository.findings(matching: nil) }
        callbacks.resetQueueStore = { [engine, repository] in
            await engine.cancelPendingFollowUps()
            let ids = try await offMainActor {
                Set(try env.operations.records().compactMap { $0.finding?.id })
                    .union(UndoArchive.records(in: env.undoRoot).compactMap(\.findingID))
            }
            try await repository.eraseDiscoveredItems(preserving: ids)
            return try await repository.findings(matching: nil)
        }
        callbacks.loadOperations = { try await offMainActor { try env.operations.knownRecords() } }
        callbacks.loadUnreadableOperations = { try await offMainActor { try env.operations.inventory().unreadable } }
        callbacks.loadUnreadableArchives = { try await offMainActor { try UndoArchive.inventory(in: env.undoRoot).unreadable } }
        callbacks.loadRecovery = {
            try await offMainActor {
                UndoArchive.records(in: env.undoRoot).map { record in
                    RecoveryFile(record: record, url: UndoArchive.payloadURL(record, root: env.undoRoot))
                }
            }
        }
        return callbacks
    }

    deinit { purgeTask.cancel(); verificationTask.cancel(); wakeTask?.cancel() }

    /// Installs the engine and progress hooks. Await it before restoring, so early updates are not dropped.
    public func attach(_ model: AppModel) async {
        wakeTask?.cancel()
        wakeTask = Task { @MainActor [weak model] in
            for await _ in NSWorkspace.shared.notificationCenter.notifications(named: NSWorkspace.didWakeNotification).map({ _ in true }) {
                guard !Task.isCancelled else { return }
                if let model, model.monitoringEnabled && !model.isPaused { model.scanNow() }
            }
        }
        let repository = repository
        let engine = engine
        await progress.setHandler { [weak model] finding in
            await MainActor.run { model?.applyRepairUpdate(finding) }
        }
        await engine.setPathChangeHandler { [weak model] path in
            do {
                let findings = try await repository.findings(at: path)
                await MainActor.run { model?.applyPathUpdate(path: path, findings: findings) }
            } catch { await MainActor.run { model?.lastErrorText = error.localizedDescription } }
        }
        await engine.setStoreChangeHandler { [weak model] in
            do {
                let events = try await repository.events(limit: 100)
                let unavailable = await engine.unavailableRootIDs
                await MainActor.run { model?.applyEventUpdate(events); model?.applyRootAvailability(unavailable) }
            } catch { await MainActor.run { model?.lastErrorText = error.localizedDescription } }
        }
    }
}

/// Journal and manifest reads block on disk. The callbacks are formed on the main actor, so without this
/// hop that I/O (and the fsyncs in restore) would stall the menu and windows.
@concurrent private func offMainActor<T: Sendable>(_ work: @Sendable () throws -> T) async throws -> T { try work() }

/// Recovery is loaded even if no watched root is available.
@concurrent private func restoreRepairOperations(_ env: ManualRequeueAction.Environment, _ repository: FindingRepository) async throws {
    var restoredFindingIDs: Set<UUID> = []
    for var record in try env.operations.knownRecords() {
        guard let snapshot = record.finding, restoredFindingIDs.insert(snapshot.id).inserted else { continue }
        if [.planned, .stagingPrepared, .clonedOrCopied, .hashed, .publishing, .archiving, .archived, .finalizing].contains(record.phase) {
            record.phase = .recoveryRequired
            record.message = "The operation was interrupted. Review the retained files."
            try env.operations.save(record)
        }
        try await repository.upsert(FindingRequeue.snapshot(for: record, fallback: snapshot))
    }
    var existingIDs = Set(try await repository.findings(matching: nil).map(\.id))
    for record in try env.operations.knownRecords() {
        if let next = record.nextFinding, existingIDs.insert(next.id).inserted { try await repository.upsert(next) }
    }
    let known = try await repository.findings(matching: nil)
    let operationFindingIDs = Set(try env.operations.knownRecords().compactMap { $0.finding?.id })
    for var finding in known where finding.hasRepairEvidence && !operationFindingIDs.contains(finding.id)
        && finding.disposition != .resolved && finding.disposition != .ignored
        && (finding.disposition != .requeueSucceeded || finding.retryPath != finding.canonicalPath) {
        if try env.operations.knownPending(path: finding.canonicalPath) == nil {
            finding.disposition = .recoveryRequired
            finding.eligibilityBlockReason = "This older repair has incomplete evidence. Review its existing files."
            try await repository.upsert(finding)
        }
    }
}

private actor RepairProgress {
    private var handler: @Sendable (FindingSnapshot) async -> Void = { _ in }
    func setHandler(_ handler: @escaping @Sendable (FindingSnapshot) async -> Void) { self.handler = handler }
    func emit(_ finding: FindingSnapshot) async { await handler(finding) }
}
