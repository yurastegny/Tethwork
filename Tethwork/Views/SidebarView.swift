import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var model: AppModel
    /// Immediate List selection — avoids flicker while `navigateTo` updates `currentPath`.
    @State private var selection: String?
    /// Keep the clicked row selected while asynchronous navigation updates the model.
    @State private var pendingNavigation: UUID?
    @State private var hasAppeared = false

    var body: some View {
        List(selection: Binding(
            get: { selection },
            set: { value in
                guard let value, value != selection else { return }
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    selection = value
                }
                applySelection(value)
            }
        )) {
            Section("Volumes") {
                if model.connections.isEmpty {
                    Text("No Connections")
                        .foregroundStyle(.secondary)
                }

                ForEach(model.connections) { conn in
                    SidebarItemLabel(
                        title: conn.name,
                        systemImage: "externaldrive",
                        isSelected: selection == SidebarID.disk(conn.id)
                    )
                        .modifier(SidebarRowStyle(isSelected: selection == SidebarID.disk(conn.id)))
                        .tag(SidebarID.disk(conn.id))
                        .contextMenu {
                            Button("Edit Connection…") {
                                model.editingConnection = conn
                            }
                            Button("Remove Connection", role: .destructive) {
                                let id = conn.id
                                Task { await model.deleteConnection(id) }
                            }
                        }
                }
            }

            if !model.connections.isEmpty {
                Section("Locations") {
                    ForEach([SidebarID.trash], id: \.self) { id in
                        HStack {
                            SidebarItemLabel(
                                title: "Trash",
                                systemImage: "trash",
                                isSelected: selection == id
                            )
                            Spacer(minLength: 8)
                            if model.trashCount > 0 {
                                Text("\(model.trashCount)")
                                    .font(.system(size: 11, weight: .regular))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                        .modifier(SidebarRowStyle(isSelected: selection == id))
                        .tag(id)
                        .help("Deleted files are kept on the network volumes for \(TrashStore.retentionDays) days")
                    }
                }
            }

            if !model.favoriteFolders.isEmpty {
                Section("Favorites") {
                    ForEach(model.favoriteFolders) { favorite in
                        SidebarItemLabel(
                            title: model.favoriteTitle(favorite),
                            systemImage: "folder",
                            isSelected: selection == SidebarID.favorite(favorite.id)
                        )
                            .modifier(SidebarRowStyle(isSelected: selection == SidebarID.favorite(favorite.id)))
                            .tag(SidebarID.favorite(favorite.id))
                            .help(favoriteHelp(favorite))
                            .contextMenu {
                                Button("Remove from Favorites") {
                                    model.removeFavorite(favorite.id)
                                }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .background(SidebarSelectionStyle())
        .contextMenu(forSelectionType: String.self) { selected in
            if let id = selected.first,
               let diskID = SidebarID.diskID(from: id),
               let conn = model.connections.first(where: { $0.id == diskID }) {
                Button("Edit Connection…") {
                    model.editingConnection = conn
                }
                Button("Remove Connection", role: .destructive) {
                    Task { await model.deleteConnection(diskID) }
                }
            } else if let value = selected.first,
                      let id = SidebarID.favoriteID(from: value) {
                Button("Remove from Favorites") {
                    model.removeFavorite(id)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button {
                model.showConnectSheet = true
            } label: {
                Label("New Connection", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .onAppear {
            setSelectionFromModel()
            if !hasAppeared {
                hasAppeared = true
                // After the sidebar show animation — mid-animation scroll jumps hitch it.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    BrowserScrollSupport.resetSidebarListScroll()
                }
            }
        }
        .onChange(of: model.currentPath) { _, _ in
            setSelectionFromModel()
        }
        .onChange(of: model.showingTrash) { _, _ in
            setSelectionFromModel()
        }
        .onChange(of: model.activeConnection?.id) { _, _ in
            setSelectionFromModel()
        }
        .onChange(of: model.favoriteFolders) { _, _ in
            setSelectionFromModel()
        }
    }

    private func setSelectionFromModel() {
        guard pendingNavigation == nil else { return }
        let derived = selectionDerivedFromModel()
        guard selection != derived else { return }
        var t = Transaction()
        t.animation = nil
        withTransaction(t) { selection = derived }
    }

    private func selectionDerivedFromModel() -> String? {
        if model.showingTrash {
            return SidebarID.trash
        }
        if let favorite = bestFavoriteMatch(for: model.currentPath) {
            return SidebarID.favorite(favorite.id)
        }
        if let id = model.activeConnection?.id {
            return SidebarID.disk(id)
        }
        return nil
    }

    private func applySelection(_ newValue: String) {
        let navigation = UUID()
        pendingNavigation = navigation
        Task { @MainActor in
            guard pendingNavigation == navigation else { return }
            if newValue == SidebarID.trash {
                await model.openTrash()
            } else {
                model.closeTrash()
                if let diskID = SidebarID.diskID(from: newValue),
                   let conn = model.connections.first(where: { $0.id == diskID }) {
                    if model.activeConnection?.id == diskID {
                        await model.navigateTo("", displayName: conn.name)
                    } else {
                        await model.selectConnection(conn)
                    }
                } else if let id = SidebarID.favoriteID(from: newValue),
                          let favorite = model.favoriteFolders.first(where: { $0.id == id }),
                          let connection = model.connections.first(where: { $0.id == favorite.connectionID }) {
                    if model.activeConnection?.id != connection.id {
                        await model.selectConnection(connection)
                    }
                    guard pendingNavigation == navigation,
                          model.activeConnection?.id == connection.id else {
                        if pendingNavigation == navigation {
                            pendingNavigation = nil
                            setSelectionFromModel()
                        }
                        return
                    }
                    await model.navigateTo(favorite.relativePath, displayName: model.favoriteTitle(favorite))
                }
            }
            guard pendingNavigation == navigation else { return }
            pendingNavigation = nil
        }
    }

    /// Match only favorites on the active server, preferring the closest ancestor.
    private func bestFavoriteMatch(for current: String) -> FavoriteFolder? {
        model.favoriteFolders.filter { favorite in
            guard favorite.connectionID == model.activeConnection?.id else { return false }
            let path = favorite.relativePath
            return current == path || (!path.isEmpty && current.hasPrefix(path + "/"))
        }
        .max { $0.relativePath.count < $1.relativePath.count }
    }

    private func favoriteHelp(_ favorite: FavoriteFolder) -> String {
        let server = model.connections.first { $0.id == favorite.connectionID }?.name ?? "Volume"
        return "\(server) · /\(favorite.relativePath)"
    }
}

private struct SidebarItemLabel: View {
    let title: String
    let systemImage: String
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 16))
                .foregroundStyle(Color.accentColor)
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
            Group {
                if isSelected {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                } else {
                    Text(title)
                        .font(.system(size: 13, weight: .regular))
                }
            }
            .foregroundStyle(.primary)
            .lineLimit(1)
        }
    }
}

private struct SidebarRowStyle: ViewModifier {
    let isSelected: Bool

    func body(content: Content) -> some View {
        content
            .transaction { transaction in
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.primary.opacity(0.1) : Color.clear)
                    .padding(.horizontal, -8)
                    .padding(.vertical, -2)
            }
    }
}

/// Suppress only this List's native accent highlight; SwiftUI supplies its gray background.
private struct SidebarSelectionStyle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { [weak view] in
            guard let view, view.window != nil else { return }
            var ancestor = view.superview
            while let container = ancestor {
                if let table = findTable(in: container) {
                    table.selectionHighlightStyle = .none
                    return
                }
                // Never reach into the file browser or another window column.
                if container is NSSplitView { return }
                ancestor = container.superview
            }
        }
    }

    private func findTable(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        if view is NSSplitView { return nil }
        for child in view.subviews {
            if let table = findTable(in: child) { return table }
        }
        return nil
    }
}

private enum SidebarID {
    private static let diskPrefix = "disk|"
    private static let favoritePrefix = "favorite|"
    static let trash = "trash"

    static func disk(_ id: String) -> String { diskPrefix + id }
    static func favorite(_ id: String) -> String { favoritePrefix + id }

    static func diskID(from value: String) -> String? {
        guard value.hasPrefix(diskPrefix) else { return nil }
        return String(value.dropFirst(diskPrefix.count))
    }

    static func favoriteID(from value: String) -> String? {
        guard value.hasPrefix(favoritePrefix) else { return nil }
        return String(value.dropFirst(favoritePrefix.count))
    }
}
