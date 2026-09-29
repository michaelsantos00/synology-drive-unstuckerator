import DriveMonitorCore
import Foundation

@MainActor
public final class MonitorSession {
    private let repository: FindingRepository
    private let engine: MonitoringEngine
    private let purgeTask: Task<Void, Never>

    public init() throws {
        let repository = try FindingRepository(inMemory: false)
        self.repository = repository
        if let undoRoot = try? UndoArchive.supportRoot() {
            _ = try? UndoArchive.purgeExpired(root: undoRoot)
        }
        purgeTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60 * 60))
                guard !Task.isCancelled, let undoRoot = try? UndoArchive.supportRoot() else { continue }
                _ = try? UndoArchive.purgeExpired(root: undoRoot)
            }
        }
        engine = MonitoringEngine(
            store: repository,
            saveRoot: { try await repository.save(root: $0) },
            runner: ProcessCommandRunner(),
            interpreting: ProductionInterpretation.standard,
            schedulesReconciliation: true
        )
    }

    public func callbacks() -> MonitorCallbacks {
        var callbacks = MonitorCallbacks()
        callbacks.start = { [engine] roots in
            try await engine.start(roots: roots)
        }
        callbacks.scan = { [engine, repository] in
            try await engine.scanNow()
            return try await repository.findings(matching: nil)
        }
        callbacks.pause = { [engine] paused in
            if paused {
                await engine.pause()
            } else {
                try await engine.resume()
            }
        }
        callbacks.requeue = { [repository] id in
            try await ManualRequeueAction.perform(id: id, repository: repository)
        }
        callbacks.recheck = { [engine, repository] id in
            let known = try await repository.findings(matching: nil)
            guard let finding = known.first(where: { $0.id == id }) else { return nil }
            _ = try await engine.evaluateFile(finding.canonicalPath)
            return try await repository.findings(matching: nil).first(where: { $0.id == id })
        }
        callbacks.saveFinding = { [repository] finding in
            try await repository.upsert(finding)
        }
        callbacks.saveRoot = { [repository] root in
            try await repository.save(root: root)
        }
        callbacks.acknowledgeBaseline = { [engine] id, _ in
            try await engine.acknowledgeBaseline(rootID: id)
        }
        callbacks.loadRoots = { [repository] in
            try await repository.roots()
        }
        callbacks.loadEvents = { [repository] in
            try await repository.events()
        }
        callbacks.resetQueueStore = { [engine, repository] in
            await engine.cancelPendingFollowUps()
            try await repository.eraseDiscoveredItems()
        }
        return callbacks
    }

    deinit {
        purgeTask.cancel()
    }

    public func attach(_ model: AppModel) {
        let repository = repository
        Task {
            await engine.setStoreChangeHandler {
                let findings = (try? await repository.findings(matching: nil)) ?? []
                let events = (try? await repository.events()) ?? []
                await MainActor.run {
                    model.applyStoreUpdate(findings: findings, events: events)
                }
            }
        }
    }
}
