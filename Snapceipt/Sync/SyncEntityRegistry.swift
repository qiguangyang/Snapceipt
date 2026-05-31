import Foundation
import SwiftData

// MARK: - JSONValue encoding

/// Make the (decode-only) `JSONValue` round-trippable so an outbox payload snapshot
/// can be re-encoded into a `PushMutation.payload` without a per-type Encodable struct.
extension JSONValue: Encodable {
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n):
            // Preserve integers as integers so the backend sees `5`, not `5.0`.
            if n.rounded() == n, abs(n) < 9_007_199_254_740_992 { try c.encode(Int(n)) }
            else { try c.encode(n) }
        case .bool(let b): try c.encode(b)
        case .object(let o): try c.encode(o)
        case .array(let a): try c.encode(a)
        case .null: try c.encodeNil()
        }
    }
}

// MARK: - Registry

/// Single source of truth mapping `EntityType` → row glue + payload codec. Every one
/// of the 12 syncable types is registered so a pulled envelope of any type upserts
/// into the right `@Model` (no silent drop).
final class SyncEntityRegistry {
    @MainActor static let shared = SyncEntityRegistry()

    private var handlers: [EntityType: SyncEntityHandler] = [:]

    init() {
        register(.transaction, TransactionSyncMapper())
        register(.profile, ProfileSyncMapper())
        register(.lineItem, LineItemSyncMapper())
        register(.category, CategorySyncMapper())
        register(.smartRule, SmartRuleSyncMapper())
        register(.budget, BudgetSyncMapper())
        register(.loyaltyCard, LoyaltyCardSyncMapper())
        register(.quote, QuoteSyncMapper())
        register(.quoteLineItem, QuoteLineItemSyncMapper())
        register(.mileageTrip, MileageTripSyncMapper())
        register(.wfhLog, WFHLogSyncMapper())
        register(.taxSettings, TaxSettingsSyncMapper())
        register(.vehicle, VehicleSyncMapper())
        register(.vehicleYear, VehicleYearSyncMapper())
    }

    private func register<M: SyncRowMapper>(_ type: EntityType, _ mapper: M) {
        handlers[type] = SyncEntityHandler(
            applyPulled: { ctx, env in mapper.upsert(ctx, env) },
            localUpdatedAt: { ctx, id in mapper.localUpdatedAt(ctx, id) },
            deleteLocal: { ctx, id in mapper.delete(ctx, id) },
            overwriteLocal: { ctx, env in mapper.upsert(ctx, env) },
            stampServer: { ctx, id, rev, upd in mapper.stamp(ctx, id, rev: rev, updatedAt: upd) },
            encodePayload: { entity in
                guard let row = entity as? M.Model else { return [:] }
                return mapper.payload(row)
            }
        )
    }

    func handler(for type: EntityType) -> SyncEntityHandler? { handlers[type] }

    /// Snapshot a Syncable entity to a JSON object string for the outbox.
    func encodePayload(entityType: EntityType, entity: any Syncable) -> String {
        let fields = handler(for: entityType)?.encodePayload(entity) ?? sharedFields(entity)
        guard let data = try? JSONEncoder().encode(fields) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Decode an outbox payload string back into the wire JSON object for push.
    func decodePayload(_ json: String) -> [String: JSONValue] {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONDecoder().decode([String: JSONValue].self, from: data) else {
            return [:]
        }
        return dict
    }
}

// MARK: - Shared envelope encoding

/// The fixed SPINE sync columns shared by every entity (camelCase, matching the
/// backend `rowToEntity` envelope). Domain fields are merged on top by each mapper.
func sharedFields(_ e: any Syncable) -> [String: JSONValue] {
    var f: [String: JSONValue] = [
        "id": .string(e.id),
        "userId": .string(e.userId),
        "createdAt": .number(Double(e.createdAt)),
        "updatedAt": .number(Double(e.updatedAt)),
        "rev": .number(Double(e.rev)),
    ]
    f["deletedAt"] = e.deletedAt.map { .number(Double($0)) } ?? .null
    f["lastEditedDeviceId"] = e.lastEditedDeviceId.map { .string($0) } ?? .null
    if let pid = e.profileId { f["profileId"] = .string(pid) }
    return f
}

private func str(_ v: String?) -> JSONValue { v.map { .string($0) } ?? .null }
private func num(_ v: Int?) -> JSONValue { v.map { .number(Double($0)) } ?? .null }
private func num(_ v: Int) -> JSONValue { .number(Double(v)) }
private func boolv(_ v: Bool) -> JSONValue { .bool(v) }

// MARK: - Row mapper protocol

/// Strongly-typed mapping between a syncable @Model row and the wire envelope.
protocol SyncRowMapper {
    associatedtype Model: PersistentModel & Syncable
    func upsert(_ context: ModelContext, _ env: PullChange)
    func localUpdatedAt(_ context: ModelContext, _ id: String) -> Int?
    func delete(_ context: ModelContext, _ id: String)
    func stamp(_ context: ModelContext, _ id: String, rev: Int, updatedAt: Int)
    func payload(_ row: Model) -> [String: JSONValue]
}

extension SyncRowMapper {
    func fetch(_ context: ModelContext, _ id: String) -> Model? {
        var d = FetchDescriptor<Model>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return (try? context.fetch(d))?.first
    }

