import Foundation

/// POST a signed StoreKit transaction to `/me/subscription`, retrying transient failures (5xx /
/// transport); gives up immediately on a 4xx (auth / validation / bundle / product — a retry won't
/// help). Returns whether the backend recorded it. Used for BOTH a fresh purchase and the launch
/// reconciliation that re-sends an existing entitlement the backend hasn't seen (the cause of the
/// "thinks Pro locally but server stayed free" mismatch).
@discardableResult
func recordPurchaseWithRetry(api: any APIClient, jws: String, attempts: Int = 3) async -> Bool {
    for attempt in 1...attempts {
        do {
            try await api.recordPurchase(signedTransaction: jws)
            return true
        } catch let e as APIError where (400..<500).contains(e.status) {
            return false   // client error — a retry won't help
        } catch {
            if attempt < attempts { try? await Task.sleep(for: .seconds(Double(attempt) * 1.5)) }
        }
    }
    return false
}
