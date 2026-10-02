import Foundation
import SwiftData
import Observation

/// Picker reads and writes through the same scoped client store as the client editor.
@Observable
@MainActor
final class ClientPickerViewModel {
    @ObservationIgnored private let store: ClientStore
    @ObservationIgnored let profileId: String
    private(set) var clients: [Client] = []
    var errorMessage: String?

    init(context: ModelContext, sync: any SyncEnqueuing, userId: String, profileId: String,
         persist: @escaping (ModelContext) throws -> Void = { try $0.save() }) {
        self.store = ClientStore(context: context, sync: sync, userId: userId, profileId: profileId, persist: persist)
        self.profileId = profileId
        reload()
    }

    func reload() {
        do { clients = try store.list(search: "") }
        catch { clients = []; errorMessage = error.localizedDescription }
    }

    func filtered(search: String) -> [Client] {
        do { return try store.list(search: search) }
        catch { errorMessage = error.localizedDescription; return [] }
    }

    @discardableResult
    func create(name: String, email: String?, mobilePhone: String? = nil, address: String? = nil) -> Client? {
        errorMessage = nil
        do {
            let client = try store.save(id: nil, draft: ClientDraft(name: name, email: email, mobilePhone: mobilePhone, address: address))
            reload()
            return client
        } catch { errorMessage = error.localizedDescription; return nil }
    }

    func delete(_ client: Client) {
        errorMessage = nil
        do { try store.delete(id: client.id); reload() }
        catch { errorMessage = error.localizedDescription }
    }
}
