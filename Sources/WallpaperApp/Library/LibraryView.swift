import SwiftUI
import WELibrary

/// Sidebar (types and sources), wallpaper grid, inspector.
struct LibraryView: View {
    @Bindable var model: LibraryModel
    @Bindable var steam: SteamModel
    @Bindable var assets: AssetsModel
    @Bindable var setup: SetupModel
    let browse: WorkshopBrowseModel
    @State private var downloadsShown = false

    private var browsing: Bool { model.section == .workshopBrowse }

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model, steam: steam)
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
        } detail: {
            if model.section == .workshopBrowse {
                WorkshopBrowseView(browse: browse)
                    .inspector(isPresented: $model.inspectorShown) {
                        WorkshopInspector(browse: browse)
                            .inspectorColumnWidth(min: 260, ideal: 300, max: 380)
                    }
            } else {
                WallpaperGrid(model: model)
                    .inspector(isPresented: $model.inspectorShown) {
                        Inspector(model: model, steam: steam)
                            .inspectorColumnWidth(min: 260, ideal: 300, max: 380)
                    }
            }
        }
        // One search field: it searches the Workshop while browsing it, the library otherwise.
        .searchable(text: browsing ? Bindable(browse).search : $model.search, placement: .toolbar,
                    prompt: browsing ? Text("Search the Workshop") : Text("Search titles and tags"))
        .onSubmit(of: .search) { if browsing { browse.reload() } }
        .onChange(of: browse.search) { old, new in
            // Clearing the search returns to the chosen sort order.
            if browsing, new.isEmpty, !old.isEmpty { browse.reload() }
        }
        .onChange(of: model.showMature) { if browse.loaded { browse.reload() } }
        .sheet(isPresented: $steam.loginSheetShown) { SteamLoginSheet(steam: steam) }
        .sheet(isPresented: $steam.importSheetShown) { ImportSheet(steam: steam) }
        .sheet(isPresented: $assets.sheetShown) { AssetsSheet(assets: assets, steam: steam) }
        .sheet(isPresented: $setup.welcomeShown) { WelcomeSheet(setup: setup, steam: steam, assets: assets, library: model) }
        .onAppear { steam.loadAccount() }
        .task {
            await assets.refresh()
            setup.showIfNeeded(steam: steam, assets: assets)
        }
        // Compare subscriptions with downloads (metadata only) whenever the account becomes available.
        .task(id: steam.account?.accountName) { await steam.syncNow() }
        .toolbar {
            ToolbarItemGroup {
                if !steam.queue.downloads.isEmpty {
                    Button { downloadsShown.toggle() } label: {
                        Label {
                            Text("Downloads")
                        } icon: {
                            if steam.queue.activeCount > 0 {
                                ProgressView(value: steam.queue.progress).progressViewStyle(.circular).controlSize(.small)
                            } else {
                                Image(systemName: "arrow.down.circle")
                            }
                        }
                    }
                    .help(Text("Downloads"))
                    .popover(isPresented: $downloadsShown, arrowEdge: .bottom) { DownloadsPopover(queue: steam.queue) }
                }
                Menu {
                    if !browsing {
                        Picker(selection: $model.sort) {
                            Text("Recently Modified").tag(LibrarySort.recent)
                            Text("Title").tag(LibrarySort.title)
                            Text("Size").tag(LibrarySort.size)
                        } label: { Text("Sort By") }
                        .pickerStyle(.inline)
                        Divider()
                        Toggle(isOn: $model.onlyRunnable) { Text("Only Wallpapers That Run on Mac") }
                    }
                    Toggle(isOn: $model.showMature) { Text("Show Questionable and Mature") }
                } label: {
                    Label { Text("View Options") } icon: { Image(systemName: "line.3.horizontal.decrease.circle") }
                }
                Button {
                    if browsing { browse.reload() } else { Task { await model.refresh() } }
                } label: {
                    Label { Text("Refresh") } icon: { Image(systemName: "arrow.clockwise") }
                }
                .disabled(browsing ? browse.state == .loading : model.isRefreshing)
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
    let steam: SteamModel

    var body: some View {
        List(selection: $model.section) {
            Section {
                if let account = steam.account {
                    // A Menu as the row itself draws dimmed in a sidebar: a plain row with a context menu, and the
                    // same actions behind "…" in the section header.
                    Label { Text(displayedAccountName(account.accountName)) } icon: { Image(systemName: "person.crop.circle.fill") }
                        .contextMenu { accountActions }
                    .help(Text("Logged in to Steam"))
                    if !steam.pendingUpdates.isEmpty {
                        Button { steam.installUpdates() } label: {
                            Label {
                                Text("Update \(steam.pendingUpdates.count) (\(steam.pendingUpdateBytes.formatted(.byteCount(style: .file))))")
                            } icon: { Image(systemName: "arrow.triangle.2.circlepath") }
                        }
                        .buttonStyle(.plain)
                        .help(Text("New versions are checked before they replace the installed ones."))
                    }
                    Label { Text("Browse the Workshop") } icon: { Image(systemName: "sparkle.magnifyingglass") }
                        .tag(LibrarySection.workshopBrowse)
                    if steam.newSubscriptionCount > 0 {
                        Button { steam.showImport() } label: {
                            Label { Text("\(steam.newSubscriptionCount) New Subscriptions…") } icon: { Image(systemName: "plus.circle") }
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    Button { steam.showLogin() } label: {
                        Label { Text("Log In to Steam…") } icon: { Image(systemName: "person.crop.circle.badge.plus") }
                    }
                    .buttonStyle(.plain)
                    if let problem = steam.accountProblem {
                        Text(problem).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } header: {
                HStack {
                    Text("Steam")
                    Spacer()
                    if steam.account != nil {
                        Menu { accountActions } label: { Image(systemName: "ellipsis.circle") }
                            .menuStyle(.button)
                            .buttonStyle(.borderless)
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .help(Text("Steam Account"))
                    }
                }
            }
            Section {
                row(.all, Text("All Wallpapers"), "square.grid.2x2")
                ForEach([WallpaperType.scene, .video, .web], id: \.self) { type in
                    row(.type(type), Text(type.label), type.symbol)
                }
            } header: { Text("Library") }
            Section {
                row(.steamWorkshop, Text("Steam Workshop"), "cloud")
                row(.downloads, Text("Downloaded"), "arrow.down.circle")
                if model.count(.bundled) > 0 { row(.bundled, Text("Included"), "gift") }
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

    @ViewBuilder private var accountActions: some View {
        Button { steam.showImport() } label: { Text("Import Subscriptions…") }
        Divider()
        Button(role: .destructive) { steam.signOut() } label: { Text("Log Out") }
    }

    private func row(_ section: LibrarySection, _ title: Text, _ symbol: String) -> some View {
        Label { title } icon: { Image(systemName: symbol) }
            .badge(model.count(section))
            .tag(section)
    }
}
