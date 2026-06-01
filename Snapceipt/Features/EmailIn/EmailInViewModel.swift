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
        defer { isLoadingAddress = false }
        do {
            address = try await api.profileInbox(profileId: profileId)
        } catch {
            errorMessage = "Couldn't load your inbox address."
        }
    }

    func rotate() async {
        errorMessage = nil
        do {
            address = try await api.rotateProfileInbox(profileId: profileId)
        } catch {
            errorMessage = "Couldn't rotate the address."
        }
    }

    /// Apply review edits, flip failed->done, sign the amount per category, and
    /// enqueue an upsert. `amountCentsAbs` is the positive magnitude from the editor.
    func save(_ txn: Transaction, merchant: String, amountCentsAbs: Int, txnDate: String, catKey: String) {
        let sign = catKey == "income" ? 1 : -1
        txn.merchant = merchant
        txn.amountCents = sign * abs(amountCentsAbs)
        txn.txnDate = txnDate
        txn.catKey = catKey
        if txn.extractionStatus == "failed" { txn.extractionStatus = "done" }
        txn.updatedAt = Epoch.nowMs()
        try? context.save()
        reload()
        sync.enqueue(op: "upsert", entityType: .transaction, entity: txn)
    }
}
