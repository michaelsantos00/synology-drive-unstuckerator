import AppKit
import SwiftUI

/// First-run setup. A menu-bar app shows nothing at launch, so this window explains where the app
/// lives and gets one folder watched.
public struct WelcomeView: View {
    @Bindable var model: AppModel
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openSettings) private var openSettings
    public init(model: AppModel) { self.model = model }

    private var configured: Bool { !model.needsRootConfirmation && !model.watchedRoots.isEmpty }

    public var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                DockMark(side: 88)
                Text("Synology Drive Unstuckerator").font(.title.bold()).accessibilityAddTraits(.isHeader)
                Text("Gets a stuck upload moving again.").font(.title3).foregroundStyle(.secondary)
            }
            .padding(.top, 34).padding(.bottom, 26)

            VStack(alignment: .leading, spacing: 16) {
                feature("eye", "Watches the folders you choose",
                        "Checks Synology Drive folders, including nested folders, for files Synology has stopped uploading.")
                feature("checkmark.shield", "Repairs one file at a time",
                        "Fix places a verified copy for Synology Drive to upload. Your original is kept, and you can undo for 6 hours once the upload is confirmed.")
                feature("menubar.arrow.up.rectangle", "Lives in the menu bar",
                        "Click the Unstuckerator icon in the menu bar to see files that need attention. Auto-fix stays off until you turn it on.")
            }
            .padding(.horizontal, 44)

            footer.padding(.horizontal, 24).padding(.top, 28).padding(.bottom, 20)
        }
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: configured) { _, done in
            if done { AccessibilityNotification.Announcement("Watching \(model.watchedFolderSummary).").post() }
        }
    }

    private func feature(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.tint).frame(width: 30).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var footer: some View {
        VStack(spacing: 12) {
            if configured {
                NoticeView(symbol: "checkmark.circle.fill", tint: .green,
                           text: "Watching \(model.watchedFolderSummary). Video files are checked by default; change file types in Settings → Folders.")
                HStack {
                    Button("Open Settings…") { NSApp.activate(); openSettings() }
                    Spacer()
                    Button("Done") { dismissWindow(id: AppWindowID.welcome.rawValue) }
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                if let error = model.lastErrorText {
                    NoticeView(symbol: "exclamationmark.octagon.fill", tint: .red, text: error, lineLimit: 5)
                }
                HStack {
                    Button("Not Now") { dismissWindow(id: AppWindowID.welcome.rawValue) }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    if model.savingConfiguration { ProgressView().controlSize(.small).accessibilityLabel("Saving folder") }
                    Button("Choose Folder…") { model.addFolder() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.savingConfiguration || model.isRestoring)
                }
                Text("Choose a folder inside Synology Drive, under ~/Library/CloudStorage.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

#Preview { WelcomeView(model: AppModel()) }
