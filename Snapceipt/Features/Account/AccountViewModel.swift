import Foundation

/// Drives the Account & security surface: the change-email code flow (request a
/// 6-digit code to a new address, then verify it and update the session), the
/// device list (from `me()`) + per-device revoke, and account deletion. Revoking
/// the current device or deleting the account clears the session and calls
/// `onSignedOut` so the shell can drop back to sign-in. (spec §8)
@Observable
@MainActor
final class AccountViewModel {
    @ObservationIgnored private let api: any APIClient
    @ObservationIgnored private let auth: AuthStore
    @ObservationIgnored private let currentDeviceId: String
    @ObservationIgnored private let onSignedOut: () -> Void

    var email: String? { auth.session?.email }
    private(set) var devices: [DeviceDTO] = []

    // Change-email flow
    var newEmail = ""
    var code = ""
    private(set) var codeSent = false
    var errorMessage: String?
    private(set) var busy = false

    init(api: any APIClient, auth: AuthStore, currentDeviceId: String, onSignedOut: @escaping () -> Void) {
        self.api = api
        self.auth = auth
        self.currentDeviceId = currentDeviceId
        self.onSignedOut = onSignedOut
    }

    func requestCode() async {
        let target = newEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard target.contains("@"), target.contains(".") else { errorMessage = "Enter a valid email."; return }
        busy = true; errorMessage = nil; defer { busy = false }
        do { _ = try await api.requestEmailChange(newEmail: target); codeSent = true }
        catch { errorMessage = "Couldn't send the code. " + friendly(error) }
    }

    func verifyCode() async {
        busy = true; errorMessage = nil; defer { busy = false }
        do {
            let user = try await api.verifyEmailChange(code: code.trimmingCharacters(in: .whitespaces))
            auth.updateEmail(user.email)
            codeSent = false; code = ""; newEmail = ""
        } catch { errorMessage = "That code didn't work. " + friendly(error) }
    }

    func loadDevices() async {
        do { devices = try await api.me().devices } catch { errorMessage = "Couldn't load devices." }
    }

    func revoke(_ id: String) async {
        do {
            try await api.revokeDevice(id: id)
            if id == currentDeviceId { signOut() } else { await loadDevices() }
        } catch { errorMessage = "Couldn't sign that device out." }
    }

    func deleteAccount() async {
        busy = true; errorMessage = nil; defer { busy = false }
        do { try await api.deleteAccount(); signOut() }
        catch { errorMessage = "Couldn't delete the account. " + friendly(error) }
    }

    var currentDevice: String { currentDeviceId }

    private func signOut() {
        auth.clear()
        onSignedOut()
    }
    private func friendly(_ e: Error) -> String {
        if let a = e as? APIError { return a.message }
        return "Please try again."
    }
}
