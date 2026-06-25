import SwiftUI
import AuthenticationServices

/// Signed-out entry screen: email + password sign-in, plus Sign in with Apple and the
/// 6-digit-code paths (create account / forgot password / passwordless). A password login
/// from a NEW device is challenged with a code on the next screen (2FA). Errors surface
/// inline via `vm.lastError`.
struct SignInView: View {
    @Environment(AuthViewModel.self) private var vm
    @Environment(\.accent) private var accent

    @State private var email = ""
    @State private var password = ""
    @FocusState private var focus: Field?
    private enum Field { case email, password }

    private var isBusy: Bool { vm.state == .working }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                brand
                    .padding(.top, 52)
                    .padding(.bottom, 30)

                VStack(spacing: 12) {
                    SignInWithAppleButton(.signIn) { request in
                        request.requestedScopes = [.fullName, .email]
                    } onCompletion: { _ in }
                        .signInWithAppleButtonStyle(.black)
                        .frame(height: 54)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .allowsHitTesting(false)         // visual; tap handled by the overlay button
                        .overlay(
                            Button { Task { await vm.signInWithApple() } } label: { Color.clear }
                                .accessibilityLabel("Sign in with Apple")
                                .accessibilityIdentifier(AccessibilityID.signInApple)
                        )

                    dividerOr

                    TextField("you@example.com", text: $email)
                        .font(.ui(16))
                        .keyboardType(.emailAddress)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .focused($focus, equals: .email)
                        .onSubmit { focus = .password }
                        .modifier(FieldChrome())
                        .accessibilityIdentifier(AccessibilityID.signInEmail)

                    SecureField("Password", text: $password)
                        .font(.ui(16))
                        .textContentType(.password)
                        .submitLabel(.go)
                        .focused($focus, equals: .password)
                        .onSubmit { signIn() }
                        .modifier(FieldChrome())
                        .accessibilityIdentifier(AccessibilityID.signInPassword)

                    Button(action: signIn) {
                        Group {
                            if isBusy { ProgressView().tint(.white) } else { Text("Sign in") }
                        }
                        .font(.ui(16, .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 54)
                        .background(accent.base, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .disabled(isBusy)
                    .accessibilityIdentifier(AccessibilityID.signInSubmit)

                    HStack {
                        Button("Create an account") { startCode(.signUp) }
                            .accessibilityIdentifier(AccessibilityID.signInCreate)
                        Spacer()
                        Button("Forgot password?") { startCode(.reset) }
                            .accessibilityIdentifier(AccessibilityID.signInForgot)
                    }
                    .font(.ui(13, .semibold))
                    .foregroundStyle(accent.base)
                    .padding(.top, 2)

                    Button("Sign in with a code instead") { startCode(.codeLogin) }
                        .font(.ui(14, .semibold))
                        .foregroundStyle(Palette.ink2)
                        .accessibilityIdentifier(AccessibilityID.signInUseCode)
                        .padding(.top, 4)

                    #if DEBUG
                    Button { Task { await vm.devSignIn() } } label: {
                        Label("Dev sign in", systemImage: "wrench.and.screwdriver")
                            .font(.ui(13, .semibold))
                            .foregroundStyle(Palette.ink3)
                    }
                    .accessibilityIdentifier(AccessibilityID.signInDev)
                    .padding(.top, 6)
                    #endif

                    if let err = vm.lastError {
                        Text(err)
                            .font(.ui(13))
                            .foregroundStyle(Palette.alert)
                            .multilineTextAlignment(.center)
                            .padding(.top, 2)
                    }
                }
                .padding(.horizontal, 22)

                Text("By continuing you agree to our [Terms](https://snapceipt.cc/terms) & [Privacy Policy](https://snapceipt.cc/privacy).")
                    .font(.ui(11.5))
                    .foregroundStyle(Palette.ink3)
                    .tint(accent.base)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 36)
                    .padding(.top, 22)
                    .padding(.bottom, 18)
            }
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Palette.cream.ignoresSafeArea())
        .keyboardDismissButton()   // dismiss the email/password keyboard
    }

    private var brand: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(LinearGradient(colors: [accent.base, accent.deep],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 78, height: 78)
                    .shadow(color: accent.base.opacity(0.45), radius: 18, x: 0, y: 10)
                Image(systemName: "doc.viewfinder")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.white)
            }
            Text("Snapceipt").font(.display(30, .bold)).foregroundStyle(Palette.ink)
            Text("Snap receipts. Sort your tax. Done.")
                .font(.ui(15)).foregroundStyle(Palette.ink2).multilineTextAlignment(.center)
        }
    }

    private var dividerOr: some View {
        HStack(spacing: 10) {
            Rectangle().fill(Palette.line).frame(height: 1)
            Text("or").font(.ui(12)).foregroundStyle(Palette.ink3)
            Rectangle().fill(Palette.line).frame(height: 1)
        }
        .padding(.vertical, 2)
    }

    private func signIn() {
        let e = email, p = password
        Task { await vm.signInWithPassword(email: e, password: p) }
    }

    private func startCode(_ purpose: AuthViewModel.CodePurpose) {
        let e = email
        Task { await vm.startCode(email: e, purpose: purpose) }
    }
}

