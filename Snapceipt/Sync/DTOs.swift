import Foundation

// MARK: - Error envelope

/// Decoded form of the backend error envelope: { error: { code, message, requestId } }.
struct ApiErrorEnvelope: Decodable {
    let error: ApiErrorBody
}

struct ApiErrorBody: Decodable {
    let code: String
    let message: String
    let requestId: String?
}

/// Thrown by `LiveAPIClient` for any non-2xx response (or a transport failure).
struct APIError: Error, Equatable {
    /// Backend error code, e.g. "AUTH_INVALID_TOKEN", "VALIDATION_FAILED", "NOT_FOUND".
    let code: String
    let message: String
    /// HTTP status (0 for a transport-level failure with no response).
    let status: Int

    static let transport = APIError(code: "TRANSPORT", message: "Network request failed", status: 0)
    static let decoding = APIError(code: "DECODING", message: "Could not decode the server response", status: 0)
    #if DEBUG
    /// `-uiTestOffline` seam: the transport-shaped error the stub/live extractors throw
    /// to force the queued-for-the-cloud fallback + outbox queue (J18b/J18c). DEBUG-only.
    static let uiTestOffline = APIError(code: "TRANSPORT", message: "offline (uiTest seam)", status: 0)
    #endif
}

// MARK: - Auth request bodies

/// POST /auth/apple — client-collected identity proof. `fullName`/`email` only on first auth.
struct AppleAuthBody: Encodable {
    let identityToken: String
    let authorizationCode: String
    let rawNonce: String
    var fullName: String?
    var email: String?
}

/// POST /auth/magic-link/request — carries the install deviceId so the backend
/// device-binds the minted token (the X-Device-Id header is the binding source;
/// this body field is a redundant hint for clients that can't set the header).
struct MagicLinkRequestBody: Encodable {
    let email: String
    let deviceId: String
}

/// POST /auth/magic-link/verify
struct MagicLinkVerifyBody: Encodable {
    let token: String
}

/// POST /auth/otp/request — 6-digit sign-in code fallback.
struct OTPRequestBody: Encodable {
    let email: String
}

/// POST /auth/otp/verify — { email, code }.
struct OTPVerifyBody: Encodable {
    let email: String
    let code: String
}

/// POST /auth/refresh
struct RefreshBody: Encodable {
    let refreshToken: String
}

// MARK: - Export (spec §4.2)

/// POST /export body: { profileId, format, from, to, toEmail? }.
/// `toEmail` required iff format == "accountant".
struct ExportRequestBody: Encodable {
    let profileId: String
    let format: String    // "pdf" | "csv" | "accountant"
    let from: String      // "YYYY-MM-DD"
    let to: String        // "YYYY-MM-DD"
    var toEmail: String?
}

/// Decoded POST /export response (the union of both server shapes; one side present).
/// pdf/csv -> { url, expiresAt }; accountant -> { status, outboxId }.
struct ExportResponse: Decodable {
    let url: String?
    let expiresAt: Int?
    let status: String?
    let outboxId: String?
}

/// The cents summary echoed by the bas-format export so the caller can reconcile
/// screen-vs-pack (spec §4.4).
struct BasEcho: Decodable, Equatable {
    let g1: Int
    let oneA: Int
    let oneB: Int
    let netGst: Int
    let payg: Int
    let totalPayable: Int
}

/// Decoded POST /export {format:"bas"} response (a genuinely new shape — two links
/// + an echoed summary, NOT the pdf/csv {url} or accountant {status} shape).
struct BasExportResponse: Decodable {
    let pdfUrl: String
    let csvUrl: String
    let expiresAt: Int
    let emailed: Bool
    let bas: BasEcho
}

/// POST /export body for the bas format: { profileId, format:"bas", from, to, bas:{paygInstalmentCents}, toEmail? }.
struct BasExportRequestBody: Encodable {
    let profileId: String
    let format: String   // always "bas"
    let from: String
    let to: String
    let bas: Payload
    var toEmail: String?
    struct Payload: Encodable { let paygInstalmentCents: Int }
}

