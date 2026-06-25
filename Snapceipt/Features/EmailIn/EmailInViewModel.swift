import Foundation
import SwiftData

/// Drives the Email-in surface. The inbox list is local-first (email_in
/// transactions that sync down); only the address card needs the network.
/// `@MainActor`; deps injected for tests. Mirrors QuoteListViewModel.
@Observable
@MainActor
final class EmailInViewModel {
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let sync: any SyncEnqueuing
    @ObservationIgnored private let api: any APIClient
    @ObservationIgnored private let userId: String
    @ObservationIgnored let profileId: String

    /// email_in transactions for the active profile — failed first, then newest date.
    private(set) var inbox: [Transaction] = []
    private(set) var address: InboxAddressResponse?
    private(set) var isLoadingAddress = false
    /// True when the SERVER returned 403 for the Pro-gated inbox endpoint — i.e. this account is
    /// not Pro server-side even though the local entitlement (e.g. a sandbox/unsynced purchase)
    /// made the UI think it was. The view shows the upgrade/restore card instead of a dead address
    /// card. Distinct from `errorMessage` (a transient/network failure that should offer Retry).
    private(set) var proRequired = false
    var errorMessage: String?

    init(context: ModelContext, sync: any SyncEnqueuing, api: any APIClient, userId: String, profileId: String) {
        self.context = context
        self.sync = sync
        self.api = api
        self.userId = userId
        self.profileId = profileId
        reload()
    }

    func reload() {
        let pid = profileId
        let d = FetchDescriptor<Transaction>(
            predicate: #Predicate { $0.profileId == pid && $0.source == "email_in" && $0.deletedAt == nil })
        let rows = (try? context.fetch(d)) ?? []
        inbox = rows.sorted { a, b in
            let aFailed = a.extractionStatus == "failed"
            let bFailed = b.extractionStatus == "failed"
            if aFailed != bFailed { return aFailed }    // failed rows first
            return a.txnDate > b.txnDate                // then newest by date
        }
    }

    func loadAddress() async {
        isLoadingAddress = true
        errorMessage = nil
        proRequired = false
        defer { isLoadingAddress = false }
        do {
            address = try await api.profileInbox(profileId: profileId)
        } catch let e as APIError where e.code == "FORBIDDEN" {
            // Server doesn't consider this account Pro (the local entitlement never synced, e.g. a
            // sandbox purchase). Show the upgrade/restore card, not a broken address card.
            proRequired = true
        } catch {
            errorMessage = "Couldn't load your inbox address."
        }
    }

    /// Email-in is Pro-only; the alias endpoint now 403s for free users. Skip the
    /// doomed call for non-entitled users (otherwise `loadAddress` would surface an
    /// `errorMessage`). The view shows a Pro upgrade card instead.
    func loadAddressIfPro(isPro: Bool) async {
        guard isPro else { return }
        await loadAddress()
    }

    func rotate() async {
        errorMessage = nil
        do {
            address = try await api.rotateProfileInbox(profileId: profileId)
        } catch {
            errorMessage = "Couldn't rotate the address."
        }
    }
}
