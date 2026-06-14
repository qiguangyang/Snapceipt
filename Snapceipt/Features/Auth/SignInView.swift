import SwiftUI
import AuthenticationServices

/// First screen for a signed-out user: Sign in with Apple + a "Continue with email"
/// field that requests a magic link. Errors surface inline beneath the buttons.
struct SignInView: View {
    @Environment(AuthViewModel.self) private var vm
    @Environment(\.accent) private var accent

    @State private var email = ""
    @State private var showEmailField = false
    @FocusState private var emailFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            // Brand lockup
            VStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(
                            LinearGradient(colors: [accent.base, accent.deep],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                        .frame(width: 78, height: 78)
                        .shadow(color: accent.base.opacity(0.45), radius: 18, x: 0, y: 10)
                    Image(systemName: "doc.viewfinder")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(.white)
                }
                Text("Snapceipt")
                    .font(.display(30, .bold))
                    .foregroundStyle(Palette.ink)
                Text("Snap receipts. Sort your tax. Done.")
                    .font(.ui(15))
                    .foregroundStyle(Palette.ink2)
                    .multilineTextAlignment(.center)
            }
            .padding(.bottom, 44)

            Spacer(minLength: 0)

            VStack(spacing: 12) {
                SignInWithAppleButton(.signIn) { request in
                    request.requestedScopes = [.fullName, .email]
                } onCompletion: { _ in }
                    .signInWithAppleButtonStyle(.black)
                    .frame(height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .allowsHitTesting(false)         // visual; tap handled by the overlay button
                    .overlay(
                        Button { Task { await vm.signInWithApple() } } label: {
                            Color.clear
                        }
                        .accessibilityLabel("Sign in with Apple")
                        .accessibilityIdentifier(AccessibilityID.signInApple)
                    )

                if showEmailField {
                    emailEntry
                } else {
                    Button {
                        withAnimation { showEmailField = true }
                        emailFocused = true
                    } label: {
                        Text("Continue with email")
                            .font(.ui(16, .semibold))
                            .foregroundStyle(Palette.ink)
                            .frame(maxWidth: .infinity, minHeight: 54)
                            .background(Palette.paper, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(Palette.line, lineWidth: 1)
                            )
                    }
                    .accessibilityIdentifier(AccessibilityID.signInEmail)
                }

                #if DEBUG
                Button {
                    Task { await vm.devSignIn() }
                } label: {
                    Label("Dev sign in", systemImage: "wrench.and.screwdriver")
                        .font(.ui(13, .semibold))
                        .foregroundStyle(Palette.ink3)
                }
                .accessibilityIdentifier(AccessibilityID.signInDev)
                .padding(.top, 6)
                #endif

                if case .error(let message) = vm.state {
                    Text(message)
                        .font(.ui(13))
                        .foregroundStyle(Palette.alert)
                        .multilineTextAlignment(.center)
                        .padding(.top, 2)
                }
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 28)

            Text("By continuing you agree to our [Terms](https://snapceipt.cc/terms) & [Privacy Policy](https://snapceipt.cc/privacy).")
                .font(.ui(11.5))
                .foregroundStyle(Palette.ink3)
                .tint(accent.base)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
                .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.cream.ignoresSafeArea())
        .keyboardDismissButton()   // dismiss the email keyboard
    }

    private var emailEntry: some View {
        HStack(spacing: 10) {
            TextField("you@example.com", text: $email)
                .font(.ui(16))
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .focused($emailFocused)
                .onSubmit { send() }
                .padding(.horizontal, 14)
                .frame(height: 54)
                .background(Palette.paper, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Palette.line, lineWidth: 1)
                )

            Button(action: send) {
                Image(systemName: "arrow.right")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 54, height: 54)
                    .background(accent.base, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .disabled(email.isEmpty)
            .opacity(email.isEmpty ? 0.5 : 1)
        }
    }

    private func send() {
        let value = email
        Task { await vm.requestMagicLink(email: value) }
    }
}