    func localUpdatedAt(_ context: ModelContext, _ id: String) -> Int? { fetch(context, id)?.updatedAt }

    func delete(_ context: ModelContext, _ id: String) {
        if let row = fetch(context, id) { context.delete(row) }
    }

    func stamp(_ context: ModelContext, _ id: String, rev: Int, updatedAt: Int) {
        guard let row = fetch(context, id) as? (any MutableSyncRow) else { return }
        row.setRev(rev); row.setUpdatedAt(updatedAt)
    }
}

/// Lets the generic `stamp` write the two server-stamped fields without a per-type
/// closure. Each @Model that participates in sync conforms via the extensions below.
protocol MutableSyncRow: AnyObject {
    func setRev(_ rev: Int)
    func setUpdatedAt(_ updatedAt: Int)
}

/// Applies the shared SPINE envelope fields onto any @Model conforming row.
private func applySharedEnvelope(_ row: some SyncableMutableEnvelope, _ env: PullChange) {
    row.userId = env.userId
    row.rev = env.rev
    row.createdAt = env.createdAt
    row.updatedAt = env.updatedAt
    row.deletedAt = env.deletedAt
    row.lastEditedDeviceId = env.lastEditedDeviceId
}

/// The mutable SPINE columns every syncable @Model exposes (settable, unlike the
/// read-only `Syncable` protocol used for generic reads).
protocol SyncableMutableEnvelope: AnyObject {
    var userId: String { get set }
    var profileId: String? { get set }
    var rev: Int { get set }
    var createdAt: Int { get set }
    var updatedAt: Int { get set }
    var deletedAt: Int? { get set }
    var lastEditedDeviceId: String? { get set }
}

// MARK: - Transaction

private struct TransactionSyncMapper: SyncRowMapper {
    func upsert(_ context: ModelContext, _ env: PullChange) {
        let row = fetch(context, env.id) ?? {
            let t = Transaction(userId: env.userId, profileId: env.profileId,
                                catKey: env.string("catKey") ?? "custom",
                                amountCents: env.int("amountCents") ?? 0,
                                txnDate: env.string("txnDate") ?? "")
            t.id = env.id
            context.insert(t)
            return t
        }()
        applySharedEnvelope(row, env)
        row.profileId = env.profileId
        if let v = env.string("merchant") { row.merchant = v }
        if let v = env.string("categoryId") { row.categoryId = v }
        if let v = env.string("catKey") { row.catKey = v }
        if let v = env.int("amountCents") { row.amountCents = v }
        if let v = env.string("currency") { row.currency = v }
        if let v = env.string("txnDate") { row.txnDate = v }
        if let v = env.string("mode") { row.mode = v }
        if let v = env.string("taxLabel") { row.taxLabel = v }
        if let v = env.int("deductiblePct") { row.deductiblePct = v }
        if let v = env.string("paymentMethod") { row.paymentMethod = v }
        if let v = env.bool("isAi") { row.isAi = v }
        if let v = env.string("note") { row.note = v }
        if let v = env.int("gstCents") { row.gstCents = v }
        if let v = env.string("logbookLink") { row.logbookLink = v }
        if let v = env.string("mileageTripId") { row.mileageTripId = v }
        if let v = env.string("source") { row.source = v }
        if let v = env.string("extractionStatus") { row.extractionStatus = v }
    }

