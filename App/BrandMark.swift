import AppKit
import SwiftUI

/// Polished dock artwork shown in the open menu.
struct DockMark: View {
    var side: CGFloat = 44

    var body: some View {
        Image(nsImage: DockArtwork.image)
            .resizable()
            .interpolation(.high)
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: side * 0.223, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Menu-bar mark: a one-color template that macOS tints like every other menu bar icon.
/// The menu bar label ignores `height` and uses the image's own size.
struct MenuBarMark: View {
    var height: CGFloat = MenuBarArtwork.glyphHeight

    var body: some View {
        Image(nsImage: MenuBarArtwork.image)
            .resizable()
            .renderingMode(.template)
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(height: height)
            .accessibilityHidden(true)
    }
}

@MainActor
enum DockArtwork {
    static let image: NSImage = {
        let urls = dockMarkURLs()
        for url in urls {
            if let image = NSImage(contentsOf: url), image.size.width > 8 {
                return image
            }
        }
        if let icon = NSApp.applicationIconImage, icon.size.width > 8 {
            return icon
        }
        return NSImage(size: NSSize(width: 128, height: 128))
    }()

    private static func dockMarkURLs() -> [URL] {
        var urls: [URL] = []
        if let url = Bundle.main.url(forResource: "DockMark", withExtension: "png") {
            urls.append(url)
        }
        if let resource = Bundle.main.resourceURL {
            urls.append(resource.appendingPathComponent("DockMark.png"))
            urls.append(resource.appendingPathComponent("DriveMonitorUI_DriveMonitorUI.bundle/DockMark.png"))
        }
        let executable = Bundle.main.bundleURL
        urls.append(executable.appendingPathComponent("Contents/Resources/DockMark.png"))
        urls.append(executable.deletingLastPathComponent().appendingPathComponent("DockMark.png"))
        return urls
    }
}

@MainActor
enum MenuBarArtwork {
    /// Menu bar labels ignore SwiftUI frames, so the image itself carries the point size.
    nonisolated static let glyphHeight: CGFloat = 16

    static let image: NSImage = {
        for url in menuMarkURLs() {
            if let source = NSImage(contentsOf: url), source.size.width > 8 {
                return template(from: source)
            }
        }
        let empty = NSImage(size: NSSize(width: glyphHeight, height: glyphHeight))
        empty.isTemplate = true
        return empty
    }()

    /// Redraws the art at menu-bar size for each display scale, so it stays sharp.
    private static func template(from source: NSImage) -> NSImage {
        let width = (glyphHeight * source.size.width / source.size.height).rounded()
        let image = NSImage(size: NSSize(width: width, height: glyphHeight), flipped: false) { rect in
            source.draw(in: rect)
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func menuMarkURLs() -> [URL] {
        var urls: [URL] = []
        if let url = Bundle.main.url(forResource: "MenuMark", withExtension: "png") {
            urls.append(url)
        }
        if let resource = Bundle.main.resourceURL {
            urls.append(resource.appendingPathComponent("MenuMark.png"))
            urls.append(resource.appendingPathComponent("DriveMonitorUI_DriveMonitorUI.bundle/MenuMark.png"))
        }
        let executable = Bundle.main.bundleURL
        urls.append(executable.appendingPathComponent("Contents/Resources/MenuMark.png"))
        urls.append(executable.deletingLastPathComponent().appendingPathComponent("MenuMark.png"))
        return urls
    }
}
