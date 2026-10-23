import SwiftUI
import WELibrary

/// Sidebar (types and sources), wallpaper grid, inspector.
struct LibraryView: View {
    @Bindable var model: LibraryModel

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model)
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
        } detail: {
            WallpaperGrid(model: model)
                .inspector(isPresented: $model.inspectorShown) {
                    Inspector(model: model)
                        .inspectorColumnWidth(min: 260, ideal: 300, max: 380)
                }
        }
        .searchable(text: $model.search, placement: .toolbar, prompt: Text("Search titles and tags"))
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    Picker(selection: $model.sort) {
                        Text("Recently Modified").tag(LibrarySort.recent)
                        Text("Title").tag(LibrarySort.title)
                        Text("Size").tag(LibrarySort.size)
                    } label: { Text("Sort By") }
                    .pickerStyle(.inline)
                    Divider()
                    Toggle(isOn: $model.onlyRunnable) { Text("Only Wallpapers That Run on Mac") }
                    Toggle(isOn: $model.showMature) { Text("Show Questionable and Mature") }
                } label: {
                    Label { Text("View Options") } icon: { Image(systemName: "line.3.horizontal.decrease.circle") }
                }
                Button {
                    Task { await model.refresh() }
                } label: {
                    Label { Text("Refresh") } icon: { Image(systemName: "arrow.clockwise") }
                }
                .disabled(model.isRefreshing)
                Button {
                    model.inspectorShown.toggle()
                } label: {
                    Label { Text("Inspector") } icon: { Image(systemName: "sidebar.trailing") }
                }
            }
        }
    }
}

private struct Sidebar: View {
    @Bindable var model: LibraryModel

    var body: some View {
        List(selection: $model.section) {
            Section {
                row(.all, Text("All Wallpapers"), "square.grid.2x2")
                ForEach([WallpaperType.scene, .video, .web], id: \.self) { type in
                    row(.type(type), Text(type.label), type.symbol)
                }
            } header: { Text("Library") }
            Section {
                row(.steamWorkshop, Text("Steam Workshop"), "cloud")
                row(.downloads, Text("Downloaded"), "arrow.down.circle")
                ForEach(model.folders, id: \.self) { url in
                    row(.folder(url), Text(url.lastPathComponent), "folder")
                        .contextMenu {
                            Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Text("Show in Finder") }
                            Button(role: .destructive) { model.removeFolder(url) } label: { Text("Remove from Library") }
                        }
                        .help(url.path)
                }
            } header: { Text("Sources") }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button { model.addFolder() } label: {
                    Label { Text("Add Folder…") } icon: { Image(systemName: "plus") }
                }
                .buttonStyle(.borderless)
                Spacer()
                if model.isRefreshing || model.isCheckingDeep {
                    ProgressView().controlSize(.small)
                        .help(model.isRefreshing ? Text("Scanning folders…") : Text("Checking compatibility…"))
                }
            }
            .padding(10)
        }
    }

    private func row(_ section: LibrarySection, _ title: Text, _ symbol: String) -> some View {
        Label { title } icon: { Image(systemName: symbol) }
            .badge(model.count(section))
            .tag(section)
    }
}