    func payload(_ r: Transaction) -> [String: JSONValue] {
        var f = sharedFields(r)
        f["merchant"] = .string(r.merchant)
        f["categoryId"] = str(r.categoryId)
        f["catKey"] = .string(r.catKey)
        f["amountCents"] = num(r.amountCents)
        f["currency"] = .string(r.currency)
        f["txnDate"] = .string(r.txnDate)
        f["mode"] = .string(r.mode)
        f["taxLabel"] = str(r.taxLabel)
        f["deductiblePct"] = num(r.deductiblePct)
        f["paymentMethod"] = str(r.paymentMethod)
        f["isAi"] = boolv(r.isAi)
        f["note"] = str(r.note)
        f["gstCents"] = num(r.gstCents)
        f["logbookLink"] = str(r.logbookLink)
        f["mileageTripId"] = str(r.mileageTripId)
        f["source"] = .string(r.source)
        f["extractionStatus"] = str(r.extractionStatus)
        return f
    }
}

extension Transaction: SyncableMutableEnvelope, MutableSyncRow {
    func setRev(_ rev: Int) { self.rev = rev }
    func setUpdatedAt(_ updatedAt: Int) { self.updatedAt = updatedAt }
}

// MARK: - Profile

private struct ProfileSyncMapper: SyncRowMapper {
    func upsert(_ context: ModelContext, _ env: PullChange) {
        // The persona arrives as `profileType` (envelope `type` is the discriminant).
        let persona = env.string("profileType") ?? "personal"
        let row = fetch(context, env.id) ?? {
            let p = Profile(userId: env.userId, name: env.string("name") ?? "", type: persona,
                            accent1: env.string("accent1") ?? "#0E7C72",
                            accent2: env.string("accent2") ?? "#DCF0ED",
                            accent3: env.string("accent3") ?? "#0A5950")
            p.id = env.id
            context.insert(p)
            return p
        }()
        applySharedEnvelope(row, env)
        if let v = env.string("name") { row.name = v }
        if let v = env.string("profileType") { row.type = v }
        if let v = env.string("initials") { row.initials = v }
        if let v = env.string("accent1") { row.accent1 = v }
        if let v = env.string("accent2") { row.accent2 = v }
        if let v = env.string("accent3") { row.accent3 = v }
        if let v = env.string("abn") { row.abn = v }
        if let v = env.bool("gstRegistered") { row.gstRegistered = v }
        if let v = env.int("sortOrder") { row.sortOrder = v }
        if let v = env.bool("isDefault") { row.isDefault = v }
    }

    func payload(_ r: Profile) -> [String: JSONValue] {
        var f = sharedFields(r)
        f["name"] = .string(r.name)
        f["profileType"] = .string(r.type)   // persona -> profiles.type on the server
        f["initials"] = str(r.initials)
        f["accent1"] = .string(r.accent1)
        f["accent2"] = .string(r.accent2)
        f["accent3"] = .string(r.accent3)
        f["abn"] = str(r.abn)
        f["gstRegistered"] = boolv(r.gstRegistered)
        f["sortOrder"] = num(r.sortOrder)
        f["isDefault"] = boolv(r.isDefault)
        return f
    }
}

extension Profile: SyncableMutableEnvelope, MutableSyncRow {
    func setRev(_ rev: Int) { self.rev = rev }
    func setUpdatedAt(_ updatedAt: Int) { self.updatedAt = updatedAt }
}

// MARK: - LineItem

private struct LineItemSyncMapper: SyncRowMapper {
    func upsert(_ context: ModelContext, _ env: PullChange) {
        let row = fetch(context, env.id) ?? {
            let x = LineItem(userId: env.userId, transactionId: env.string("transactionId") ?? "",
                             name: env.string("name") ?? "", priceCents: env.int("priceCents") ?? 0)
            x.id = env.id
            context.insert(x)
            return x
        }()
        applySharedEnvelope(row, env)
        if let v = env.string("transactionId") { row.transactionId = v }
        if let v = env.string("name") { row.name = v }
        if let v = env.int("priceCents") { row.priceCents = v }
        if let v = env.int("quantity") { row.quantity = v }
        if let v = env.int("sortOrder") { row.sortOrder = v }
    }