/// The normalized export outcome the UI consumes.
enum ExportResult: Equatable {
    case download(url: String, expiresAt: Int)
    case sent(status: String, outboxId: String)
    case basPack(pdfUrl: String, csvUrl: String, expiresAt: Int, emailed: Bool, bas: BasEcho)
}

// MARK: - Auth responses

/// Returned by /auth/apple, /auth/magic-link/verify, /auth/refresh.
/// { accessToken, refreshToken, expiresIn, user }
struct SessionResponse: Decodable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int
    let user: SessionUser
}

/// The authed user; `email` and `displayName` are nullable in the backend.
struct SessionUser: Decodable {
    let id: String
    let email: String?
    let displayName: String?
}

/// GET /auth/me -> { user, devices }
struct MeResponse: Decodable {
    let user: SessionUser
    let devices: [DeviceDTO]
}

// MARK: - Password auth (email + password, with a 6-digit code as MFA on new devices)

struct PasswordLoginBody: Encodable { let email: String; let password: String }
struct PasswordSetBody: Encodable { let password: String }

/// POST /auth/password/login returns EITHER a full session OR { mfaRequired: true } when the
/// device hasn't been verified before — all fields are optional so one type decodes both.
struct PasswordLoginResponse: Decodable {
    let accessToken: String?
    let refreshToken: String?
    let expiresIn: Int?
    let user: SessionUser?
    let mfaRequired: Bool?
}

/// The two outcomes of a password login: a session, or a new-device code challenge.
enum PasswordLoginResult {
    case session(SessionResponse)
    case mfaRequired
}

/// GET /auth/me -> { user: { …, plan }, … }. A narrow decode that keeps only the
/// plan so EntitlementStore can sync the backend's cross-device truth without
/// changing the existing SessionUser shape.
struct MePlanResponse: Decodable {
    struct PlanUser: Decodable { let plan: String }
    let user: PlanUser
}

/// POST /me/subscription request body — the StoreKit 2 signed transaction JWS
/// (`Transaction.jwsRepresentation`). The backend VERIFIES Apple's signature/cert
/// chain and derives originalTransactionId/expiry/productId from the verified
/// payload, so the client no longer sends those fields (they could be forged).
struct RecordPurchaseBody: Encodable {
    let signedTransaction: String
}

/// A registered device row. `GET /auth/me` returns the full shape (§8.2); only `id`
/// is contractually guaranteed, so the rest default to nil for source-compatibility.
struct DeviceDTO: Decodable, Equatable {
    let id: String
    var platform: String? = nil
    var model: String? = nil
    var osVersion: String? = nil
    var hasApnsToken: Bool? = nil
    var pushEnabled: Bool? = nil
    var lastSeenAt: Int? = nil
    var createdAt: Int? = nil
}

// MARK: - Account & security (spec §8)

/// POST /users/me/email body.
struct EmailChangeBody: Encodable { let newEmail: String }
/// POST /users/me/email/verify body.
struct VerifyCodeBody: Encodable { let code: String }
/// POST /users/me/email response: `{ sent, devCode? }` (devCode only in E2E_TEST_MODE).
struct EmailChangeRequested: Decodable, Equatable { let sent: Bool; let devCode: String? }
/// The account user returned by the verify-email response (distinct from `SessionUser`,
/// which lacks `plan`).
struct AccountUser: Decodable, Equatable { let id: String; let email: String?; let displayName: String?; let plan: String }
/// POST /users/me/email/verify response: `{ user }`.
struct AccountUserResponse: Decodable, Equatable { let user: AccountUser }

/// PUT /devices/me body (§4.2). All fields optional; the encoder OMITS nil keys
/// (Swift's default for `Optional` Encodable), so a quiet-hours-only update never
/// clobbers the apns token and vice-versa.
struct UpdateDeviceBody: Encodable {
    var apnsToken: String?
    var quietHoursStartMin: Int?
    var quietHoursEndMin: Int?
    var timezone: String?
    var pushEnabled: Bool?
    /// The build's APNs environment ("development" for Xcode/devicectl builds, "production"
    /// for TestFlight/App Store) so the server pushes to the matching APNs host. Defaulted
    /// so quiet-hours-only callers can omit it (the encoder drops nil keys → server COALESCE keeps it).
    var apnsEnvironment: String? = nil
}

