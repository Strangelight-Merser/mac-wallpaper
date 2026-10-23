import SwiftUI
import WELibrary
import WERender

struct Inspector: View {
    let model: LibraryModel

    var body: some View {
        if let entry = model.selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    PreviewImage(url: entry.preview, placeholder: entry.type.symbol, animating: true)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                    VStack(alignment: .leading, spacing: 6) {
                        Text(entry.title).font(.title3.weight(.semibold)).textSelection(.enabled)
                        HStack(spacing: 6) {
                            Label { Text(entry.type.label) } icon: { Image(systemName: entry.type.symbol) }
                            Text(verbatim: "·")
                            Text(entry.contentRating.label)
                            if entry.audioResponsive {
                                Text(verbatim: "·")
                                Label { Text("Reacts to audio") } icon: { Image(systemName: "waveform") }
                            }
                        }
                        .font(.callout).foregroundStyle(.secondary)
                    }

                    HStack {
                        Button { model.setAsWallpaper(entry) } label: {
                            (model.isCurrent(entry) ? Text("On Desktop") : Text("Set as Wallpaper")).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(model.isCurrent(entry) || entry.compatibility?.status == .unsupported)
                        Menu {
                            EntryActions(model: model, entry: entry)
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .controlSize(.large)
                    }

                    if entry.type == .scene || entry.type == .video {
                        DisplayModeSection(model: model, entry: entry)
                    }

                    CompatibilitySection(compatibility: entry.compatibility)

                    if !entry.tags.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Tags").font(.headline)
                            TagList(tags: entry.tags)
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Details").font(.headline)
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                            GridRow {
                                Text("Size").foregroundStyle(.secondary)
                                Text(entry.sizeOnDisk.formatted(.byteCount(style: .file)))
                            }
                            GridRow {
                                Text("Modified").foregroundStyle(.secondary)
                                Text(entry.modified.formatted(date: .abbreviated, time: .omitted))
                            }
                            if let id = entry.workshopID {
                                GridRow {
                                    Text("Workshop ID").foregroundStyle(.secondary)
                                    Text(verbatim: String(id)).textSelection(.enabled)
                                }
                            }
                            GridRow {
                                Text("Folder").foregroundStyle(.secondary)
                                Text(entry.folder.path).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                            }
                        }
                        .font(.callout)
                    }
                }
                .padding(16)
            }
        } else {
            ContentUnavailableView {
                Label { Text("No Selection") } icon: { Image(systemName: "rectangle.on.rectangle") }
            } description: {
                Text("Select a wallpaper to see its details. Double-click to set it as your wallpaper.")
            }
        }
    }
}

private struct CompatibilitySection: View {
    let compatibility: Compatibility?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("On This Mac").font(.headline)
            if let compatibility {
                CompatibilityBadge(status: compatibility.status, showsLabel: true)
                let missing = compatibility.missing.sorted { $0.value > $1.value }
                if !missing.isEmpty {
                    (compatibility.status == .partial
                     ? Text("Shows without these parts, which mac-wallpaper can’t play yet:")
                     : Text("Uses things mac-wallpaper can’t play yet:"))
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(missing, id: \.key) { feature, count in
                            HStack {
                                Text(verbatim: "•")
                                Text(feature.label)
                                if count > 1 { Text(verbatim: "×\(count)").foregroundStyle(.secondary) }
                            }
                        }
                    }
                    .font(.callout)
                }
            } else {
                CompatibilityBadge(status: nil)
            }
        }
    }
}

/// Wrapping row of tag capsules.
private struct TagList: View {
    let tags: [String]

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(tags, id: \.self) { tag in
                Text(tag).font(.caption)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
            }
        }
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> [(items: [Int], y: CGFloat, width: CGFloat, height: CGFloat)] {
        var rows: [(items: [Int], y: CGFloat, width: CGFloat, height: CGFloat)] = []
        var items: [Int] = [], x: CGFloat = 0, y: CGFloat = 0, height: CGFloat = 0
        for (index, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            if !items.isEmpty && x + size.width > width {
                rows.append((items, y, x - spacing, height))
                y += height + spacing; items = []; x = 0; height = 0
            }
            items.append(index); x += size.width + spacing; height = max(height, size.height)
        }
        if !items.isEmpty { rows.append((items, y, x - spacing, height)) }
        return rows
    }
}

/// How the wallpaper fills a screen of another shape.
struct DisplayModeSection: View {
    let model: LibraryModel
    let entry: WallpaperEntry

    var body: some View {
        let mode = model.contentMode(for: entry)
        VStack(alignment: .leading, spacing: 6) {
            Text("Display").font(.headline)
            Picker("Display", selection: Binding(get: { mode }, set: { model.setContentMode($0, for: entry) })) {
                Text("Fill").tag(WERender.ContentMode.fill)
                Text("Fit").tag(WERender.ContentMode.fit)
                Text("Stretch").tag(WERender.ContentMode.stretch)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Group {
                switch mode {
                case WERender.ContentMode.fill: Text("Covers the screen; edges may be cut off.")
                case WERender.ContentMode.fit: Text("Shows the whole picture, with bars if the screen is a different shape.")
                case WERender.ContentMode.stretch: Text("Fills the screen exactly; the picture may look squashed.")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }
}