#if DEBUG
/// No-op `APIClient` used only by SwiftUI previews in the auth/onboarding module so
/// they compile without the live network stack. Gated behind `#if DEBUG`.
final class PreviewAPIClient: APIClient {
    func authApple(_ body: AppleAuthBody) async throws -> SessionResponse { stub }
    func magicLinkRequest(email: String) async throws {}
    func magicLinkRequestDev(email: String) async throws -> String? { nil }
    func magicLinkVerify(token: String) async throws -> SessionResponse { stub }
    func otpRequest(email: String) async throws {}
    func otpVerify(email: String, code: String) async throws -> SessionResponse { stub }
    func refresh(refreshToken: String) async throws -> SessionResponse { stub }
    func signOut() async throws {}
    func me() async throws -> MeResponse {
        MeResponse(user: SessionUser(id: "u", email: "you@example.com", displayName: "You"), devices: [])
    }
    func syncPush(deviceId: String, mutations: [PushMutation]) async throws -> PushResponse {
        PushResponse(results: [], serverTime: Epoch.nowMs())
    }
    func syncPull(cursor: String?, limit: Int) async throws -> PullResponse {
        PullResponse(changes: [], nextCursor: nil, hasMore: false, serverTime: Epoch.nowMs())
    }
    func extract(ocrText: String, source: String, capturedAt: String?) async throws -> ExtractionResponse {
        let json = """
        {"requestId":"preview",
         "receipt":{"merchant":"Preview Cafe","date":"2026-05-28","currencyCode":"AUD",
           "total":12.00,"gst":1.09,"category":"meals","deductible":50,
           "lineItems":[],"confidence":0.9,"needsReview":false},
         "meta":{"model":"preview","source":"scan","latencyMs":1,"attempts":1,"stub":true}}
        """
        return try JSONDecoder().decode(ExtractionResponse.self, from: Data(json.utf8))
    }
    func uploadImage(jpeg: Data, transactionId: String?, width: Int, height: Int) async throws -> UploadedImage {
        UploadedImage(imageKey: "u/u/preview.jpg", getUrl: "/images/u/u/preview.jpg", byteSize: jpeg.count)
    }
    func export(profileId: String, format: String, from: String, to: String,
                toEmail: String?) async throws -> ExportResult {
        .download(url: "/export/dl/preview-token", expiresAt: 1_790_000_000_000)
    }
    func exportBas(profileId: String, from: String, to: String,
                   paygInstalmentCents: Int, toEmail: String?) async throws -> ExportResult {
        .basPack(pdfUrl: "/export/dl/preview-bas-pdf", csvUrl: "/export/dl/preview-bas-csv",
                 expiresAt: 1_790_000_000_000, emailed: false,
                 bas: BasEcho(g1: 0, oneA: 0, oneB: 0, netGst: 0, payg: 0, totalPayable: 0))
    }
    func updateDevice(_ body: UpdateDeviceBody) async throws -> UpdateDeviceResponse {
        UpdateDeviceResponse(id: "preview-device")
    }
    func sendQuote(_ id: String) async throws -> SendQuoteResponse {
        SendQuoteResponse(number: "SN-0001", sentAt: 1_790_000_000_000, status: "sent",
                          subtotalCents: 0, gstCents: 0, totalCents: 0,
                          pdfUrl: nil, expiresAt: nil, emailed: false)
    }
    func profileInbox(profileId: String) async throws -> InboxAddressResponse {
        InboxAddressResponse(profileId: profileId, token: "previewtoken",
                             address: "r.previewtoken@in.snapceipt.cc")
    }
    func rotateProfileInbox(profileId: String) async throws -> InboxAddressResponse {
        InboxAddressResponse(profileId: profileId, token: "previewtoken2",
                             address: "r.previewtoken2@in.snapceipt.cc")
    }
    func requestEmailChange(newEmail: String) async throws -> EmailChangeRequested {
        EmailChangeRequested(sent: true, devCode: "000000")
    }
    func verifyEmailChange(code: String) async throws -> AccountUser {
        AccountUser(id: "u", email: "new@example.com", displayName: "You", plan: "free")
    }
    func revokeDevice(id: String) async throws {}
    func deleteAccount() async throws {}
    private var stub: SessionResponse {
        SessionResponse(accessToken: "a.b.c", refreshToken: "r", expiresIn: 900,
                        user: SessionUser(id: "u", email: "you@example.com", displayName: "You"))
    }
}

#Preview {
    SignInView()
        .environment(AuthViewModel(
            api: PreviewAPIClient(),
            auth: AuthStore(keychain: Keychain(service: "sc.preview"))
        ))
        .environment(\.accent, .personal)
}
#endif