/// PUT /devices/me response — the upserted device row (only `id` is asserted).
struct UpdateDeviceResponse: Decodable {
    let id: String
}

/// POST /devices/test-push response — dev/QA push-delivery diagnostics.
struct TestPushResponse: Decodable {
    let deviceCount: Int
    let detail: String
}

/// POST /devices/simulate-inbound response — the dev/QA email-in simulation result.
struct SimulateInboundResponse: Decodable {
    let transactionId: String
    let extraction: String
    let merchant: String
    let deviceCount: Int
}

// MARK: - Quotes (spec §4.5)

/// `POST /quotes/:id/send` → the hosted HTML quote link + email status + minted number.
/// Status/totals are persisted server-side and synced via /sync — NOT returned here.
struct SendQuoteResponse: Decodable {
    /// The hosted HTML quote URL (https://api.snapceipt.cc/q/<token>).
    let url: String?
    let emailed: Bool
    /// The minted (or existing) quote number, e.g. "SN-0001". Apply to the local quote
    /// so "Quote #N" displays immediately without waiting for a sync pull.
    let number: String?
}

/// `POST /quotes/:id/link` → the hosted HTML quote URL + minted quote number (spec §4).
struct QuoteShareLinkResponse: Decodable {
    let url: String
    /// The minted (or existing) quote number. Apply to the local quote so the editor
    /// can show "Quote #N" immediately after sharing without a sync pull.
    let number: String?
}

/// `POST /profile/logo` → the stored R2 key (server-owned; iOS persists it locally
/// pull-only via sync, but the upload response lets us reflect it immediately). (spec §5)
struct UploadProfileLogoResponse: Decodable {
    let logoR2Key: String
}

// MARK: - Invoices (spec §6)

/// POST /invoices/:id/issue response. Mints the number, builds the tax-invoice PDF →
/// R2, sets status=issued + dates. The editor applies these to the local Invoice.
struct IssueInvoiceResponse: Decodable {
    let pdfUrl: String
    let number: String
    let status: String       // "issued"
    let issueDate: String    // "YYYY-MM-DD"
    let dueDate: String?     // "YYYY-MM-DD"
    let issuedAt: Int        // epoch ms
    let subtotalCents: Int
    let gstCents: Int
    let totalCents: Int
    let expiresAt: Int?
}

/// POST /invoices/:id/send response — emails the client the tax-invoice PDF.
struct SendInvoiceResponse: Decodable {
    let pdfUrl: String?
    let emailed: Bool
}

/// POST /invoices/:id/pdf response — (re)build/return the invoice PDF for share.
struct InvoicePdfResponse: Decodable {
    let pdfUrl: String
    let expiresAt: Int?
}

// MARK: - Email-in (spec §3.1 / §3.4)

/// GET /profiles/:id/inbox — the per-profile inbox alias. The
/// client treats `address` as opaque (the server owns formatting).
struct InboxAddressResponse: Decodable, Equatable {
    let profileId: String
    let token: String
    let address: String
}

// MARK: - Sync push

/// One mutation in a /sync/push batch.
/// { mutationId, entityType, entityId, op, baseRev?, updatedAt, payload }
struct PushMutation: Encodable {
    let mutationId: String
    let entityType: String
    let entityId: String
    let op: String            // "upsert" | "delete"
    var baseRev: Int?
    let updatedAt: Int
    let payload: AnyEncodable // full entity snapshot (upsert) — opaque JSON
}

/// POST /sync/push body: { deviceId, mutations }.
struct PushBody: Encodable {
    let deviceId: String
    let mutations: [PushMutation]
}

