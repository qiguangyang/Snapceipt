import SwiftUI
import SwiftData

/// All client-originated presentations stay in this workspace so Close/Save returns to detail.
struct ClientsHubView: View {
    let context: ModelContext
    let sync: any SyncEnqueuing
    let api: APIClient
    let userId: String
    let profileId: String
    let onClose: () -> Void
    let scheduler: FollowUpNotificationScheduler
    @Environment(\.scenePhase) private var scenePhase
    @State private var vm: ClientWorkspaceViewModel

    init(context: ModelContext, sync: any SyncEnqueuing, api: APIClient, userId: String,
         profileId: String, initialClientId: String?, onClose: @escaping () -> Void,
         scheduler: FollowUpNotificationScheduler) {
        self.context = context; self.sync = sync; self.api = api; self.userId = userId
        self.profileId = profileId; self.onClose = onClose; self.scheduler = scheduler
        _vm = State(initialValue: ClientWorkspaceViewModel(context: context, sync: sync, userId: userId,
            profileId: profileId, initialClientId: initialClientId))
    }
    var body: some View {
        NavigationStack(path: Binding(get: { vm.selectedClientId.map { [$0] } ?? [] }, set: { ids in
            vm.selectedClientId = ids.last; vm.reload()
        })) {
            ClientsListView(vm: vm)
                .navigationDestination(for: String.self) { _ in ClientDetailView(vm: vm, scheduler: scheduler) }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Close", action: onClose).accessibilityIdentifier(AccessibilityID.clientsClose) }
                    ToolbarItem(placement: .primaryAction) { Button("Saved items") { vm.presentation = .catalog }.accessibilityIdentifier(AccessibilityID.clientsSavedItems) }
                }
        }
        .accessibilityIdentifier(AccessibilityID.clientsHubScreen)
        .sheet(item: presentationBinding(document: false), onDismiss: refresh) { presentation in
            let generation = vm.presentationGeneration
            switch presentation {
            case .catalog: CatalogListView(context: context, sync: sync, userId: userId, profileId: profileId)
            case .client(let id):
                if id == nil || vm.clients.contains(where: { $0.id == id }) {
                    ClientEditView(store: vm.clientStore, client: vm.clients.first { $0.id == id },
                        onSaved: vm.clientSaved, onClose: vm.closePresentation)
                } else { unavailableEditor }
            case .followUp(let id):
                if let clientId = vm.selectedClientId,
                   id == nil || vm.followUps.contains(where: { $0.id == id && $0.clientId == clientId }) {
                    ClientFollowUpEditorView(store: vm.followUpStore, clientId: clientId,
                        followUp: vm.followUps.first { $0.id == id }, scheduler: scheduler,
                        onSaved: { _ in vm.finishPresentation(presentation, generation: generation) }, onClose: vm.closePresentation)
                } else { unavailableEditor }
            case .link:
                if let client = vm.selectedClient {
                    LegacyDocumentLinkView(store: vm.clientStore, client: ClientSelection(client),
                        onLinked: vm.closePresentation, onClose: vm.closePresentation)
                }
            default: EmptyView()
            }
        }
        .fullScreenCover(item: presentationBinding(document: true), onDismiss: refresh) { presentation in
            documentEditor(presentation).id(presentation.id)
        }
        .onReceive(NotificationCenter.default.publisher(for: .syncDidApplyChanges)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .clientFollowUpsDidChange)) { _ in refresh() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { refresh() } }
    }
    private func presentationBinding(document: Bool) -> Binding<ClientWorkspaceViewModel.Presentation?> {
        Binding(get: { vm.presentation?.isDocument == document ? vm.presentation : nil }, set: { value in
            if let value { vm.presentation = value }
            else if vm.presentation?.isDocument == document { vm.closePresentation() }
        })
    }
    @ViewBuilder private func documentEditor(_ presentation: ClientWorkspaceViewModel.Presentation) -> some View {
        switch presentation {
        case .quote(let id):
            QuoteEditorView(context: context, sync: sync, api: api, userId: userId, profileId: profileId,
                quoteId: id, onClose: vm.closePresentation, onConvert: vm.convertedToInvoice, onSavedDraft: vm.closePresentation, showsRepeatReview: vm.needsPriceReview(id))
        case .invoice(let id):
            InvoiceEditorView(context: context, sync: sync, api: api, userId: userId, profileId: profileId,
                invoiceId: id, onClose: vm.closePresentation, onSavedDraft: vm.closePresentation, showsRepeatReview: vm.needsPriceReview(id))
        default: EmptyView()
        }
    }
    private var unavailableEditor: some View {
        VStack(spacing: 16) {
            Text("This record is no longer available in this business.")
            Button("Close", action: vm.closePresentation)
        }.padding()
    }
    private func refresh() { vm.reload(); Task { await scheduler.refresh() } }
}

/// A separate scoped workspace instance keeps the Home counts current after sync/mutations.
struct ClientsHomeCard: View {
    let context: ModelContext
    let sync: any SyncEnqueuing
    let userId: String
    let profileId: String
    let onOpen: () -> Void
    let refreshToken: String
    @Environment(\.scenePhase) private var scenePhase
    @State private var vm: ClientWorkspaceViewModel?
    var body: some View {
        Button(action: onOpen) {
            Card(padding: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Clients").font(.headline)
                        Text("\(vm?.clients.count ?? 0) clients").font(.subheadline)
                        Text("\(vm?.openFollowUps.count ?? 0) follow-ups · \(vm?.dueCount ?? 0) due").font(.subheadline)
                        Text("Open clients").font(.subheadline.weight(.semibold))
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                }.foregroundStyle(Palette.ink)
            }
        }
        .buttonStyle(.plain).accessibilityIdentifier(AccessibilityID.homeClients)
        .onChange(of: refreshToken) { _, _ in vm?.reload() }
        .task { vm = ClientWorkspaceViewModel(context: context, sync: sync, userId: userId, profileId: profileId) }
        .onReceive(NotificationCenter.default.publisher(for: .syncDidApplyChanges)) { _ in vm?.reload() }
        .onReceive(NotificationCenter.default.publisher(for: .clientFollowUpsDidChange)) { _ in vm?.reload() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { vm?.reload() } }
    }
}
