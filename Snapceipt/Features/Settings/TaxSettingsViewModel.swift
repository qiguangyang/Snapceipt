import Foundation
import SwiftData
import UIKit

/// GST-rate presets for the Tax & GST settings control. (spec §3)
enum GstRatePreset: String, CaseIterable, Identifiable {
    case au, nz, custom
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .au: return "10%"
        case .nz: return "15%"
        case .custom: return "Custom %"
        }
    }
}

/// Edits the active profile's tax_settings (+ the Profile's ABN/GST identity).
/// `@MainActor`; deps injected. Lazily ensures a tax_settings row exists.
@Observable
@MainActor
final class TaxSettingsViewModel {
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let sync: any SyncEnqueuing
    @ObservationIgnored private let userId: String
    @ObservationIgnored private let profile: Profile
    @ObservationIgnored private let api: APIClient
    @ObservationIgnored private var settings: TaxSettings

    var showsBusinessIdentity: Bool { profile.type == "business" }

    // Mirrored editable state (read from the row at init).
    private(set) var mealsDeductiblePct: Int
    private(set) var wfhRateCentsPerHour: Int
    private(set) var financialYearStartMonth: Int
    private(set) var gstRegistered: Bool
    private(set) var abn: String

    // GST rate (bp) + business/bank details (mirror the active Profile). (spec §3, §5)
    private(set) var gstRateBp: Int
    /// The user's selected GST-rate segment. Stored (not derived) so "Custom" stays
    /// selected even when the rate is a round number (e.g. custom 10%) — otherwise the
    /// segmented control snaps back to a preset and the custom field never appears.
    private(set) var gstRatePreset: GstRatePreset
    private(set) var businessEmail: String
    private(set) var phone: String
    private(set) var website: String
    private(set) var addressText: String
    private(set) var bankDetails: String
    private(set) var logoR2Key: String?
    /// The logo bitmap for the settings preview. Set on upload and cached locally
    /// (keyed by profile id) so the preview survives reopening settings — the R2 key
    /// alone can't be rendered on-device (it's only inlined server-side in the HTML quote).
    private(set) var logoImage: UIImage?
    private(set) var isUploadingLogo = false
    var logoUploadError: String?

    // Local-only prefs (no column): entity type, GST basis, BAS period, vehicle method.
    var entityType: String { didSet { defaults.set(entityType, forKey: key("entityType")) } }
    var gstBasis: String { didSet { defaults.set(gstBasis, forKey: key("gstBasis")) } }
    var basPeriodRaw: String { didSet { defaults.set(basPeriodRaw, forKey: key("basPeriod")) } }

    @ObservationIgnored private let defaults: UserDefaults
    private func key(_ k: String) -> String { "sc.tax.\(profile.id).\(k)" }

    var basPeriod: BasPeriod { BasPeriod(rawValue: basPeriodRaw) ?? .quarterly }
    var nextBasDue: Date { BasSchedule.nextDue(basPeriod, on: Date()) }

