import SwiftUI
import WESteam

/// QR login (default) with account + password + Steam Guard as the alternative.
struct SteamLoginSheet: View {
    @Bindable var steam: SteamModel
    @State private var accountName = ""
    @State private var password = ""
    @State private var code = ""

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Text("Log In to Steam").font(.title2.weight(.semibold))
                Text("Use the Steam account that owns Wallpaper Engine. mac-wallpaper never sees your password; Steam gives it a login that you can remove anytime.")
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Group {
                switch steam.login {
                case .idle, .qr: qrPanel
                case .password: passwordForm
                case .guardNeeded(let choices): guardForm(choices)
                case .awaitingApproval:
                    status(symbol: "iphone.radiowaves.left.and.right", Text("Approve the login in the Steam mobile app (or in the email Steam sent you)."))
                case .working:
                    ProgressView().controlSize(.large).frame(height: 220)
                case .failed(let message):
                    VStack(spacing: 12) {
                        status(symbol: "exclamationmark.triangle", Text(message))
                        Button { steam.startQR() } label: { Text("Try Again") }
                    }
                }
            }
            .frame(minHeight: 250)

            Text("This Mac will appear as “\(steam.deviceName)” under Authorized Devices in your Steam account.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                switch steam.login {
                case .password, .guardNeeded:
                    Button { steam.startQR() } label: { Text("Use QR Code Instead") }
                default:
                    Button { steam.usePassword() } label: { Text("Log In with Account Name and Password") }
                }
                Spacer()
                Button(role: .cancel) { steam.cancelLogin() } label: { Text("Cancel") }
                    .keyboardShortcut(.cancelAction)
            }
            .buttonStyle(.link)
        }
        .padding(24)
        .frame(width: 440)
    }

    @ViewBuilder private var qrPanel: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white)
                if case .qr(let url?, let scanned) = steam.login, let image = qrImage(url) {
                    Image(nsImage: image).interpolation(.none).resizable().frame(width: 200, height: 200)
                        .opacity(scanned ? 0.15 : 1)
                    if scanned {
                        VStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill").font(.system(size: 44)).foregroundStyle(.green)
                            Text("Scanned").font(.headline).foregroundStyle(.black)
                        }
                    }
                } else {
                    ProgressView()
                }
            }
            .frame(width: 220, height: 220)
            if case .qr(_, true) = steam.login {
                Text("Now confirm the login on your phone.").font(.callout.weight(.medium))
            } else {
                Text("Open the Steam app on your phone, tap the shield icon (Steam Guard), then scan this code. It refreshes by itself.")
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var passwordForm: some View {
        Form {
            TextField(text: $accountName) { Text("Account name") }
                .textContentType(.username)
            SecureField(text: $password) { Text("Password") }
                .textContentType(.password)
                .onSubmit(submitPassword)
            HStack {
                Spacer()
                Button(action: submitPassword) { Text("Log In") }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(accountName.isEmpty || password.isEmpty)
            }
        }
        .formStyle(.grouped)
        .frame(height: 200)
    }

    private func submitPassword() {
        guard !accountName.isEmpty, !password.isEmpty else { return }
        let secret = password
        password = ""
        steam.passwordLogin(account: accountName, password: secret)
    }

    private func guardForm(_ choices: [SteamGuardConfirmation]) -> some View {
        let codeKind = choices.first { $0.kind == .deviceCode }?.kind ?? choices.first { $0.kind == .emailCode }?.kind
        let approval = choices.first { $0.kind == .deviceConfirmation || $0.kind == .emailConfirmation }?.kind
        return VStack(spacing: 14) {
            if let codeKind {
                (codeKind == .deviceCode
                 ? Text("Enter the code from the Steam Guard screen in your Steam mobile app.")
                 : Text("Enter the code Steam sent to your email address."))
                    .multilineTextAlignment(.center)
                TextField(text: $code) { Text("Steam Guard code") }
                    .textFieldStyle(.roundedBorder)
                    .font(.title2.monospaced())
                    .multilineTextAlignment(.center)
                    .frame(width: 180)
                    .onSubmit { steam.submitGuard(codeKind, code: code) }
                Button { steam.submitGuard(codeKind, code: code) } label: { Text("Continue") }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(code.count < 5)
            }
            if let approval {
                Button { steam.submitGuard(approval, code: nil) } label: { Text("Approve on My Phone Instead") }
                    .buttonStyle(.link)
            }
        }
    }

    private func status(symbol: String, _ text: Text) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 40)).foregroundStyle(.secondary)
            text.multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 340)
    }
}
