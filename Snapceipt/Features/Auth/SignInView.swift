import SwiftUI
import AuthenticationServices

/// Signed-out landing: Sign in with Apple, "Sign in with Email" (→ dedicated email login page),
/// and "Create an account" (→ dedicated sign-up page). All email / password / code entry lives on
/// the pushed sub-pages; this NavigationStack roots them. Apple + dev errors surface inline via
/// `vm.lastError` (cleared when popping back to the landing).
struct SignInView: View {
    @Environment(AuthViewModel.self) private var vm
    @Environment(\.accent) private var accent
    @State private var path: [AuthRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                AuthBrandHeader()
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
                            Button { Task { await vm.signInWithApple() } } label: { Color.clear }
                                .accessibilityLabel("Sign in with Apple")
                                .accessibilityIdentifier(AccessibilityID.signInApple)
                        )

                    Button { path.append(.emailLogin) } label: {
                        Label("Sign in with Email", systemImage: "envelope.fill")
                            .font(.ui(16, .semibold))
                            .foregroundStyle(Palette.ink)
                            .frame(maxWidth: .infinity, minHeight: 54)
                            .background(Palette.paper, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Palette.line, lineWidth: 1))
                    }
                    .accessibilityIdentifier(AccessibilityID.signInWithEmail)

                    Button { path.append(.createAccount) } label: {
                        (Text("New to Snapceipt?  ").foregroundStyle(Palette.ink3)
                         + Text("Create an account").foregroundStyle(accent.base))
                            .font(.ui(14, .semibold))
                    }
                    .accessibilityIdentifier(AccessibilityID.signInCreate)
                    .padding(.top, 6)

                    #if DEBUG
                    Button { Task { await vm.devSignIn() } } label: {
                        Label("Dev sign in", systemImage: "wrench.and.screwdriver")
                            .font(.ui(13, .semibold))
                            .foregroundStyle(Palette.ink3)
                    }
                    .accessibilityIdentifier(AccessibilityID.signInDev)
                    .padding(.top, 4)
                    #endif

                    AuthErrorText(message: vm.lastError).padding(.top, 2)
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 24)

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
            .navigationDestination(for: AuthRoute.self) { route in
                switch route {
                case .emailLogin: EmailLoginView()
                case .createAccount: CreateAccountView()
                case .forgotPassword: ForgotPasswordView()
                }
            }
            // Clear a stale sub-page error when popping back to the landing. (Apple / dev errors
            // are set while already on the landing — the path doesn't change — so they still show.)
            .onChange(of: path) { _, newPath in
                if newPath.isEmpty { vm.clearError() }
            }
        }
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