    func payload(_ r: LineItem) -> [String: JSONValue] {
        var f = sharedFields(r)
        f["transactionId"] = .string(r.transactionId)
        f["name"] = .string(r.name)
        f["priceCents"] = num(r.priceCents)
        f["quantity"] = num(r.quantity)
        f["sortOrder"] = num(r.sortOrder)
        return f
    }
}

extension LineItem: SyncableMutableEnvelope, MutableSyncRow {
    func setRev(_ rev: Int) { self.rev = rev }
    func setUpdatedAt(_ updatedAt: Int) { self.updatedAt = updatedAt }
}

// MARK: - Category

private struct CategorySyncMapper: SyncRowMapper {
    func upsert(_ context: ModelContext, _ env: PullChange) {
        let row = fetch(context, env.id) ?? {
            let x = Category(userId: env.userId, profileId: env.profileId,
                             key: env.string("key") ?? "custom", label: env.string("label") ?? "",
                             icon: env.string("icon") ?? "", tint: env.string("tint") ?? "#000000",
                             soft: env.string("soft") ?? "#FFFFFF")
            x.id = env.id
            context.insert(x)
            return x
        }()
        applySharedEnvelope(row, env)
        row.profileId = env.profileId
        if let v = env.string("key") { row.key = v }
        if let v = env.string("label") { row.label = v }
        if let v = env.string("icon") { row.icon = v }
        if let v = env.string("tint") { row.tint = v }
        if let v = env.string("soft") { row.soft = v }
        if let v = env.int("defaultDeductiblePct") { row.defaultDeductiblePct = v }
        if let v = env.bool("isIncome") { row.isIncome = v }
        if let v = env.int("sortOrder") { row.sortOrder = v }
    }

    func payload(_ r: Category) -> [String: JSONValue] {
        var f = sharedFields(r)
        f["key"] = .string(r.key)
        f["label"] = .string(r.label)
        f["icon"] = .string(r.icon)
        f["tint"] = .string(r.tint)
        f["soft"] = .string(r.soft)
        f["defaultDeductiblePct"] = num(r.defaultDeductiblePct)
        f["isIncome"] = boolv(r.isIncome)
        f["sortOrder"] = num(r.sortOrder)
        return f
    }
}

extension Category: SyncableMutableEnvelope, MutableSyncRow {
    func setRev(_ rev: Int) { self.rev = rev }
    func setUpdatedAt(_ updatedAt: Int) { self.updatedAt = updatedAt }
}

// MARK: - SmartRule

private struct SmartRuleSyncMapper: SyncRowMapper {
    func upsert(_ context: ModelContext, _ env: PullChange) {
        let row = fetch(context, env.id) ?? {
            let x = SmartRule(userId: env.userId, profileId: env.profileId,
                              matchType: env.string("matchType") ?? "merchant_contains",
                              matcher: env.string("matcher") ?? "")
            x.id = env.id
            context.insert(x)
            return x
        }()
        applySharedEnvelope(row, env)
        row.profileId = env.profileId
        if let v = env.string("matchType") { row.matchType = v }
        if let v = env.string("matcher") { row.matcher = v }
        if let v = env.string("categoryId") { row.categoryId = v }
        if let v = env.int("setDeductiblePct") { row.setDeductiblePct = v }
        if let v = env.string("setMode") { row.setMode = v }
        if let v = env.int("priority") { row.priority = v }
        if let v = env.bool("enabled") { row.enabled = v }
    }

