import AppKit

enum DockIcon {
    /// Inset the entire rendered tile, not just the foreground artwork. Keep
    /// Icon Composer's original assets for Finder and system appearances.
    @MainActor
    static func image(from source: NSImage) -> NSImage {
        let size = NSSize(width: 1024, height: 1024)
        return NSImage(size: size, flipped: false) { rect in
            let inset = rect.width * 0.03
            NSGraphicsContext.current?.imageInterpolation = .high
            source.draw(in: rect.insetBy(dx: inset, dy: inset),
                        from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
    }
}
