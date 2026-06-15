import Foundation
import StoreKit

/// Disambiguates `StoreKit.Transaction` from the app's `Transaction` SwiftData model.
private typealias SKTransaction = StoreKit.Transaction

/// StoreKit 2 boundary: loads the two Pro products, runs purchase/restore, and
/// listens for Transaction.updates. The pure mapping seams (product ids, purchase
/// outcome) are static so they're unit-testable without touching StoreKit I/O.
@MainActor
@Observable
final class StoreKitService {
    enum ProductID {
        static let monthly = "app.snapceipt.pro.monthly"
        static let yearly  = "app.snapceipt.pro.yearly"
        static let all: [String] = [monthly, yearly]
    }

    /// Stable, testable outcome of a purchase/restore attempt.
    enum PurchaseOutcome: Equatable {
        case success
        case pending        // Ask-to-buy / SCA — entitlement arrives later via updates.
        case userCancelled
        case failed
        var entitled: Bool { self == .success }
    }

    /// True iff the product id is one of our entitling Pro subscriptions.
    static func isProProduct(_ id: String) -> Bool { ProductID.all.contains(id) }

    /// Loaded products; empty until `loadProducts()` resolves.
    private(set) var products: [Product] = []
    /// The set of currently-entitled product ids derived from Transaction.currentEntitlements.
    private(set) var entitledProductIDs: Set<String> = []

    /// Called whenever entitlement changes (purchase, restore, expiry, refund) so
    /// the EntitlementStore can sync to the backend. Injected by the app shell.
    var onEntitlementChange: (@MainActor (Bool) -> Void)?

    /// Called when a transaction is verified — provides the StoreKit 2 signed
    /// transaction JWS (`Transaction.jwsRepresentation`) so the app shell can POST
    /// it to /me/subscription, where the backend VERIFIES Apple's signature/cert
    /// chain and derives originalTransactionId/expiry/productId from the verified
    /// payload (never from client-asserted fields).
    var onVerifiedTransaction: (@MainActor (String) -> Void)?

    @ObservationIgnored private var updatesTask: Task<Void, Never>?

    init() {
        // Listen for out-of-band transaction updates (renewals, Ask-to-Buy approvals,
        // refunds) for the whole app lifetime.
        updatesTask = Task.detached { [weak self] in
            for await update in SKTransaction.updates {
                // Finish the verified transaction and notify the app shell.
                if case .verified(let skTxn) = update {
                    // jwsRepresentation lives on the signed VerificationResult envelope.
                    let jws = update.jwsRepresentation
                    await skTxn.finish()
                    await self?.notifyVerified(signedTransaction: jws)
                    await self?.refreshEntitlements()
                }
            }
        }
    }

    deinit { updatesTask?.cancel() }

    /// Load both Pro products from the store (or the .storekit config in DEBUG).
    func loadProducts() async {
        do { products = try await Product.products(for: ProductID.all) }
        catch { products = [] }
    }

    /// Buy a product. Maps the StoreKit result to our stable PurchaseOutcome.
    func purchase(_ product: Product) async -> PurchaseOutcome {
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                guard case .verified(let skTxn) = verification else {
                    // The transaction came back unverified (tampered or JWS failure).
                    // Do NOT report success — the paywall must not dismiss.
                    return .failed
                }
                // jwsRepresentation lives on the signed VerificationResult envelope.
                let jws = verification.jwsRepresentation
                await skTxn.finish()
                notifyVerified(signedTransaction: jws)
                await refreshEntitlements()
                return .success
            case .pending:
                return .pending
            case .userCancelled:
                return .userCancelled
            @unknown default:
                return .failed
            }
        } catch {
            return .failed
        }
    }

    /// Restore: re-sync entitlements from current transactions.
    func restore() async {
        try? await AppStore.sync()
        await refreshEntitlements()
    }

    /// Recompute entitledProductIDs from Transaction.currentEntitlements and notify.
    func refreshEntitlements() async {
        var ids: Set<String> = []
        for await result in SKTransaction.currentEntitlements {
            if case .verified(let txn) = result, Self.isProProduct(txn.productID) {
                ids.insert(txn.productID)
            }
        }
        entitledProductIDs = ids
        onEntitlementChange?(!ids.isEmpty)
    }

    @MainActor
    private func notifyVerified(signedTransaction: String) {
        onVerifiedTransaction?(signedTransaction)
    }
}
