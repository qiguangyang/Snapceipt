import Foundation
import SwiftData

/// Edits the active profile's tax_settings (+ the Profile's ABN/GST identity).
/// `@MainActor`; deps injected. Lazily ensures a tax_settings row exists.
@Observable
@MainActor
final class TaxSettingsViewModel {
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let sync: any SyncEnqueuing
    @ObservationIgnored private let userId: String
    @ObservationIgnored private let profile: Profile
    @ObservationIgnored private var settings: TaxSettings

    var showsBusinessIdentity: Bool { profile.type == "business" }

    // Mirrored editable state (read from the row at init).
    private(set) var mealsDeductiblePct: Int
    private(set) var wfhRateCentsPerHour: Int
    private(set) var financialYearStartMonth: Int
    private(set) var gstRegistered: Bool
    private(set) var abn: String

    // Local-only prefs (no column): entity type, GST basis, BAS period, vehicle method.
    var entityType: String { didSet { defaults.set(entityType, forKey: key("entityType")) } }
    var gstBasis: String { didSet { defaults.set(gstBasis, forKey: key("gstBasis")) } }
    var basPeriodRaw: String { didSet { defaults.set(basPeriodRaw, forKey: key("basPeriod")) } }

    @ObservationIgnored private let defaults: UserDefaults
    private func key(_ k: String) -> String { "sc.tax.\(profile.id).\(k)" }

    var basPeriod: BasPeriod { BasPeriod(rawValue: basPeriodRaw) ?? .quarterly }
    var nextBasDue: Date { BasSchedule.nextDue(basPeriod, on: Date()) }

    init(context: ModelContext, sync: any SyncEnqueuing, userId: String, profile: Profile,
         defaults: UserDefaults = .standard) {
        self.context = context
        self.sync = sync
        self.userId = userId
        self.profile = profile
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
}
