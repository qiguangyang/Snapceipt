import Foundation

/// The 15 syncable entity types. Raw values are the camelCase strings the
/// backend `SYNCABLE_TABLES` keys + `PushMutation.entityType` use verbatim.
enum EntityType: String, CaseIterable, Codable, Sendable {
    case transaction
    case lineItem
    case profile
    case category
    case smartRule
    case budget
    case loyaltyCard
    case quote
    case quoteLineItem
    case mileageTrip
    case wfhLog
    case taxSettings
    case vehicle
    case vehicleYear
    case client
}