    func payload(_ r: SmartRule) -> [String: JSONValue] {
        var f = sharedFields(r)
        f["matchType"] = .string(r.matchType)
        f["matcher"] = .string(r.matcher)
        f["categoryId"] = str(r.categoryId)
        f["setDeductiblePct"] = num(r.setDeductiblePct)
        f["setMode"] = str(r.setMode)
        f["priority"] = num(r.priority)
        f["enabled"] = boolv(r.enabled)
        return f
    }
}

extension SmartRule: SyncableMutableEnvelope, MutableSyncRow {
    func setRev(_ rev: Int) { self.rev = rev }
    func setUpdatedAt(_ updatedAt: Int) { self.updatedAt = updatedAt }
}

// MARK: - Budget

private struct BudgetSyncMapper: SyncRowMapper {
    func upsert(_ context: ModelContext, _ env: PullChange) {
        let row = fetch(context, env.id) ?? {
            let x = Budget(userId: env.userId, profileId: env.profileId,
                           label: env.string("label") ?? "", capCents: env.int("capCents") ?? 0)
            x.id = env.id
            context.insert(x)
            return x
        }()
        applySharedEnvelope(row, env)
        row.profileId = env.profileId
        if let v = env.string("categoryId") { row.categoryId = v }
        if let v = env.string("catKey") { row.catKey = v }
        if let v = env.string("label") { row.label = v }
        if let v = env.string("period") { row.period = v }
        if let v = env.string("monthKey") { row.monthKey = v }
        if let v = env.int("capCents") { row.capCents = v }
        if let v = env.string("currency") { row.currency = v }
        if let v = env.int("alertThresholdPct") { row.alertThresholdPct = v }
        if let v = env.int("alertSentAt") { row.alertSentAt = v }
    }

    func payload(_ r: Budget) -> [String: JSONValue] {
        var f = sharedFields(r)
        f["categoryId"] = str(r.categoryId)
        f["catKey"] = str(r.catKey)
        f["label"] = .string(r.label)
        f["period"] = .string(r.period)
        f["monthKey"] = str(r.monthKey)
        f["capCents"] = num(r.capCents)
        f["currency"] = .string(r.currency)
        f["alertThresholdPct"] = num(r.alertThresholdPct)
        f["alertSentAt"] = num(r.alertSentAt)
        return f
    }
}

extension Budget: SyncableMutableEnvelope, MutableSyncRow {
    func setRev(_ rev: Int) { self.rev = rev }
    func setUpdatedAt(_ updatedAt: Int) { self.updatedAt = updatedAt }
}

// MARK: - LoyaltyCard

private struct LoyaltyCardSyncMapper: SyncRowMapper {
    func upsert(_ context: ModelContext, _ env: PullChange) {
        let row = fetch(context, env.id) ?? {
            let x = LoyaltyCard(userId: env.userId, profileId: env.profileId,
                                brand: env.string("brand") ?? "", number: env.string("number") ?? "",
                                color1: env.string("color1") ?? "#000000",
                                color2: env.string("color2") ?? "#FFFFFF")
            x.id = env.id
            context.insert(x)
            return x
        }()
        applySharedEnvelope(row, env)
        row.profileId = env.profileId
        if let v = env.string("brand") { row.brand = v }
        if let v = env.string("subBrand") { row.subBrand = v }
        if let v = env.string("number") { row.number = v }
        if let v = env.string("barcodeFormat") { row.barcodeFormat = v }
        if let v = env.string("pointsLabel") { row.pointsLabel = v }
        if let v = env.string("color1") { row.color1 = v }
        if let v = env.string("color2") { row.color2 = v }
        if let v = env.int("sortOrder") { row.sortOrder = v }
    }

    func payload(_ r: LoyaltyCard) -> [String: JSONValue] {
        var f = sharedFields(r)
        f["brand"] = .string(r.brand)
        f["subBrand"] = str(r.subBrand)
        f["number"] = .string(r.number)
        f["barcodeFormat"] = str(r.barcodeFormat)
        f["pointsLabel"] = str(r.pointsLabel)
        f["color1"] = .string(r.color1)
        f["color2"] = .string(r.color2)
        f["sortOrder"] = num(r.sortOrder)
        return f
    }
}

extension LoyaltyCard: SyncableMutableEnvelope, MutableSyncRow {
    func setRev(_ rev: Int) { self.rev = rev }
    func setUpdatedAt(_ updatedAt: Int) { self.updatedAt = updatedAt }
}

// MARK: - Quote

private struct QuoteSyncMapper: SyncRowMapper {
    func upsert(_ context: ModelContext, _ env: PullChange) {
        let row = fetch(context, env.id) ?? {
            let x = Quote(userId: env.userId, profileId: env.profileId)
            x.id = env.id
            context.insert(x)
            return x
        }()
        applySharedEnvelope(row, env)
        row.profileId = env.profileId
        if let v = env.string("number") { row.number = v }
        if let v = env.string("clientName") { row.clientName = v }
        if let v = env.string("clientEmail") { row.clientEmail = v }
        if let v = env.bool("gstEnabled") { row.gstEnabled = v }
        if let v = env.int("subtotalCents") { row.subtotalCents = v }
        if let v = env.int("gstCents") { row.gstCents = v }
        if let v = env.int("totalCents") { row.totalCents = v }
        if let v = env.string("currency") { row.currency = v }
        if let v = env.string("status") { row.status = v }
        if let v = env.string("validUntil") { row.validUntil = v }
        if let v = env.int("sentAt") { row.sentAt = v }
    }

