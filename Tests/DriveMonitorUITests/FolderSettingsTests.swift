import Foundation
import Testing
import DriveMonitorCore
@testable import DriveMonitorUI

@Suite @MainActor struct FolderSettingsTests {
    @Test func addingFolderPreservesExistingRulesPermissionAndRelaunch() async throws {
        let fixture = try FolderFixture(); defer { fixture.remove() }
        let original = fixture.root("Media", automatic: true)
        let repository = try FindingRepository(inMemory: true)
        try await repository.save(root: original)
        let callbacks = callbacks(repository)
        let model = AppModel(callbacks: callbacks); model.desktopNotificationsEnabled = false
        await model.restoreSavedMonitoring()
        // A draft for the existing folder must not become the new folder's policy.
        model.minimumStableAge = 912
        model.addRoot(fixture.url.appendingPathComponent("Other"))
        try await settle(model)
        #expect(model.watchedRoots.first(where: { $0.id == original.id }) == original)
        let added = try #require(model.watchedRoots.first(where: { $0.id != original.id }))
        #expect(!added.automaticRequeueEnabled && added.baselineCompletedAt == nil)
        #expect(added.minimumStableAge == 300)
        #expect(Set(added.extensions) == Set(FileFormatCatalog.presets[0].extensions))
        #expect(model.automaticRequeueEnabled)
        #expect(model.editingRootID == added.id)
        let reopened = AppModel(callbacks: callbacks); reopened.desktopNotificationsEnabled = false
        await reopened.restoreSavedMonitoring()
        #expect(Set(reopened.watchedRoots.map(\.id)) == Set([original.id, added.id]))
        #expect(reopened.watchedRoots.first(where: { $0.id == original.id }) == original)
        reopened.setAutomaticRequeueEnabled(true, rootID: added.id)
        #expect(!reopened.savingAutomaticSetting)
        #expect(reopened.lastErrorText?.contains("Review") == true)
    }

    @Test func addingFolderPreservesPause() async throws {
        let fixture = try FolderFixture(); defer { fixture.remove() }
        let repository = try FindingRepository(inMemory: true)
        try await repository.save(root: fixture.root("Media"))
        var observedPause: Bool?
        var cb = callbacks(repository)
        cb.startPaused = { _, paused in observedPause = paused }
        cb.loadMonitoringPaused = { true }
        let model = AppModel(callbacks: cb)
        await model.restoreSavedMonitoring()
        model.addRoot(fixture.url.appendingPathComponent("Other"))
        try await settle(model)
        #expect(observedPause == true && model.isPaused && !model.monitoringEnabled)
    }

    @Test func firstAddedFolderStartsMonitoringWithoutAutomaticPermission() async throws {
        let fixture = try FolderFixture(); defer { fixture.remove() }
        let repository = try FindingRepository(inMemory: true)
        var observedPause: Bool?
        var cb = callbacks(repository)
        cb.startPaused = { _, paused in observedPause = paused }
        let model = AppModel(callbacks: cb)
        await model.restoreSavedMonitoring()
        model.addRoot(fixture.url.appendingPathComponent("Media"))
        try await settle(model)
        #expect(observedPause == false && model.monitoringEnabled && !model.needsRootConfirmation)
        #expect(!model.automaticRequeueEnabled)
    }

    @Test func failedAdditionDoesNotLoseExistingFoldersOrDraft() async throws {
        let fixture = try FolderFixture(); defer { fixture.remove() }
        let original = fixture.root("Media")
        let repository = try FindingRepository(inMemory: true)
        try await repository.save(root: original)
        var cb = callbacks(repository)
        cb.saveRoots = { _ in throw CocoaError(.fileWriteOutOfSpace) }
        let model = AppModel(callbacks: cb)
        await model.restoreSavedMonitoring()
        model.minimumStableAge = 912
        model.addRoot(fixture.url.appendingPathComponent("Other"))
        try await settle(model)
        #expect(model.watchedRoots == [original])
        #expect(try await repository.roots() == [original])
        #expect(model.editingRootID == original.id && model.hasPendingFolderSettings)
        #expect(model.isPaused && model.lastErrorText != nil)
    }

