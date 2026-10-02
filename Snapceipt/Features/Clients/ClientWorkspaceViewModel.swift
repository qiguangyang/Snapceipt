import Foundation
import Observation
import SwiftData

@Observable @MainActor
final class ClientWorkspaceViewModel {
    enum Presentation: Identifiable, Equatable {
        case client(String?), followUp(String?), link, catalog, quote(String), invoice(String)
        var id: String {
            switch self {
            case .client(let id): "client-\(id ?? "new")"
            case .followUp(let id): "followUp-\(id ?? "new")"
            case .link: "link"
            case .catalog: "catalog"
            case .quote(let id): "quote-\(id)"
            case .invoice(let id): "invoice-\(id)"
            }
        }
        var isDocument: Bool { switch self { case .quote, .invoice: true; default: false } }
    }
    let clientStore: ClientStore
    let followUpStore: ClientFollowUpStore
    @ObservationIgnored private let repeatService: RepeatWorkService
    @ObservationIgnored private let context: ModelContext
    let userId: String
    let profileId: String
    var selectedClientId: String?
    var search = ""
    var showFollowUps = false
    var presentation: Presentation? { didSet { presentationGeneration += 1 } }
    private(set) var presentationGeneration = 0
    private var priceReviewIds: Set<String> = []
    private(set) var clients: [Client] = []
    private(set) var followUps: [ClientFollowUp] = []
    private(set) var history = ClientHistory.Snapshot(documents: [], outstandingCents: 0)
    var errorMessage: String?

    init(context: ModelContext, sync: any SyncEnqueuing, userId: String, profileId: String, initialClientId: String? = nil) {
        self.context = context; self.userId = userId; self.profileId = profileId
        clientStore = ClientStore(context: context, sync: sync, userId: userId, profileId: profileId)
        followUpStore = ClientFollowUpStore(context: context, sync: sync, userId: userId, profileId: profileId)
        repeatService = RepeatWorkService(context: context, sync: sync, userId: userId, profileId: profileId)
        selectedClientId = initialClientId
        reload()
    }
    static func isAvailable(profileType: String?) -> Bool { profileType == "business" }
    var selectedClient: Client? { clients.first { $0.id == selectedClientId } }
    var filteredClients: [Client] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? clients : clients.filter {
            [$0.name, $0.email ?? "", $0.mobilePhone ?? ""].contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }
    var openFollowUps: [ClientFollowUp] {
        let live = Set(filteredClients.map(\.id))
        return followUps.filter { $0.completedAt == nil && live.contains($0.clientId) }
    }
    var dueCount: Int { followUps.filter { $0.completedAt == nil && $0.dueAt <= Epoch.nowMs() }.count }
    func select(_ id: String) { selectedClientId = id; reload() }
    func reload() {
        do {
            clients = try clientStore.list(search: "")
            let live = Set(clients.map(\.id))
            followUps = try followUpStore.list(clientId: nil, includeCompleted: true).filter { live.contains($0.clientId) }
            if let id = selectedClientId, live.contains(id) {
                history = try ClientHistory.load(context: context, userId: userId, profileId: profileId, clientId: id,
                    today: RepeatWorkService.documentDate(now: Date(), addingDays: 0))
            } else { selectedClientId = nil; history = .init(documents: [], outstandingCents: 0) }
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }
    func closePresentation() { presentation = nil; reload() }
    func finishPresentation(_ expected: Presentation, generation: Int) {
        guard presentation == expected, presentationGeneration == generation else { return }
        closePresentation()
    }
    func convertedToInvoice(_ id: String) {
        guard case .quote(let quoteId) = presentation else { return }
        if needsPriceReview(quoteId) { priceReviewIds.insert(id) }
        presentation = .invoice(id)
    }
    func clientSaved(_ client: Client) { selectedClientId = client.id; closePresentation() }
    func createDocument(kind: ClientHistory.DocumentKind) {
        guard presentation == nil, let id = selectedClientId else { return }
        do {
            switch kind {
            case .quote: presentation = .quote(try repeatService.newQuote(clientId: id, now: Date()))
            case .invoice: presentation = .invoice(try repeatService.newInvoice(clientId: id, now: Date()))
            }
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }
    func createAgain(_ source: ClientHistory.Document) {
        guard presentation == nil, history.documents.contains(where: { $0.reference == source.reference }) else { return }
        do {
            switch source.kind {
            case .quote:
                let id = try repeatService.repeatQuote(sourceId: source.id, now: Date())
                priceReviewIds.insert(id); presentation = .quote(id)
            case .invoice:
                let id = try repeatService.repeatInvoice(sourceId: source.id, now: Date())
                priceReviewIds.insert(id); presentation = .invoice(id)
            }
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }
    func needsPriceReview(_ documentId: String) -> Bool { priceReviewIds.contains(documentId) }
    func mutateFollowUp(_ row: ClientFollowUp, delete: Bool = false) {
        do {
            if delete { try followUpStore.delete(id: row.id) }
            else if row.completedAt == nil { try followUpStore.complete(id: row.id, at: Epoch.nowMs()) }
            else { try followUpStore.reopen(id: row.id) }
            reload()
        } catch { errorMessage = error.localizedDescription }
    }
    func deleteSelectedClient() {
        guard let id = selectedClientId else { return }
        do { try clientStore.delete(id: id); reload() }
        catch { errorMessage = error.localizedDescription }
    }
}