/// Shared text-field chrome (paper fill + rounded border) for the sign-in fields.
private struct FieldChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 14)
            .frame(height: 54)
            .background(Palette.paper, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Palette.line, lineWidth: 1))
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
    func passwordLogin(email: String, password: String) async throws -> PasswordLoginResult { .session(stub) }
    func passwordSet(password: String) async throws {}
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
    func extract(jpeg: Data, source: String, capturedAt: String?) async throws -> ExtractionResponse {
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
    func testPush() async throws -> TestPushResponse {
        TestPushResponse(deviceCount: 0, detail: "preview")
    }
    func simulateEmailIn(jpeg: Data, profileId: String) async throws -> SimulateInboundResponse {
        SimulateInboundResponse(transactionId: "preview-txn", extraction: "done", merchant: "Preview", deviceCount: 0)
    }
    func sendQuote(_ id: String) async throws -> SendQuoteResponse {
        SendQuoteResponse(url: "https://api.snapceipt.cc/q/preview-token", emailed: false,
                          number: "SN-0001")
    }
    func quoteShareLink(_ id: String) async throws -> QuoteShareLinkResponse {
        QuoteShareLinkResponse(url: "https://api.snapceipt.cc/q/preview-token", number: "SN-0001")
    }
    func uploadProfileLogo(profileId: String, png: Data) async throws -> UploadProfileLogoResponse {
        UploadProfileLogoResponse(logoR2Key: "\(profileId)/profiles/preview/logo")
    }
    func issueInvoice(_ id: String) async throws -> IssueInvoiceResponse {
        IssueInvoiceResponse(pdfUrl: "/invoices/dl/preview-token", number: "INV-0001",
                             status: "issued", issueDate: "2026-06-19", dueDate: "2026-07-03",
                             issuedAt: 1_790_000_000_000, subtotalCents: 0, gstCents: 0,
                             totalCents: 0, expiresAt: nil)
    }
    func sendInvoice(_ id: String) async throws -> SendInvoiceResponse {
        SendInvoiceResponse(pdfUrl: "/invoices/dl/preview-token", emailed: false)
    }
    func invoicePdf(_ id: String) async throws -> InvoicePdfResponse {
        InvoicePdfResponse(pdfUrl: "/invoices/dl/preview-token", expiresAt: nil)
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
    func mePlan() async throws -> String { "free" }
    func recordPurchase(signedTransaction: String) async throws {}
    func revokeDevice(id: String) async throws {}
    func deleteAccount() async throws {}
    func reportDiagnostic(_ body: DiagnosticReportBody) async throws {}
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