    @Test func duplicateNestedAncestorAndAliasFoldersAreRejected() async throws {
        let fixture = try FolderFixture(); defer { fixture.remove() }
        let original = fixture.root("Media")
        let repository = try FindingRepository(inMemory: true)
        try await repository.save(root: original)
        let alias = fixture.url.appendingPathComponent("Alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: URL(fileURLWithPath: original.path))
        let nested = URL(fileURLWithPath: original.path).appendingPathComponent("Nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let model = AppModel(callbacks: callbacks(repository))
        await model.restoreSavedMonitoring()
        for url in [URL(fileURLWithPath: original.path), nested, fixture.url, alias] {
            model.addRoot(url)
            #expect(!model.savingConfiguration)
            #expect(model.watchedRoots == [original])
            #expect(model.lastErrorText != nil)
        }
        #expect(try await repository.roots() == [original])
        // Similar prefixes do not mean one folder contains the other.
        model.addRoot(fixture.url.appendingPathComponent("MediaExtra"))
        try await settle(model)
        #expect(model.watchedRoots.count == 2 && model.lastErrorText == nil)
    }

    @Test func cancelledFolderPickerLeavesConfigurationAlone() async throws {
        let fixture = try FolderFixture(); defer { fixture.remove() }
        let original = fixture.root("Media")
        let repository = try FindingRepository(inMemory: true)
        try await repository.save(root: original)
        let model = AppModel(pickFolder: { nil }, callbacks: callbacks(repository))
        await model.restoreSavedMonitoring()
        model.addFolder()
        #expect(model.watchedRoots == [original] && !model.savingConfiguration)
    }

    @Test func enablingOneFolderAfterRevocationDoesNotRestoreOtherOptIns() async throws {
        let fixture = try FolderFixture(); defer { fixture.remove() }
        let first = fixture.root("Media", automatic: true)
        let second = fixture.root("Other", automatic: true)
        let repository = try FindingRepository(inMemory: true)
        try await repository.replaceRoots([first, second])
        var revoked = true
        var cb = callbacks(repository)
        cb.loadAutomaticRevocation = { revoked }
        cb.saveAutomaticRevocation = { revoked = $0 }
        let model = AppModel(callbacks: cb)
        await model.restoreSavedMonitoring()
        model.setAutomaticRequeueEnabled(true, rootID: second.id)
        try await settle(model)
        let saved = try await repository.roots()
        #expect(saved.first(where: { $0.id == first.id })?.automaticRequeueEnabled == false)
        #expect(saved.first(where: { $0.id == second.id })?.automaticRequeueEnabled == true)
        #expect(!revoked && model.automaticRequeueEnabled)
    }

    @Test func folderOptOutSaveFailureRemainsRevokedAfterRelaunch() async throws {
        let fixture = try FolderFixture(); defer { fixture.remove() }
        let first = fixture.root("Media", automatic: true)
        let second = fixture.root("Other", automatic: true)
        let repository = try FindingRepository(inMemory: true)
        try await repository.replaceRoots([first, second])
        var revoked = false
        var cb = callbacks(repository)
        cb.loadAutomaticRevocation = { revoked }
        cb.saveAutomaticRevocation = { revoked = $0 }
        cb.saveRoots = { _ in throw CocoaError(.fileWriteOutOfSpace) }
        let model = AppModel(callbacks: cb)
        await model.restoreSavedMonitoring()
        model.setAutomaticRequeueEnabled(false, rootID: first.id)
        try await settle(model)
        #expect(revoked && !model.automaticRequeueEnabled && model.isPaused)
        let reopened = AppModel(callbacks: cb)
        await reopened.restoreSavedMonitoring()
        #expect(!reopened.automaticRequeueEnabled)
    }

    @Test func folderOptOutKeepsOtherAuthorizedFoldersEnabledAfterSuccessfulSave() async throws {
        let fixture = try FolderFixture(); defer { fixture.remove() }
        let first = fixture.root("Media", automatic: true)
        let second = fixture.root("Other", automatic: true)
        let repository = try FindingRepository(inMemory: true)
        try await repository.replaceRoots([first, second])
        var revoked = false
        var cb = callbacks(repository)
        cb.loadAutomaticRevocation = { revoked }
        cb.saveAutomaticRevocation = { revoked = $0 }
        let model = AppModel(callbacks: cb)
        await model.restoreSavedMonitoring()
        model.setAutomaticRequeueEnabled(false, rootID: first.id)
        try await settle(model)
        #expect(!revoked && model.automaticRequeueEnabled)
        #expect(model.watchedRoots.first(where: { $0.id == first.id })?.automaticRequeueEnabled == false)
        #expect(model.watchedRoots.first(where: { $0.id == second.id })?.automaticRequeueEnabled == true)
    }

    @Test func applyingRulesOnlyChangesSelectedFolder() async throws {
        let fixture = try FolderFixture(); defer { fixture.remove() }
        let first = fixture.root("Media")
        let second = fixture.root("Other")
        let repository = try FindingRepository(inMemory: true)
        try await repository.replaceRoots([first, second])
        let model = AppModel(callbacks: callbacks(repository))
        await model.restoreSavedMonitoring()
        model.selectSettingsRoot(second.id)
        #expect(!model.hasPendingFolderSettings)
        model.minimumStableAge = 912
        #expect(model.hasPendingFolderSettings)
        model.applyRootSettings()
        try await settle(model)
        #expect(!model.hasPendingFolderSettings)
        #expect(model.watchedRoots.first(where: { $0.id == first.id }) == first)
        #expect(try await repository.roots().first(where: { $0.id == second.id })?.minimumStableAge == 912)
        model.selectSettingsRoot(first.id)
        #expect(model.minimumStableAge == first.minimumStableAge)
    }

    @Test func setupReviewIsSpecificToSelectedFolder() async throws {
        let fixture = try FolderFixture(); defer { fixture.remove() }
        var first = fixture.root("Media"); first.baselineCompletedAt = nil
        var second = fixture.root("Other"); second.baselineCompletedAt = nil
        let repository = try FindingRepository(inMemory: true)
        try await repository.replaceRoots([first, second])
        let model = AppModel(callbacks: callbacks(repository))
        await model.restoreSavedMonitoring()
        model.acknowledgeBaseline(rootID: second.id)
        try await settle(model)
        let saved = try await repository.roots()
        #expect(saved.first(where: { $0.id == first.id })?.baselineCompletedAt == nil)
        #expect(saved.first(where: { $0.id == second.id })?.baselineCompletedAt != nil)
    }

    @Test func removingFolderPreservesFilesHistoryAndSurvivesRelaunch() async throws {
        let fixture = try FolderFixture(); defer { fixture.remove() }
        let first = fixture.root("Media", automatic: true)
        let second = fixture.root("Other")
        let file = URL(fileURLWithPath: first.path).appendingPathComponent("kept.mp4")
        try Data("keep these bytes".utf8).write(to: file)
        let finding = FindingSnapshot(id: UUID(), canonicalPath: file.path, filename: file.lastPathComponent,
            rootIdentifier: first.id, fileSize: 15, modificationDate: Date(), firstDetectedAt: Date(), lastCheckedAt: Date(),
            providerState: "Recovery pending", confirmationCount: 2, attemptCount: 1, disposition: .recoveryRequired)
        let repository = try FindingRepository(inMemory: true)
        try await repository.replaceRoots([first, second]); try await repository.upsert(finding)
        let cb = callbacks(repository)
        let model = AppModel(callbacks: cb)
        await model.restoreSavedMonitoring()
        model.selectSettingsRoot(first.id)
        model.removeRoot(first.id)
        try await settle(model)
        #expect(model.watchedRoots == [second] && model.editingRootID == second.id)
        #expect(!model.automaticRequeueEnabled)
        #expect(try Data(contentsOf: file) == Data("keep these bytes".utf8))
        #expect(try await repository.finding(id: finding.id) == finding)
        let reopened = AppModel(callbacks: cb)
        await reopened.restoreSavedMonitoring()
        #expect(reopened.watchedRoots == [second] && reopened.findings.contains(finding))
        reopened.removeRoot(second.id)
        #expect(reopened.watchedRoots == [second] && !reopened.savingConfiguration)
    }

    private func callbacks(_ repository: FindingRepository) -> MonitorCallbacks {
        var cb = MonitorCallbacks()
        cb.loadRoots = { try await repository.roots() }
        cb.loadFindings = { try await repository.findings(matching: nil) }
        cb.saveRoots = { try await repository.replaceRoots($0) }
        cb.saveRoot = { try await repository.save(root: $0) }
        cb.startPaused = { _, _ in }
        cb.pause = { _ in }
        cb.scan = { try await repository.findings(matching: nil) }
        return cb
    }
    private func settle(_ model: AppModel) async throws {
        for _ in 0..<200 {
            if !model.savingConfiguration && !model.savingAutomaticSetting && !model.changingMonitoring && !model.acknowledgingBaseline { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Settings operation did not complete.")
    }
}

private struct FolderFixture {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("folder-settings-\(UUID())").resolvingSymlinksInPath()
        for name in ["Media", "Other", "MediaExtra"] {
            try FileManager.default.createDirectory(at: url.appendingPathComponent(name), withIntermediateDirectories: true)
        }
    }
    func root(_ name: String, automatic: Bool = false) -> WatchedRootSnapshot {
        WatchedRootSnapshot(id: UUID(), path: url.appendingPathComponent(name).path, displayName: name,
            enabled: true, extensions: ["mp4"], ignorePatterns: ["*_segment_*"], minimumStableAge: 300,
            automaticRequeueEnabled: automatic, baselineCompletedAt: Date().addingTimeInterval(-3600))
    }
    func remove() { try? FileManager.default.removeItem(at: url) }
}