    init(context: ModelContext, sync: any SyncEnqueuing, userId: String, profile: Profile,
         api: APIClient, defaults: UserDefaults = .standard) {
        self.context = context
        self.sync = sync
        self.userId = userId
        self.profile = profile
        self.api = api
        self.defaults = defaults

        let pid = profile.id
        var d = FetchDescriptor<TaxSettings>(predicate: #Predicate { $0.profileId == pid && $0.deletedAt == nil })
        d.fetchLimit = 1
        if let row = (try? context.fetch(d))?.first {
            self.settings = row
        } else {
            let row = TaxSettings(userId: userId, profileId: pid)
            context.insert(row)
            try? context.save()
            sync.enqueue(op: "upsert", entityType: .taxSettings, entity: row)
            self.settings = row
        }
        self.mealsDeductiblePct = settings.mealsDeductiblePct
        self.wfhRateCentsPerHour = settings.wfhRateCentsPerHour
        self.financialYearStartMonth = settings.financialYearStartMonth
        self.gstRegistered = profile.gstRegistered
        self.abn = profile.abn ?? ""
        self.gstRateBp = profile.gstRateBp
        self.gstRatePreset = Self.preset(forBp: profile.gstRateBp)
        self.businessEmail = profile.businessEmail ?? ""
        self.phone = profile.phone ?? ""
        self.website = profile.website ?? ""
        self.addressText = profile.addressText ?? ""
        self.bankDetails = profile.bankDetails ?? ""
        self.logoR2Key = profile.logoR2Key
        if let url = Self.logoCacheURL(profileId: pid), let data = try? Data(contentsOf: url) {
            self.logoImage = UIImage(data: data)
        }
        self.entityType = defaults.string(forKey: "sc.tax.\(pid).entityType") ?? "Sole trader"
        self.gstBasis = defaults.string(forKey: "sc.tax.\(pid).gstBasis") ?? "Cash"
        self.basPeriodRaw = defaults.string(forKey: "sc.tax.\(pid).basPeriod") ?? BasPeriod.quarterly.rawValue
    }

    private func saveSettings() {
        settings.updatedAt = Epoch.nowMs()
        try? context.save()
        sync.enqueue(op: "upsert", entityType: .taxSettings, entity: settings)
    }
    private func saveProfile() {
        profile.updatedAt = Epoch.nowMs()
        try? context.save()
        sync.enqueue(op: "upsert", entityType: .profile, entity: profile)
    }

    func setMealsDeductiblePct(_ v: Int) { let c = max(0, min(100, v)); mealsDeductiblePct = c; settings.mealsDeductiblePct = c; saveSettings() }
    func setWfhRate(_ cents: Int) { let c = max(0, cents); wfhRateCentsPerHour = c; settings.wfhRateCentsPerHour = c; saveSettings() }
    func setFinancialYearStartMonth(_ m: Int) { let c = max(1, min(12, m)); financialYearStartMonth = c; settings.financialYearStartMonth = c; saveSettings() }
    func setGstRegistered(_ on: Bool) { gstRegistered = on; profile.gstRegistered = on; saveProfile() }
    func setAbn(_ s: String) { abn = s; profile.abn = s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : s; saveProfile() }

    // MARK: - GST rate (bp)

    /// Maps a basis-point rate to its preset (1000→.au, 1500→.nz, else .custom).
    static func preset(forBp bp: Int) -> GstRatePreset {
        switch bp {
        case 1000: return .au
        case 1500: return .nz
        default: return .custom
        }
    }
    /// The preset the current rate corresponds to (1000→.au, 1500→.nz, else .custom).
    var derivedPreset: GstRatePreset { Self.preset(forBp: gstRateBp) }
    /// Percent string for the custom field (e.g. 1250 → "12.5").
    var gstRatePercentText: String {
        let pct = Double(gstRateBp) / 100.0
        return pct == pct.rounded() ? String(Int(pct)) : String(pct)
    }

    func setGstRateBp(_ bp: Int) {
        let clamped = max(0, min(10_000, bp))   // 0%..100%
        gstRateBp = clamped
        profile.gstRateBp = clamped
        saveProfile()
    }
    func setGstRatePreset(_ preset: GstRatePreset) {
        gstRatePreset = preset
        switch preset {
        case .au: setGstRateBp(1000)
        case .nz: setGstRateBp(1500)
        case .custom: break   // keep the current rate; the custom field edits it
        }
    }
    /// `12.5` → 1250 bp.
    func setCustomGstPercent(_ percent: Double) {
        gstRatePreset = .custom
        setGstRateBp(Int((percent * 100).rounded()))
    }

    // MARK: - Business + bank details

    private func normalize(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
    func setBusinessEmail(_ s: String) { businessEmail = s; profile.businessEmail = normalize(s); saveProfile() }
    func setPhone(_ s: String) { phone = s; profile.phone = normalize(s); saveProfile() }
    func setWebsite(_ s: String) { website = s; profile.website = normalize(s); saveProfile() }
    func setAddressText(_ s: String) { addressText = s; profile.addressText = normalize(s); saveProfile() }
    func setBankDetails(_ s: String) { bankDetails = s; profile.bankDetails = normalize(s); saveProfile() }

    /// Reduce → upload → store `logoR2Key`. The key is server-owned (synced pull-only);
    /// we set it locally from the upload response so the preview updates immediately.
    func uploadLogo(_ image: UIImage) async {
        logoUploadError = nil
        isUploadingLogo = true
        defer { isUploadingLogo = false }
        let png = ImageReducer().reduce(image)
        do {
            // A freshly-created profile may not have synced yet; the logo route 404s if the
            // profile row isn't in D1. Drain the outbox first so the profile upsert lands
            // server-side before we upload (mirrors the quote send/link flush).
            await sync.flush()
            let r = try await api.uploadProfileLogo(profileId: profile.id, png: png)
            logoR2Key = r.logoR2Key
            profile.logoR2Key = r.logoR2Key
            saveProfile()
            // Show the just-uploaded logo immediately + cache it for next time.
            logoImage = UIImage(data: png) ?? image
            if let url = Self.logoCacheURL(profileId: profile.id) { try? png.write(to: url) }
        } catch let e as APIError {
            logoUploadError = e.message
        } catch {
            logoUploadError = "Couldn’t upload the logo. Try again."
        }
    }

    /// Local cache path for a profile's logo bitmap (Caches dir; safe to be evicted).
    static func logoCacheURL(profileId: String) -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("sc.logo.\(profileId).img")
    }
}