    func payload(_ r: Quote) -> [String: JSONValue] {
        var f = sharedFields(r)
        f["number"] = str(r.number)
        f["clientName"] = str(r.clientName)
        f["clientEmail"] = str(r.clientEmail)
        f["gstEnabled"] = boolv(r.gstEnabled)
        f["subtotalCents"] = num(r.subtotalCents)
        f["gstCents"] = num(r.gstCents)
        f["totalCents"] = num(r.totalCents)
        f["currency"] = .string(r.currency)
        f["status"] = .string(r.status)
        f["validUntil"] = str(r.validUntil)
        f["sentAt"] = num(r.sentAt)
        return f
    }
}

extension Quote: SyncableMutableEnvelope, MutableSyncRow {
    func setRev(_ rev: Int) { self.rev = rev }
    func setUpdatedAt(_ updatedAt: Int) { self.updatedAt = updatedAt }
}

// MARK: - QuoteLineItem

private struct QuoteLineItemSyncMapper: SyncRowMapper {
    func upsert(_ context: ModelContext, _ env: PullChange) {
        let row = fetch(context, env.id) ?? {
            let x = QuoteLineItem(userId: env.userId, quoteId: env.string("quoteId") ?? "",
                                  // backend column is "description"
                                  itemDescription: env.string("description") ?? "",
                                  unitPriceCents: env.int("unitPriceCents") ?? 0)
            x.id = env.id
            context.insert(x)
            return x
        }()
        applySharedEnvelope(row, env)
        if let v = env.string("quoteId") { row.quoteId = v }
        if let v = env.string("description") { row.itemDescription = v }
        if let v = env.int("quantity") { row.quantity = v }
        if let v = env.int("unitPriceCents") { row.unitPriceCents = v }
        if let v = env.int("sortOrder") { row.sortOrder = v }
    }

    func payload(_ r: QuoteLineItem) -> [String: JSONValue] {
        var f = sharedFields(r)
        f["quoteId"] = .string(r.quoteId)
        f["description"] = .string(r.itemDescription)   // maps to backend "description"
        f["quantity"] = num(r.quantity)
        f["unitPriceCents"] = num(r.unitPriceCents)
        f["sortOrder"] = num(r.sortOrder)
        return f
    }
}

extension QuoteLineItem: SyncableMutableEnvelope, MutableSyncRow {
    func setRev(_ rev: Int) { self.rev = rev }
    func setUpdatedAt(_ updatedAt: Int) { self.updatedAt = updatedAt }
}

// MARK: - MileageTrip

private struct MileageTripSyncMapper: SyncRowMapper {
    func upsert(_ context: ModelContext, _ env: PullChange) {
        let row = fetch(context, env.id) ?? {
            let x = MileageTrip(userId: env.userId, profileId: env.profileId,
                                tripDate: env.string("tripDate") ?? "", distanceM: env.int("distanceM") ?? 0)
            x.id = env.id
            context.insert(x)
            return x
        }()
        applySharedEnvelope(row, env)
        row.profileId = env.profileId
        if let v = env.string("tripDate") { row.tripDate = v }
        if let v = env.string("fromLabel") { row.fromLabel = v }
        if let v = env.string("toLabel") { row.toLabel = v }
        if let v = env.string("purpose") { row.purpose = v }
        if let v = env.int("distanceM") { row.distanceM = v }
        if let v = env.bool("isBusiness") { row.isBusiness = v }
        if let v = env.int("rateCentsPerKm") { row.rateCentsPerKm = v }
        if let v = env.int("claimCents") { row.claimCents = v }
        if let v = env.bool("autoTracked") { row.autoTracked = v }
        if let v = env.string("vehicleId") { row.vehicleId = v }
        if let v = env.int("odometerStartM") { row.odometerStartM = v }
        if let v = env.int("odometerEndM") { row.odometerEndM = v }
    }

