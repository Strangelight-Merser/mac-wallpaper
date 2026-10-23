import SwiftUI
import WELibrary

struct WallpaperGrid: View {
    @Bindable var model: LibraryModel
    private let columns = [GridItem(.adaptive(minimum: 190, maximum: 280), spacing: 16)]

    var body: some View {
        let items = model.visible
        Group {
            if model.entries.isEmpty && !model.isRefreshing {
                ContentUnavailableView {
                    Label { Text("No Wallpapers Yet") } icon: { Image(systemName: "photo.on.rectangle.angled") }
                } description: {
                    Text("Add a folder that contains Wallpaper Engine wallpapers, for example one copied from your Windows PC. Wallpapers you subscribe to on Steam will appear here too.")
                } actions: {
                    Button { model.addFolder() } label: { Text("Add Folder…") }
                        .buttonStyle(.borderedProminent)
                }
            } else if items.isEmpty {
                ContentUnavailableView {
                    Label { Text("Nothing to Show") } icon: { Image(systemName: "line.3.horizontal.decrease.circle") }
                } description: {
                    if model.hiddenCount > 0 {
                        Text("\(model.hiddenCount) wallpapers are hidden by the search or the view options.")
                    } else {
                        Text("This section has no wallpapers.")
                    }
                }
            } else {
                ScrollView {
                    if model.assets == nil, model.entries.contains(where: { $0.compatibility?.status == .needsAssets }) {
                        AssetsBanner(model: model).padding([.horizontal, .top], 16)
                    }
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(items) { entry in
                            WallpaperCard(entry: entry, selected: model.selection == entry.id, current: model.isCurrent(entry))
                                .onTapGesture(count: 2) { model.setAsWallpaper(entry) }
                                .simultaneousGesture(TapGesture().onEnded { model.selection = entry.id })
                                .contextMenu { EntryActions(model: model, entry: entry) }
                        }
                    }
                    .padding(16)
                    if model.hiddenCount > 0 {
                        Text("\(model.hiddenCount) wallpapers are hidden by the search or the view options.")
                            .font(.callout).foregroundStyle(.secondary)
                            .padding(.bottom, 16)
                    }
                }
            }
        }
        .navigationTitle(Text("Wallpaper Library"))
        .navigationSubtitle(Text("\(items.count) wallpapers"))
    }
}

struct WallpaperCard: View {
    let entry: WallpaperEntry
    let selected: Bool
    let current: Bool
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PreviewImage(url: entry.preview, placeholder: entry.type.symbol, animating: hovering)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if current {
                        Text("On Desktop")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(6)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 3)
                }
            HStack(spacing: 6) {
                Image(systemName: entry.type.symbol).foregroundStyle(.secondary).help(entry.type.label)
                Text(entry.title).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
                CompatibilityBadge(status: entry.compatibility?.status)
            }
            .font(.callout)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
    }
}

/// Shared by the card context menu and the inspector.
struct EntryActions: View {
    let model: LibraryModel
    let entry: WallpaperEntry

    var body: some View {
        Button { model.setAsWallpaper(entry) } label: { Text("Set as Wallpaper") }
            .disabled(entry.compatibility?.status == .unsupported)
        Divider()
        Button { model.revealInFinder(entry) } label: { Text("Show in Finder") }
        if entry.workshopID != nil {
            Button { model.openWorkshopPage(entry) } label: { Text("Open Workshop Page") }
        }
    }
}

private struct AssetsBanner: View {
    let model: LibraryModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text("Scene wallpapers need Wallpaper Engine’s “assets” folder (from your Windows PC or Steam) before they can be checked and shown.")
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button { model.chooseAssets() } label: { Text("Choose Folder…") }
        }
        .padding(12)
        .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
