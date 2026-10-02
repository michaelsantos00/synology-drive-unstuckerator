import AppKit
import SwiftUI

#if !SWIFT_PACKAGE
@main
#endif
public struct SynologyDriveMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel
    private let session: MonitorSession?

    public init() {
        let initialization = Result { try MonitorSession() }
        let session = try? initialization.get()
        self.session = session
        var callbacks = session?.callbacks() ?? MonitorCallbacks()
        callbacks.exportDiagnostic = FolderPicking.exportDiagnostic
        let model = AppModel(pickFolder: FolderPicking.pickFolder, callbacks: callbacks)
        if case .failure(let error) = initialization { model.lastErrorText = "Local recovery storage could not be opened: \(error.localizedDescription)" }
        AppDelegate.onReopen = { [weak model] in model?.handleReopen() }
        FindingNotifier.install { [weak model] findingID in
            model?.showActivity(selecting: findingID, filter: findingID == nil ? .needsAttention : nil)
        }
        Task { @MainActor in
            await session?.attach(model)
            await model.restoreSavedMonitoring()
        }
        _model = State(initialValue: model)
    }

    public var body: some Scene {
        MenuBarExtra {
            MonitorPopover(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Window("Activity", id: AppWindowID.activity.rawValue) {
            ActivityView(model: model)
        }
        .defaultSize(width: 1180, height: 720)
        // A login item should not reopen windows; the menu opens Activity when asked.
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Window("Welcome", id: AppWindowID.welcome.rawValue) {
            WelcomeView(model: model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Settings {
            MonitorSettingsView(model: model)
                .onAppear { NSApp.activate() }
        }
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("Quit Synology Drive Unstuckerator") { NSApp.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command)
            }
            SidebarCommands()
            InspectorCommands()
        }
    }
}

/// The status item. It is the only view alive from launch, so it hands its `openWindow` to the model.
struct MenuBarLabel: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 3) {
            MenuBarMark(badge: model.menuBarBadge)
            if model.badgeCount > 0 { Text(model.badgeCount, format: .number) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.menuBarAccessibilityLabel)
        .onAppear { model.windowPresenter = { openWindow(id: $0.rawValue) } }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var onReopen: () -> Void = {}

    /// Opening the app from Finder or Spotlight while it runs shows a window instead of nothing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Self.onReopen()
        return false
    }
}
