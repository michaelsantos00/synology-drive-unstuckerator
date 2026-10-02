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

/// A state overlay drawn into the menu-bar mark, so the state reads without opening the menu.
public enum MenuBarBadge: Hashable, Sendable {
    case none, paused, alert

    fileprivate var symbolName: String? {
        switch self {
        case .none: nil
        case .paused: "pause.fill"
        case .alert: "exclamationmark"
        }
    }
}

/// Menu-bar mark: a one-color template that macOS tints like every other menu bar icon.
/// The menu bar label uses the image's own size, so the artwork carries the point size.
struct MenuBarMark: View {
    var badge: MenuBarBadge = .none

    var body: some View {
        Image(nsImage: MenuBarArtwork.image(badge: badge))
            .renderingMode(.template)
            .accessibilityHidden(true)
    }
}

@MainActor
enum DockArtwork {
    static let image: NSImage = {
        let urls = ResourceLookup.urls(for: "DockMark.png")
        for url in urls {
            if let image = NSImage(contentsOf: url), image.size.width > 8 {
                return image
            }
        }
        if let icon = NSApp?.applicationIconImage, icon.size.width > 8 {
            return icon
        }
        return NSImage(size: NSSize(width: 128, height: 128))
    }()
}

@MainActor
enum MenuBarArtwork {
    /// Menu bar labels ignore SwiftUI frames, so the image itself carries the point size.
    nonisolated static let glyphHeight: CGFloat = 16
    private static var cache: [MenuBarBadge: NSImage] = [:]

    private static let source: NSImage? = ResourceLookup.urls(for: "MenuMark.png").lazy
        .compactMap { NSImage(contentsOf: $0) }.first { $0.size.width > 8 }

    static var image: NSImage { image(badge: .none) }

    static func image(badge: MenuBarBadge) -> NSImage {
        if let cached = cache[badge] { return cached }
        let image = template(badge: badge)
        cache[badge] = image
        return image
    }

    /// Redraws the art at menu-bar size for each display scale, so it stays sharp.
    private static func template(badge: MenuBarBadge) -> NSImage {
        let mark = source, badgeSymbol = badge.symbolName
        let markWidth = mark.map { (glyphHeight * $0.size.width / $0.size.height).rounded() } ?? glyphHeight
        let diameter: CGFloat = 9
        let width = badgeSymbol == nil ? markWidth : markWidth + 3
        let image = NSImage(size: NSSize(width: width, height: glyphHeight), flipped: false) { rect in
            mark?.draw(in: NSRect(x: 0, y: 0, width: markWidth, height: rect.height))
            guard let symbolName = badgeSymbol, let context = NSGraphicsContext.current else { return true }
            let disc = NSRect(x: rect.maxX - diameter, y: rect.minY, width: diameter, height: diameter)
            // Clear a ring around the badge so it reads as separate from the mark.
            context.compositingOperation = .destinationOut
            NSBezierPath(ovalIn: disc.insetBy(dx: -1.25, dy: -1.25)).fill()
            context.compositingOperation = .sourceOver
            NSColor.black.setFill()
            NSBezierPath(ovalIn: disc).fill()
            // Knock the glyph out of the disc; a template image only keeps alpha.
            if let glyph = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 6, weight: .black)) {
                let size = glyph.size
                let origin = NSPoint(x: disc.midX - size.width / 2, y: disc.midY - size.height / 2)
                glyph.draw(in: NSRect(origin: origin, size: size), from: .zero, operation: .destinationOut, fraction: 1)
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Synology Drive Unstuckerator"
        return image
    }
}

/// The packaged app copies artwork into Contents/Resources; `swift run` leaves it in the target's resource bundle.
/// `Bundle.module` is avoided because it traps when that bundle is absent, as it is in the packaged app.
private enum ResourceLookup {
    static func urls(for file: String) -> [URL] {
        let name = (file as NSString).deletingPathExtension, ext = (file as NSString).pathExtension
        var urls: [URL] = []
        if let url = Bundle.main.url(forResource: name, withExtension: ext) { urls.append(url) }
        let roots = [Bundle.main.resourceURL, Bundle.main.bundleURL.appendingPathComponent("Contents/Resources"),
                     Bundle.main.bundleURL, Bundle.main.executableURL?.deletingLastPathComponent()].compactMap { $0 }
        for root in roots {
            urls.append(root.appendingPathComponent(file))
            urls.append(root.appendingPathComponent("DriveMonitorCore_DriveMonitorUI.bundle/\(file)"))
            urls.append(root.appendingPathComponent("DriveMonitorCore_DriveMonitorUI.bundle/Contents/Resources/\(file)"))
        }
        return urls
    }
}