    func payload(_ r: MileageTrip) -> [String: JSONValue] {
        var f = sharedFields(r)
        f["tripDate"] = .string(r.tripDate)
        f["fromLabel"] = str(r.fromLabel)
        f["toLabel"] = str(r.toLabel)
        f["purpose"] = str(r.purpose)
        f["distanceM"] = num(r.distanceM)
        f["isBusiness"] = boolv(r.isBusiness)
        f["rateCentsPerKm"] = num(r.rateCentsPerKm)
        f["claimCents"] = num(r.claimCents)
        f["autoTracked"] = boolv(r.autoTracked)
        f["vehicleId"] = str(r.vehicleId)
        f["odometerStartM"] = num(r.odometerStartM)
        f["odometerEndM"] = num(r.odometerEndM)
        return f
    }
}

extension MileageTrip: SyncableMutableEnvelope, MutableSyncRow {
    func setRev(_ rev: Int) { self.rev = rev }
    func setUpdatedAt(_ updatedAt: Int) { self.updatedAt = updatedAt }
}

// MARK: - WFHLog

private struct WFHLogSyncMapper: SyncRowMapper {
    func upsert(_ context: ModelContext, _ env: PullChange) {
        let row = fetch(context, env.id) ?? {
            let x = WFHLog(userId: env.userId, profileId: env.profileId,
                           logDate: env.string("logDate") ?? "", minutes: env.int("minutes") ?? 0)
            x.id = env.id
            context.insert(x)
            return x
        }()
        applySharedEnvelope(row, env)
        row.profileId = env.profileId
        if let v = env.string("logDate") { row.logDate = v }
        if let v = env.int("minutes") { row.minutes = v }
        if let v = env.string("note") { row.note = v }
        if let v = env.int("rateCentsPerHour") { row.rateCentsPerHour = v }
        if let v = env.int("claimCents") { row.claimCents = v }
    }

    func payload(_ r: WFHLog) -> [String: JSONValue] {
        var f = sharedFields(r)
        f["logDate"] = .string(r.logDate)
        f["minutes"] = num(r.minutes)
        f["note"] = str(r.note)
        f["rateCentsPerHour"] = num(r.rateCentsPerHour)
        f["claimCents"] = num(r.claimCents)
        return f
    }
}

extension WFHLog: SyncableMutableEnvelope, MutableSyncRow {
    func setRev(_ rev: Int) { self.rev = rev }
    func setUpdatedAt(_ updatedAt: Int) { self.updatedAt = updatedAt }
}

// MARK: - TaxSettings

private struct TaxSettingsSyncMapper: SyncRowMapper {
    func upsert(_ context: ModelContext, _ env: PullChange) {
        let row = fetch(context, env.id) ?? {
            let x = TaxSettings(userId: env.userId, profileId: env.profileId)
            x.id = env.id
            context.insert(x)
            return x
        }()
        applySharedEnvelope(row, env)
        row.profileId = env.profileId
        if let v = env.int("gstRateBps") { row.gstRateBps = v }
        if let v = env.int("financialYearStartMonth") { row.financialYearStartMonth = v }
        if let v = env.int("mealsDeductiblePct") { row.mealsDeductiblePct = v }
        if let v = env.int("wfhRateCentsPerHour") { row.wfhRateCentsPerHour = v }
        if let v = env.int("mileageRateCentsPerKm") { row.mileageRateCentsPerKm = v }
    }

