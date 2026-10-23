import SwiftUI
import WELibrary
import WERender

struct Inspector: View {
    let model: LibraryModel
    let steam: SteamModel

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

                    PropertiesSection(model: model, entry: entry)

                    CompatibilitySection(compatibility: entry.compatibility)

                    if entry.root == .downloads, let id = entry.workshopID {
                        UpdatesSection(steam: steam, id: id)
                    }

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

/// Held updates, restoring the previous version, and items no longer subscribed (downloads only).
private struct UpdatesSection: View {
    let steam: SteamModel
    let id: UInt64

    var body: some View {
        let held = steam.syncState.held[id]
        let previous = steam.hasPreviousVersion(id)
        let unsubscribed = steam.isUnsubscribed(id)
        if held != nil || previous || unsubscribed {
            VStack(alignment: .leading, spacing: 8) {
                Text("Updates").font(.headline)
                if let held {
                    Text(held.reason.explanation).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button { steam.installHeldUpdate(id) } label: { Text("Install Anyway") }
                        Button { steam.dismissHeldUpdate(id) } label: { Text("Keep This Version") }
                    }
                }
                if previous {
                    Button { steam.restorePreviousVersion(id) } label: { Text("Restore Previous Version") }
                }
                if unsubscribed {
                    Text("No longer in your Steam subscriptions. It stays here until you remove it.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// The wallpaper's own settings (project.json properties), applied live to the desktop when it is the current one.
private struct PropertiesSection: View {
    let model: LibraryModel
    let entry: WallpaperEntry

    var body: some View {
        let all = model.properties(for: entry)
        if !all.isEmpty {
            let values = model.propertyValues(for: entry)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Settings").font(.headline)
                    Spacer()
                    if model.hasPropertyChanges(entry) {
                        Button { model.resetProperties(for: entry) } label: { Text("Reset to Defaults") }
                            .buttonStyle(.link).font(.callout)
                    }
                }
                ForEach(all.filter { WallpaperProperties.isVisible($0, values: values) }) { property in
                    PropertyRow(property: property, value: values[property.id]) { model.setProperty($0, key: property.id, for: entry) }
                }
            }
        }
    }
}

private struct PropertyRow: View {
    let property: WallpaperProperty
    let value: String?
    let set: (String) -> Void
    @State private var text = ""

    var body: some View {
        let label = PropertyText.label(property.label.isEmpty ? property.id : property.label)
        switch property.kind {
        case .group:
            Text(label.text).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 4)
        case .label:
            if let link = label.link {
                Link(destination: link) { Text(label.text) }.font(.callout)
            } else if !label.text.isEmpty {
                Text(label.text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        case .bool:
            Toggle(isOn: Binding(get: { value == "true" || value == "1" }, set: { set($0 ? "true" : "false") })) {
                Text(label.text)
            }
            .toggleStyle(.switch).controlSize(.small)
        case .slider(let min, let max, let step, let precision, let fraction):
            let number = Double(value ?? "") ?? min
            let digits = precision ?? (fraction || (step.map { $0 < 1 } ?? (max - min <= 10)) ? 2 : 0)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(label.text)
                    Spacer()
                    Text(number.formatted(.number.precision(.fractionLength(digits)))).foregroundStyle(.secondary).monospacedDigit()
                }
                // No `step:` argument: AppKit then draws one tick mark per step, and a fine step over a wide
                // range (0…1000 by 0.01) hangs the window. Values snap to the step instead.
                Slider(value: Binding(get: { number }, set: { v in
                    let snapped = step.map { $0 > 0 ? min + ((v - min) / $0).rounded() * $0 : v } ?? v
                    set(Self.format(Swift.min(max, Swift.max(min, snapped)), digits))
                }), in: min...Swift.max(min + 0.0001, max))
                .controlSize(.small)
            }
        case .color:
            ColorPicker(selection: Binding(get: { Self.color(value) }, set: { set(Self.string($0)) }), supportsOpacity: false) {
                Text(label.text)
            }
        case .combo(let options):
            Picker(selection: Binding(get: { value ?? options.first?.value ?? "" }, set: { set($0) })) {
                ForEach(options, id: \.value) { option in Text(PropertyText.label(option.label).text).tag(option.value) }
            } label: { Text(label.text) }
            .pickerStyle(.menu)
        case .textInput:
            VStack(alignment: .leading, spacing: 4) {
                Text(label.text)
                TextField(text: $text) { Text(label.text) }
                    .labelsHidden()
                    .onSubmit { set(text) }
                    .onAppear { text = value ?? "" }
                    .onChange(of: value) { text = value ?? "" }
            }
        case .file, .directory, .unknown:
            LabeledContent { Text(value ?? "").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) } label: {
                Text(label.text)
            }
        }
    }

    static func format(_ v: Double, _ digits: Int) -> String {
        digits == 0 ? String(Int(v.rounded())) : String(format: "%.\(digits)f", v)
    }

    /// WE colours are "r g b" in 0…1.
    static func color(_ s: String?) -> Color {
        let c = (s ?? "").split(separator: " ").compactMap { Double($0) }
        guard c.count >= 3 else { return .white }
        return Color(.sRGB, red: c[0], green: c[1], blue: c[2])
    }

    static func string(_ color: Color) -> String {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
        return [ns.redComponent, ns.greenComponent, ns.blueComponent].map { String(format: "%.5g", Double($0)) }.joined(separator: " ")
    }
}
