import Foundation

/// Catalog prices are exclusive cents. Document totals remain owned by the totals engines.
enum CatalogPrice {
    enum ValidationError: LocalizedError {
        case invalidPrice, invalidRate, overflow
        var errorDescription: String? {
            switch self {
            case .invalidPrice: "Price must be between zero and 10,000,000.00."
            case .invalidRate: "Tax rate must be between zero and 100 percent."
            case .overflow: "This price is too large."
            }
        }
    }

    static func enteredCents(exclusiveCents: Int, gstEnabled: Bool, gstInclusive: Bool, rateBp: Int) throws -> Int {
        guard (0...1_000_000_000).contains(exclusiveCents) else { throw ValidationError.invalidPrice }
        guard (0...10_000).contains(rateBp) else { throw ValidationError.invalidRate }
        guard gstEnabled && gstInclusive else { return exclusiveCents }
        let (factor, factorOverflow) = 10_000.addingReportingOverflow(rateBp)
        let (product, productOverflow) = exclusiveCents.multipliedReportingOverflow(by: factor)
        let (rounded, roundingOverflow) = product.addingReportingOverflow(5_000)
        guard !factorOverflow && !productOverflow && !roundingOverflow else { throw ValidationError.overflow }
        return rounded / 10_000
    }
}