    func payload(_ r: TaxSettings) -> [String: JSONValue] {
        var f = sharedFields(r)
        f["gstRateBps"] = num(r.gstRateBps)
        f["financialYearStartMonth"] = num(r.financialYearStartMonth)
        f["mealsDeductiblePct"] = num(r.mealsDeductiblePct)
        f["wfhRateCentsPerHour"] = num(r.wfhRateCentsPerHour)
        f["mileageRateCentsPerKm"] = num(r.mileageRateCentsPerKm)
        return f
    }
}

extension TaxSettings: SyncableMutableEnvelope, MutableSyncRow {
    func setRev(_ rev: Int) { self.rev = rev }
    func setUpdatedAt(_ updatedAt: Int) { self.updatedAt = updatedAt }
}

// MARK: - Vehicle

private struct VehicleSyncMapper: SyncRowMapper {
    func upsert(_ context: ModelContext, _ env: PullChange) {
        let row = fetch(context, env.id) ?? {
            let x = Vehicle(userId: env.userId, profileId: env.profileId)
            x.id = env.id
            context.insert(x)
            return x
        }()
        applySharedEnvelope(row, env)
        row.profileId = env.profileId
        if let v = env.string("make") { row.make = v }
        if let v = env.string("model") { row.model = v }
        if let v = env.int("engineCc") { row.engineCc = v }
        if let v = env.string("registration") { row.registration = v }
        if let v = env.string("logbookStartDate") { row.logbookStartDate = v }
        if let v = env.string("logbookEndDate") { row.logbookEndDate = v }
        if let v = env.int("businessUsePct") { row.businessUsePct = v }
    }

    func payload(_ r: Vehicle) -> [String: JSONValue] {
        var f = sharedFields(r)
        f["make"] = str(r.make)
        f["model"] = str(r.model)
        f["engineCc"] = num(r.engineCc)
        f["registration"] = str(r.registration)
        f["logbookStartDate"] = str(r.logbookStartDate)
        f["logbookEndDate"] = str(r.logbookEndDate)
        f["businessUsePct"] = num(r.businessUsePct)
        return f
    }
}

extension Vehicle: SyncableMutableEnvelope, MutableSyncRow {
    func setRev(_ rev: Int) { self.rev = rev }
    func setUpdatedAt(_ updatedAt: Int) { self.updatedAt = updatedAt }
}

// MARK: - VehicleYear

private struct VehicleYearSyncMapper: SyncRowMapper {
    func upsert(_ context: ModelContext, _ env: PullChange) {
        let row = fetch(context, env.id) ?? {
            let x = VehicleYear(userId: env.userId, profileId: env.profileId,
                                vehicleId: env.string("vehicleId") ?? "",
                                fyStartYear: env.int("fyStartYear") ?? 0)
            x.id = env.id
            context.insert(x)
            return x
        }()
        applySharedEnvelope(row, env)
        row.profileId = env.profileId
        if let v = env.string("vehicleId") { row.vehicleId = v }
        if let v = env.int("fyStartYear") { row.fyStartYear = v }
        if let v = env.int("odometerOpenM") { row.odometerOpenM = v }
        if let v = env.int("odometerCloseM") { row.odometerCloseM = v }
        if let v = env.int("fuelCents") { row.fuelCents = v }
        if let v = env.int("regoCents") { row.regoCents = v }
        if let v = env.int("insuranceCents") { row.insuranceCents = v }
        if let v = env.int("servicingCents") { row.servicingCents = v }
        if let v = env.int("otherCents") { row.otherCents = v }
        if let v = env.int("depreciationCents") { row.depreciationCents = v }
        if let v = env.int("businessUsePct") { row.businessUsePct = v }
        if let v = env.int("claimCents") { row.claimCents = v }
    }

    func payload(_ r: VehicleYear) -> [String: JSONValue] {
        var f = sharedFields(r)
        f["vehicleId"] = .string(r.vehicleId)
        f["fyStartYear"] = num(r.fyStartYear)
        f["odometerOpenM"] = num(r.odometerOpenM)
        f["odometerCloseM"] = num(r.odometerCloseM)
        f["fuelCents"] = num(r.fuelCents)
        f["regoCents"] = num(r.regoCents)
        f["insuranceCents"] = num(r.insuranceCents)
        f["servicingCents"] = num(r.servicingCents)
        f["otherCents"] = num(r.otherCents)
        f["depreciationCents"] = num(r.depreciationCents)
        f["businessUsePct"] = num(r.businessUsePct)
        f["claimCents"] = num(r.claimCents)
        return f
    }
}

extension VehicleYear: SyncableMutableEnvelope, MutableSyncRow {
    func setRev(_ rev: Int) { self.rev = rev }
    func setUpdatedAt(_ updatedAt: Int) { self.updatedAt = updatedAt }
}
