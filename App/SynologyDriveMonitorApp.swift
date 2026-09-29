import AppKit
import SwiftUI

#if !SWIFT_PACKAGE
@main
#endif
public struct SynologyDriveMonitorApp: App {
    @State private var model: AppModel
    private let session: MonitorSession?

    public init() {
        let session = try? MonitorSession()
        self.session = session
        var callbacks = MonitorCallbacks()
        callbacks.exportDiagnostic = FolderPicking.exportDiagnostic
        if let session {
            let connected = session.callbacks()
            callbacks.start = connected.start
            callbacks.scan = connected.scan
            callbacks.pause = connected.pause
            callbacks.recheck = connected.recheck
            callbacks.requeue = connected.requeue
            callbacks.saveFinding = connected.saveFinding
            callbacks.saveRoot = connected.saveRoot
            callbacks.acknowledgeBaseline = connected.acknowledgeBaseline
            callbacks.loadRoots = connected.loadRoots
            callbacks.loadEvents = connected.loadEvents
            callbacks.resetQueueStore = connected.resetQueueStore
        }
        let model = AppModel(pickFolder: FolderPicking.pickFolder, callbacks: callbacks)
        session?.attach(model)
        if model.desktopNotificationsEnabled { FindingNotifier.prepare() }
        Task { @MainActor in
            await model.restoreSavedMonitoring()
        }
        _model = State(initialValue: model)
    }

    public var body: some Scene {
        MenuBarExtra {
            MonitorPopover(model: model)
        } label: {
            HStack(spacing: 4) {
                MenuBarMark()
                if model.badgeCount > 0 { Text(model.badgeCount, format: .number) }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Synology Drive Unstuckerator. \(model.status.accessibilityLabel). \(model.badgeCount) findings need attention.")
        }
        .menuBarExtraStyle(.window)

        Settings {
            MonitorSettingsView(model: model)
                .onAppear { NSApp.activate() }
        }
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("Quit Synology Drive Unstuckerator") { NSApp.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command)
            }
        }
    }
}
