import Foundation
import SwiftData
import Observation

/// Drives the Mileage screen: owns the active profile's single Vehicle, its trips,
/// and the current-FY VehicleYear. Recomputes + caches `vehicle.businessUsePct` and
/// the VehicleYear claim. `@MainActor`; deps injected for tests. (v1 = one vehicle.)
@Observable
@MainActor
final class MileageViewModel {
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let sync: any SyncEnqueuing
    @ObservationIgnored private let userId: String
    @ObservationIgnored let profileId: String
    @ObservationIgnored private let startMonth: Int

    private(set) var vehicle: Vehicle?
    private(set) var trips: [MileageTrip] = []

    /// ~12 weeks = 84 days.
    private static let logbookDays = 84

    init(context: ModelContext, sync: any SyncEnqueuing, userId: String,
         profileId: String, startMonth: Int) {
        self.context = context
        self.sync = sync
        self.userId = userId
        self.profileId = profileId
        self.startMonth = startMonth
        reload()
    }

    func reload() {
        let pid = profileId
        var vd = FetchDescriptor<Vehicle>(
            predicate: #Predicate { $0.profileId == pid && $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.createdAt)])
        vd.fetchLimit = 1
        vehicle = (try? context.fetch(vd))?.first

        let td = FetchDescriptor<MileageTrip>(
            predicate: #Predicate { $0.profileId == pid && $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.tripDate, order: .reverse)])
        trips = (try? context.fetch(td)) ?? []
    }

    // MARK: hero

    private func calcTrips() -> [MileageCalc.Trip] {
        trips.map { MileageCalc.Trip(tripDate: $0.tripDate, distanceM: $0.distanceM, isBusiness: $0.isBusiness) }
    }

    func hero(fyStartYear: Int) -> MileageCalc.Hero {
        MileageCalc.hero(trips: calcTrips(), fyStartYear: fyStartYear, startMonth: startMonth)
    }

    /// Cached current-FY claim, or nil when no vehicle / no business-use %.
    func currentClaimCents(fyStartYear: Int) -> Int? {
        guard vehicle?.businessUsePct != nil else { return nil }
        return vehicleYear(fyStartYear: fyStartYear)?.claimCents
    }

    // MARK: vehicle

    func saveVehicle(make: String?, model: String?, engineCc: Int?, registration: String?) {
        let v: Vehicle
        if let existing = vehicle {
            v = existing
            v.make = make; v.model = model; v.engineCc = engineCc; v.registration = registration
            v.updatedAt = Epoch.nowMs()
        } else {
            v = Vehicle(userId: userId, profileId: profileId, make: make, model: model,
                        engineCc: engineCc, registration: registration)
            context.insert(v)
        }
        try? context.save()
        vehicle = v
        sync.enqueue(op: "upsert", entityType: .vehicle, entity: v)
    }

    /// Start (or move) the 12-week logbook window; end auto-derived, editable.
    func startLogbook(startDate: String, endDate: String? = nil) {
        guard let v = vehicle else { return }
        v.logbookStartDate = startDate
        v.logbookEndDate = endDate ?? Self.autoEnd(from: startDate)
        v.updatedAt = Epoch.nowMs()
        try? context.save()
        recomputeBusinessUsePct()
    }

    /// start + 84 days as "yyyy-MM-dd" (UTC), or the input unchanged if unparsable.
    static func autoEnd(from startDate: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        guard let start = f.date(from: startDate) else { return startDate }
        let end = start.addingTimeInterval(Double(logbookDays) * 86_400)
        return f.string(from: end)
    }

    // MARK: trips

    func addTrip(date: String, odometerStartM: Int?, odometerEndM: Int?,
                 isBusiness: Bool, purpose: String?, fromLabel: String?, toLabel: String?) {
        let distance = MileageCalc.distanceM(startM: odometerStartM, endM: odometerEndM) ?? 0
        let t = MileageTrip(userId: userId, profileId: profileId, tripDate: date,
                            fromLabel: fromLabel, toLabel: toLabel, purpose: purpose,
                            distanceM: distance, isBusiness: isBusiness,
                            vehicleId: vehicle?.id, odometerStartM: odometerStartM,
                            odometerEndM: odometerEndM)
        context.insert(t)
        try? context.save()
        reload()
        sync.enqueue(op: "upsert", entityType: .mileageTrip, entity: t)
        recomputeBusinessUsePct()
    }

    /// Recompute + cache `vehicle.businessUsePct` from in-window trips, persist + enqueue.
    private func recomputeBusinessUsePct() {
        guard let v = vehicle, let start = v.logbookStartDate, let end = v.logbookEndDate else { return }
        let pct = MileageCalc.businessUsePct(trips: calcTrips(), start: start, end: end)
        v.businessUsePct = pct
        v.updatedAt = Epoch.nowMs()
        try? context.save()
        sync.enqueue(op: "upsert", entityType: .vehicle, entity: v)
    }

    // MARK: costs / vehicle_year

    func vehicleYear(fyStartYear: Int) -> VehicleYear? {
        guard let vid = vehicle?.id else { return nil }
        let pid = profileId
        var d = FetchDescriptor<VehicleYear>(
            predicate: #Predicate {
                $0.profileId == pid && $0.vehicleId == vid
                    && $0.fyStartYear == fyStartYear && $0.deletedAt == nil
            })
        d.fetchLimit = 1
        return (try? context.fetch(d))?.first
    }

    func saveCosts(fyStartYear: Int, fuelCents: Int, regoCents: Int, insuranceCents: Int,
                   servicingCents: Int, otherCents: Int, depreciationCents: Int) {
        guard let v = vehicle else { return }
        let costs = MileageCalc.Costs(fuelCents: fuelCents, regoCents: regoCents,
                                      insuranceCents: insuranceCents, servicingCents: servicingCents,
                                      otherCents: otherCents, depreciationCents: depreciationCents)
        let pct = v.businessUsePct
        let claim = pct.map { MileageCalc.claimCents(businessUsePct: $0, costs: costs) }

        let vy: VehicleYear
        if let existing = vehicleYear(fyStartYear: fyStartYear) {
            vy = existing
        } else {
            vy = VehicleYear(userId: userId, profileId: profileId, vehicleId: v.id, fyStartYear: fyStartYear)
            context.insert(vy)
        }
        vy.fuelCents = fuelCents; vy.regoCents = regoCents; vy.insuranceCents = insuranceCents
        vy.servicingCents = servicingCents; vy.otherCents = otherCents; vy.depreciationCents = depreciationCents
        vy.businessUsePct = pct
        vy.claimCents = claim
        vy.updatedAt = Epoch.nowMs()
        try? context.save()
        sync.enqueue(op: "upsert", entityType: .vehicleYear, entity: vy)
    }
}
