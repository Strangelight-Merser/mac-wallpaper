import SwiftUI
import WELibrary
import WESteam

/// The state of Wallpaper Engine's files and the one next step, shared by the files sheet and the welcome checklist.
struct AssetsStatusView: View {
    let assets: AssetsModel
    let steam: SteamModel
    /// Called before opening the Steam login (the caller closes its own sheet first).
    var logIn: () -> Void

    var body: some View {
        let manager = assets.manager
        switch manager.status {
        case .missing, .failed:
            VStack(alignment: .leading, spacing: 8) {
                if case .failed(let failure) = manager.status {
                    Label { Text(AssetsModel.message(failure)) } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    }
                }
                if let plan = manager.plannedDownload {
                    Text("\(plan.networkBytes.formatted(.byteCount(style: .file))) to download, \(plan.diskBytes.formatted(.byteCount(style: .file))) on disk (\(plan.files) files).")
                        .foregroundStyle(.secondary)
                    Button { assets.download() } label: {
                        Text("Download \(plan.networkBytes.formatted(.byteCount(style: .file)))")
                    }
                    .buttonStyle(.borderedProminent)
                } else if steam.account == nil {
                    Text("Log in to Steam to get them from your own copy of Wallpaper Engine.").foregroundStyle(.secondary)
                    Button { logIn() } label: { Text("Log In to Steam…") }
                } else {
                    Text("They come from your copy of Wallpaper Engine on Steam. The size is shown before anything downloads.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button { assets.checkSize() } label: { Text("Check Download Size") }
                }
            }
        case .checking:
            ProgressView { Text("Asking Steam…") }.controlSize(.small)
        case .downloading(let done, let total, let files, let totalFiles):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: total > 0 ? Double(done) / Double(total) : 0)
                HStack {
                    Text("\(done.formatted(.byteCount(style: .file))) of \(total.formatted(.byteCount(style: .file))) · \(files) of \(totalFiles) files")
                        .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                    Spacer()
                    Button { assets.cancel() } label: { Text("Stop") }
                }
            }
        case .installed(let location, let source, _):
            VStack(alignment: .leading, spacing: 8) {
                Label {
                    source == .downloaded ? Text("Downloaded from Steam") : Text("Using a folder you chose")
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                Text(location.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                if source == .downloaded, steam.account != nil {
                    Button { assets.checkForUpdate() } label: { Text("Check for Updates") }
                }
            }
        case .updateAvailable(_, let bytes, _):
            VStack(alignment: .leading, spacing: 8) {
                Text("An update is available (\(bytes.formatted(.byteCount(style: .file))) to download).")
                Button { assets.installUpdate() } label: { Text("Update") }.buttonStyle(.borderedProminent)
            }
        }
    }
}

/// "Wallpaper Engine Files": what scenes use, getting them from Steam or choosing a folder, updates.
struct AssetsSheet: View {
    @Bindable var assets: AssetsModel
    let steam: SteamModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Wallpaper Engine Files").font(.title2.weight(.semibold))
                Text("Scene wallpapers use Wallpaper Engine’s built-in shaders, effects and fonts (its “assets” folder). Get them from your own copy on Steam, or choose the folder copied from a Windows PC.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            AssetsStatusView(assets: assets, steam: steam) {
                assets.sheetShown = false
                steam.showLogin()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                if assets.usesChosenFolder {
                    Button { assets.useDownloadedCopy() } label: { Text("Stop Using This Folder") }
                } else {
                    Button { assets.chooseFolder() } label: { Text("Choose Folder…") }
                }
                Spacer()
                Button { assets.sheetShown = false } label: { Text("Done") }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 520)
        .task { await assets.refresh() }
    }
}

/// First run: three steps, each with its state and one action.
struct WelcomeSheet: View {
    @Bindable var setup: SetupModel
    let steam: SteamModel
    let assets: AssetsModel
    let library: LibraryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Set Up Wallpapers").font(.title2.weight(.semibold))
                Text("Bring your Wallpaper Engine wallpapers to this Mac. You need to own Wallpaper Engine on Steam.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            step(1, done: steam.account != nil) {
                Text("Log in to Steam").font(.headline)
                if let account = steam.account {
                    Text("Logged in as \(account.accountName)").foregroundStyle(.secondary)
                } else {
                    Text("Scan a QR code with the Steam app on your phone.").foregroundStyle(.secondary)
                    Button { setup.continueAfterLogin = true; setup.welcomeShown = false; steam.showLogin() } label: {
                        Text("Log In…")
                    }
                }
            }
            step(2, done: assets.isInstalled) {
                Text("Get Wallpaper Engine’s files").font(.headline)
                AssetsStatusView(assets: assets, steam: steam) {
                    setup.continueAfterLogin = true; setup.welcomeShown = false; steam.showLogin()
                }
                if !assets.isInstalled {
                    Button { assets.chooseFolder() } label: { Text("Or Choose a Folder from a Windows PC…") }
                        .buttonStyle(.link)
                }
            }
            step(3, done: library.entries.contains { $0.root == .downloads }) {
                Text("Choose your wallpapers").font(.headline)
                Text("Pick which of your Steam subscriptions to download. Sizes are shown first.").foregroundStyle(.secondary)
                Button { setup.finish(); steam.showImport() } label: { Text("Choose Subscriptions…") }
                    .disabled(steam.account == nil)
            }
            HStack {
                Spacer()
                Button { setup.finish() } label: { Text("Done") }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 540)
        .task { await assets.refresh() }
    }

    private func step<Content: View>(_ n: Int, done: Bool, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "\(n).circle")
                .font(.title2)
                .foregroundStyle(done ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
            VStack(alignment: .leading, spacing: 6, content: content)
            Spacer(minLength: 0)
        }
    }
}

/// Whether the welcome checklist is showing, and whether it should come back after a login.
@MainActor
@Observable
final class SetupModel {
    var welcomeShown = false
    var continueAfterLogin = false
    private static let doneKey = "setupDone"

    /// First launch, or nothing set up yet.
    func showIfNeeded(steam: SteamModel, assets: AssetsModel) {
        guard !UserDefaults.standard.bool(forKey: Self.doneKey) else { return }
        if steam.account == nil || !assets.isInstalled { welcomeShown = true }
    }

    func finish() {
        welcomeShown = false
        continueAfterLogin = false
        UserDefaults.standard.set(true, forKey: Self.doneKey)
    }
}