/// One per-mutation result. { mutationId, status, reason?, entity? }
struct PushResult: Decodable {
    let mutationId: String
    let status: String        // "applied" | "conflict" | "duplicate" | "rejected"
    let reason: String?
    /// Server-canonical entity envelope (present on applied/conflict/duplicate).
    let entity: PullChange?
}

/// POST /sync/push response: { results, serverTime }.
struct PushResponse: Decodable {
    let results: [PushResult]
    let serverTime: Int
}

// MARK: - Sync pull

/// GET /sync/pull response: { changes, nextCursor, hasMore, serverTime }.
struct PullResponse: Decodable {
    let changes: [PullChange]
    let nextCursor: String?
    let hasMore: Bool
    let serverTime: Int
}

/// A single pulled entity envelope. Carries the fixed SPINE sync columns (camelCase)
/// plus arbitrary domain columns (snake_case + camelCase), kept as raw JSON so the
/// SyncEngine can map per entity type without a fixed struct per table.
struct PullChange: Decodable {
    let type: String
    let id: String
    let userId: String
    let profileId: String?
    let createdAt: Int
    let updatedAt: Int
    let deletedAt: Int?
    let rev: Int
    let lastEditedDeviceId: String?
    /// Every field of the envelope, including the fixed ones above + all domain columns.
    let raw: [String: JSONValue]

    private struct AnyKey: CodingKey {
        let stringValue: String
        init?(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int? { nil }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        var dict: [String: JSONValue] = [:]
        for key in c.allKeys {
            dict[key.stringValue] = try c.decode(JSONValue.self, forKey: key)
        }
        raw = dict
        type = dict["type"]?.stringValue ?? ""
        id = dict["id"]?.stringValue ?? ""
        userId = dict["userId"]?.stringValue ?? ""
        profileId = dict["profileId"]?.stringValue
        createdAt = dict["createdAt"]?.intValue ?? 0
        updatedAt = dict["updatedAt"]?.intValue ?? 0
        deletedAt = dict["deletedAt"]?.intValue
        rev = dict["rev"]?.intValue ?? 0
        lastEditedDeviceId = dict["lastEditedDeviceId"]?.stringValue
    }

    /// Typed accessor for an arbitrary domain column (string).
    func string(_ key: String) -> String? { raw[key]?.stringValue }
    /// Typed accessor for an arbitrary domain column (int).
    func int(_ key: String) -> Int? { raw[key]?.intValue }
    /// Typed accessor for an arbitrary domain column (double).
    func double(_ key: String) -> Double? { raw[key]?.doubleValue }
    /// Typed accessor for an arbitrary domain column (bool). Coerces a numeric 0/1
    /// to false/true, because D1 stores booleans as INTEGER and the pull route
    /// serializes them straight back as JSON numbers (so a bare `.boolValue` would
    /// drop every pulled boolean flag — gstEnabled, gstInclusive, is_ai, …).
    func bool(_ key: String) -> Bool? {
        switch raw[key] {
        case let .bool(b): return b
        case let .number(n): return n != 0
        default: return nil
        }
    }
}

// MARK: - JSON helpers

/// A minimal JSON value used to carry heterogeneous entity payloads losslessly.
enum JSONValue: Decodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let d = try? c.decode(Double.self) { self = .number(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        self = .null
    }

    var stringValue: String? { if case let .string(s) = self { return s }; return nil }
    var doubleValue: Double? { if case let .number(n) = self { return n }; return nil }
    var intValue: Int? {
        if case let .number(n) = self { return Int(n) }
        return nil
    }
    var boolValue: Bool? { if case let .bool(b) = self { return b }; return nil }
}

/// Type-erased Encodable so a PushMutation can carry an already-built entity snapshot.
struct AnyEncodable: Encodable {
    private let encodeFn: (Encoder) throws -> Void
    init<T: Encodable>(_ wrapped: T) { encodeFn = wrapped.encode }
    /// Wrap a JSON-object dictionary (the usual case for an entity snapshot).
    init(_ dict: [String: AnyEncodable]) { encodeFn = { enc in try dict.encode(to: enc) } }
    func encode(to encoder: Encoder) throws { try encodeFn(encoder) }
}
