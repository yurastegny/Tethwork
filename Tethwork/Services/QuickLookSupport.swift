import AppKit
import QuickLookThumbnailing
import QuickLookUI
import SwiftUI

/// Shared Quick Look panel controller (Space to preview, like Finder).
@MainActor
final class QuickLookController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
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
        guard let panel = QLPreviewPanel.shared(), panel.isVisible else { return }
        panel.orderOut(nil)
        urls = []
        currentIndex = 0
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

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if isDirectory {
                Image(systemName: "folder.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(size * 0.06)
                    .foregroundStyle(isSelected ? Color.white : Color.accentColor)
                    .symbolRenderingMode(isSelected ? .monochrome : .hierarchical)
                    .shadow(color: isSelected ? .black.opacity(0.18) : .clear, radius: 0.5, y: 0.5)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(size * 0.08)
            }
        }
        .frame(width: size, height: size)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: size > 36 ? 8 : 4, style: .continuous))
        .task(id: url.path) {
            await loadThumbnail()
        }
    }

    private func loadThumbnail() async {
        if isDirectory {
            image = nil
            return
        }

        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: size * 2, height: size * 2),
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .thumbnail
        )

        do {
            let representation = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            image = representation.nsImage
        } catch {
            image = NSWorkspace.shared.icon(forFile: url.path)
        }
    }
}
