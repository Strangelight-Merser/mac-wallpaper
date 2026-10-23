import AppKit
import CoreImage
import Observation
import WELibrary
import WESteam

/// The Steam account, the login flow, the user's subscriptions and the download queue.
@MainActor
@Observable
final class SteamModel {
    enum Login: Equatable {
        case idle
        case qr(URL?, scanned: Bool)
        case password
        /// Waiting for the user to pick/enter a Steam Guard confirmation.
        case guardNeeded([SteamGuardConfirmation])
        /// Approve the login in the Steam mobile app (or by email).
        case awaitingApproval
        case working
        case failed(String)
    }

    enum Subscriptions: Equatable {
        case idle, loading, loaded, failed(String)
    }

    private(set) var account: SteamTokens?
    private(set) var accountLoaded = false
    var login: Login = .idle
    var loginSheetShown = false
    var importSheetShown = false
    private(set) var subscriptionsState: Subscriptions = .idle
    private(set) var subscriptions: [WorkshopItem] = []
    /// Checked rows in the import sheet.
    var chosen: Set<UInt64> = []
    let queue: DownloadQueue

    /// How this Mac appears in Steam's list of authorized devices.
    let deviceName = "mac-wallpaper on " + (Host.current().localizedName ?? "Mac")
    private var loginTask: Task<Void, Never>?
    private var guardContinuation: CheckedContinuation<(SteamGuardConfirmation.Kind, String?), Error>?

    init(library: LibraryModel) {
        queue = DownloadQueue(library: library)
    }

    /// Reads the saved login (may show a Keychain prompt for development builds).
    func loadAccount() {
        guard !accountLoaded else { return }
        accountLoaded = true
        account = try? SteamKeychain.load()
        queue.account = account
    }

    // MARK: - login

    func showLogin() {
        loginSheetShown = true
        startQR()
    }

    func startQR() {
        loginTask?.cancel()
        login = .qr(nil, scanned: false)
        loginTask = Task {
            do {
                for try await event in SteamQRLogin(deviceName: deviceName).events() {
                    switch event {
                    case .challenge(let url):
                        if case .qr(_, let scanned) = login { login = .qr(url, scanned: scanned) }
                    case .scanned:
                        if case .qr(let url, _) = login { login = .qr(url, scanned: true) }
                    case .succeeded(let tokens):
                        signedIn(tokens)
                    }
                }
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { login = .failed(Self.message(error)) }
            }
        }
    }

    func usePassword() {
        loginTask?.cancel()
        login = .password
    }

    func passwordLogin(account name: String, password: String) {
        loginTask?.cancel()
        login = .working
        loginTask = Task {
            do {
                let tokens = try await SteamPasswordLogin(deviceName: deviceName).login(account: name, password: password) { choices in
                    try await self.askGuard(choices)
                }
                signedIn(tokens)
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { login = .failed(Self.message(error)) }
            }
        }
    }

    private func askGuard(_ choices: [SteamGuardConfirmation]) async throws -> (SteamGuardConfirmation.Kind, String?) {
        // A phone/email approval needs no input: say so and let the login keep polling.
        if let approve = choices.first(where: { $0.kind == .deviceConfirmation || $0.kind == .emailConfirmation }),
           !choices.contains(where: { $0.kind == .deviceCode || $0.kind == .emailCode }) {
            login = .awaitingApproval
            return (approve.kind, nil)
        }
        login = .guardNeeded(choices)
        return try await withCheckedThrowingContinuation { guardContinuation = $0 }
    }

    /// Answer from the Steam Guard step: a code, or the choice to approve on the phone instead.
    func submitGuard(_ kind: SteamGuardConfirmation.Kind, code: String?) {
        login = kind == .deviceConfirmation || kind == .emailConfirmation ? .awaitingApproval : .working
        guardContinuation?.resume(returning: (kind, code))
        guardContinuation = nil
    }

    func cancelLogin() {
        loginTask?.cancel()
        guardContinuation?.resume(throwing: CancellationError())
        guardContinuation = nil
        login = .idle
        loginSheetShown = false
    }

    private func signedIn(_ tokens: SteamTokens) {
        do { try SteamKeychain.save(tokens) } catch { login = .failed(Self.message(error)); return }
        account = tokens
        accountLoaded = true
        queue.account = tokens
        login = .idle
        loginSheetShown = false
        // Right after logging in, offer to bring over what the user subscribed to in Wallpaper Engine.
        showImport()
    }

    func signOut() {
        if let name = account?.accountName { try? SteamKeychain.delete(account: name) }
        account = nil
        queue.account = nil
        subscriptions = []
        subscriptionsState = .idle
    }

    // MARK: - subscriptions

    func showImport() {
        importSheetShown = true
        Task { await loadSubscriptions() }
    }

    func loadSubscriptions() async {
        guard let account, subscriptionsState != .loading else { return }
        subscriptionsState = .loading
        let client = SteamCMClient(machineName: deviceName)
        do {
            try await client.connect()
            _ = try await client.logOn(account)
            let ids = try await SteamWorkshop().subscriptions(client: client, tokens: account).ids
            await client.disconnect()
            let items = try await SteamWorkshop().details(ids).filter { $0.result == 1 }
            subscriptions = items.sorted { $0.timeUpdated > $1.timeUpdated }
            chosen = Set(items.filter { isDefaultChoice($0) }.map(\.id))
            subscriptionsState = .loaded
        } catch {
            await client.disconnect()
            subscriptionsState = .failed(Self.message(error))
        }
    }

    /// Pre-selected: everything new and rated Everyone (subscribing in WE means "install").
    func isDefaultChoice(_ item: WorkshopItem) -> Bool {
        !isInLibrary(item) && (item.rating ?? .everyone) == .everyone && item.kind != .application
    }

    func isInLibrary(_ item: WorkshopItem) -> Bool {
        queue.library.entries.contains { $0.workshopID == item.id } || queue.contains(item.id)
    }

    var chosenItems: [WorkshopItem] { subscriptions.filter { chosen.contains($0.id) } }
    var chosenBytes: Int64 { chosenItems.reduce(0) { $0 + $1.fileSize } }

    func downloadChosen() {
        queue.enqueue(chosenItems)
        importSheetShown = false
    }

    static func message(_ error: Error) -> String {
        switch error {
        case SteamError.result(let n) where [5, 15, 27].contains(n):
            return String(localized: "Steam no longer accepts this login. Please log in again.")
        case SteamError.result(9), SteamError.expired:
            return String(localized: "The login request expired. Please try again.")
        case SteamError.transport, SteamError.disconnected, SteamError.timeout:
            return String(localized: "Couldn’t reach Steam. Check your network and try again.")
        case SteamError.result(let n):
            return String(localized: "Steam refused the request (error \(n)).")
        default:
            return error.localizedDescription
        }
    }
}

/// QR code image with an opaque white quiet zone (transparent borders break phone scanners on dark backgrounds).
func qrImage(_ url: URL, pointSize: CGFloat = 220) -> NSImage? {
    guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
    filter.setValue(Data(url.absoluteString.utf8), forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    guard let code = filter.outputImage else { return nil }
    let scale = (pointSize * 2) / (code.extent.width + 8)
    let scaled = code.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    let rect = scaled.extent.insetBy(dx: -4 * scale, dy: -4 * scale)
    let image = scaled.composited(over: CIImage(color: .white).cropped(to: rect))
    guard let cg = CIContext().createCGImage(image, from: rect) else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: pointSize, height: pointSize))
}
