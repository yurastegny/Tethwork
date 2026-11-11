import AppKit
import QuickLookThumbnailing
import QuickLookUI
import SwiftUI
import UniformTypeIdentifiers

/// Tracks only this app's thumbnail work. Suspending paths atomically prevents
/// a newly realized row from reopening a file while a Trash operation deletes it.
final class ThumbnailRequests: @unchecked Sendable {
    static let shared = ThumbnailRequests()
    private struct Entry {
        let path: String
        let request: QLThumbnailGenerator.Request
    }
    private let lock = NSLock()
    private var active: [UUID: Entry] = [:]
    private var suspensions: [UUID: [String]] = [:]

    private static func contains(_ path: String, in root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    func register(_ request: QLThumbnailGenerator.Request, url: URL) -> UUID? {
        let path = url.standardizedFileURL.path
        return lock.withLock {
            guard !suspensions.values.joined().contains(where: { Self.contains(path, in: $0) }) else { return nil }
            let id = UUID()
            active[id] = Entry(path: path, request: request)
            return id
        }
    }

    func finish(_ id: UUID) {
        lock.withLock { _ = active.removeValue(forKey: id) }
    }

    func suspend(in roots: [URL]) -> UUID {
        let paths = roots.map { $0.standardizedFileURL.path }
        let token = UUID()
        let cancelled: [QLThumbnailGenerator.Request] = lock.withLock {
            suspensions[token] = paths
            let matches = active.filter { entry in paths.contains { Self.contains(entry.value.path, in: $0) } }
            for id in matches.keys { active.removeValue(forKey: id) }
            return matches.values.map(\.request)
        }
        for request in cancelled { QLThumbnailGenerator.shared.cancel(request) }
        return token
    }

    func resume(_ token: UUID) {
        lock.withLock { _ = suspensions.removeValue(forKey: token) }
    }
}

/// Shared Quick Look panel controller (Space to preview, like Finder).
@MainActor
final class QuickLookController: NSObject, @preconcurrency QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookController()

    private var urls: [URL] = []
    private var currentIndex = 0

    var isVisible: Bool {
        QLPreviewPanel.shared()?.isVisible == true
    }

    func preview(urls: [URL], startingAt index: Int = 0) {
        let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else { return }
        self.urls = existing
        self.currentIndex = min(max(0, index), existing.count - 1)

        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.currentPreviewItemIndex = currentIndex
        if !panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// Update items while the panel stays open (Finder-like: arrow keys change preview).
    func updateIfVisible(urls: [URL], startingAt index: Int = 0) {
        guard isVisible else { return }
        let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else {
            close()
            return
        }
        // Skip no-op reloads for the same file set / index.
        let sameURLs = existing.map(\.path) == self.urls.map(\.path)
        let nextIndex = min(max(0, index), existing.count - 1)
        if sameURLs, nextIndex == currentIndex {
            return
        }
        preview(urls: existing, startingAt: index)
    }

    func close() {
        urls = []
        currentIndex = 0
        guard QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared() else { return }
        panel.orderOut(nil)
        panel.reloadData()
        panel.dataSource = nil
        panel.delegate = nil
    }

    func close(ifInside roots: [URL]) {
        let paths = roots.map { $0.standardizedFileURL.path }
        guard urls.contains(where: { url in
            let path = url.standardizedFileURL.path
            return paths.contains { path == $0 || path.hasPrefix($0 + "/") }
        }) else { return }
        close()
    }

    func toggle(urls: [URL], startingAt index: Int = 0) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            close()
        } else {
            preview(urls: urls, startingAt: index)
        }
    }

    // MARK: - QLPreviewPanelDataSource

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        urls.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard urls.indices.contains(index) else { return nil }
        return urls[index] as NSURL
    }
}

struct FileThumbnailView: View {
    let url: URL
    let isDirectory: Bool
    var size: CGFloat = 40
    /// When true, folder tint switches to white so it stays visible on accent selection.
    var isSelected: Bool = false
    var modified: Date = .distantPast
    var allowsThumbnail: Bool = true

    @State private var image: NSImage?
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 300
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()
    private var cacheKey: String { "\(url.path)|\(modified.timeIntervalSince1970)|\(size)" }

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    // Preserve the complete preview, including document edges.
                    .aspectRatio(contentMode: .fit)
            } else if isDirectory {
                Image(systemName: "folder.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(isSelected ? Color.white : Color.accentColor)
                    .symbolRenderingMode(isSelected ? .monochrome : .hierarchical)
                    .shadow(color: isSelected ? .black.opacity(0.18) : .clear, radius: 0.5, y: 0.5)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(for: UTType(filenameExtension: url.pathExtension) ?? .data))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
        // All representations share one inset rather than giving thumbnails
        // more visual space than folder and fallback icons.
        .padding(size * 0.06)
        .frame(width: size, height: size)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: size > 36 ? 8 : 4, style: .continuous))
        .accessibilityHidden(true)
        .task(id: "\(cacheKey)|\(allowsThumbnail)") {
            await loadThumbnail()
        }
    }

    private func loadThumbnail() async {
        image = nil
        if isDirectory || !allowsThumbnail {
            image = nil
            return
        }

        let key = cacheKey as NSString
        if let cached = Self.cache.object(forKey: key) {
            image = cached
            return
        }
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: size * 2, height: size * 2),
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .thumbnail
        )
        guard let id = ThumbnailRequests.shared.register(request, url: url) else { return }
        defer { ThumbnailRequests.shared.finish(id) }

        do {
            let representation = try await withTaskCancellationHandler {
                try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            } onCancel: {
                QLThumbnailGenerator.shared.cancel(request)
            }
            try Task.checkCancellation()
            image = representation.nsImage
            Self.cache.setObject(representation.nsImage, forKey: key, cost: Int(size * size * 16))
        } catch {
            guard !Task.isCancelled else { return }
            image = NSWorkspace.shared.icon(for: UTType(filenameExtension: url.pathExtension) ?? .data)
        }
    }
}
