import SwiftUI
import Observation

@Observable
@MainActor
final class ClientEditViewModel {
    var draft: ClientDraft
    var errorMessage: String?
    @ObservationIgnored private let store: ClientStore
    @ObservationIgnored private let clientId: String?

    init(store: ClientStore, client: Client? = nil) {
        self.store = store
        clientId = client?.id
        // Do not expose contact fields from another account/profile in this editor.
        if let client, client.userId == store.userId, client.profileId == store.profileId, client.deletedAt == nil {
            draft = ClientDraft(name: client.name, email: client.email, mobilePhone: client.mobilePhone,
                                address: client.address, notes: client.notes)
        } else { draft = ClientDraft(name: "") }
    }

    @discardableResult
    func save(onSaved: (Client) -> Void) -> Bool {
        errorMessage = nil
        do {
            let client = try store.save(id: clientId, draft: draft)
            onSaved(client)
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }
}

/// Editable contact details and private notes. A failed write leaves the form open.
struct ClientEditView: View {
    let onSaved: (Client) -> Void
    let onClose: () -> Void
    private let isNew: Bool
    @Environment(\.accent) private var accent
    @State private var vm: ClientEditViewModel

    init(store: ClientStore, client: Client? = nil,
         onSaved: @escaping (Client) -> Void, onClose: @escaping () -> Void) {
        self.onSaved = onSaved
        self.onClose = onClose
        isNew = client == nil
        _vm = State(initialValue: ClientEditViewModel(store: store, client: client))
    }

    var body: some View {
        @Bindable var vm = vm
        VStack(spacing: 0) {
            SheetHeader(title: isNew ? "New client" : "Edit client", onClose: onClose)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    field("Client name", text: $vm.draft.name)
                    field("Email (optional)", text: optional($vm.draft.email))
                    field("Mobile phone (optional)", text: optional($vm.draft.mobilePhone))
                    field("Address (optional)", text: optional($vm.draft.address), multiline: true)
                    field("Notes (optional)", text: optional($vm.draft.notes), multiline: true)
                    if let error = vm.errorMessage { Text(error).font(.ui(13)).foregroundStyle(Palette.alert) }
                    Button("Save client") { vm.save(onSaved: onSaved) }
                        .font(.ui(15, .semibold)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .background(accent.base, in: RoundedRectangle(cornerRadius: 14))
                        .buttonStyle(.plain)
                }.padding(18)
            }
        }
        .background(Palette.cream)
        .keyboardDismissButton()
    }

    private func optional(_ value: Binding<String?>) -> Binding<String> {
        Binding(get: { value.wrappedValue ?? "" }, set: { value.wrappedValue = $0 })
    }

    private func field(_ title: String, text: Binding<String>, multiline: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.ui(12.5, .semibold)).foregroundStyle(Palette.ink3)
            TextField(title, text: text, axis: multiline ? .vertical : .horizontal)
                .lineLimit(multiline ? 2...8 : 1...1)
                .padding(12).background(Palette.paper, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}
