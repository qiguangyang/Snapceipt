import SwiftUI
import SwiftData
import Observation

@Observable
@MainActor
final class LegacyDocumentLinkViewModel {
    struct Candidate: Identifiable {
        let reference: ClientHistory.DocumentReference
        let number: String?
        let originalName: String?
        let originalEmail: String?
        let date: String
        let createdAt: Int
        let totalCents: Int
        let currency: String
        let reason: LegacyClientLinker.Reason?
        var id: ClientHistory.DocumentReference { reference }
    }

    var suggested: [Candidate] = []
    var manual: [Candidate] = []
    var selected: Set<ClientHistory.DocumentReference> = []
    var errorMessage: String?
    @ObservationIgnored private let store: ClientStore
    @ObservationIgnored private let client: ClientSelection

    init(store: ClientStore, client: ClientSelection) {
        self.store = store
        self.client = client
    }

    func load() {
        errorMessage = nil
        do {
            // Validate the target too: a stale detail view must not reveal another scope.
            guard try store.list(search: "").contains(where: { $0.id == client.id }) else {
                throw ClientStore.ValidationError.unavailable
            }
            let uid = store.userId, pid = store.profileId
            // Display persisted original snapshots, excluding pending editor input.
            let reader = ModelContext(store.context.container)
            reader.autosaveEnabled = false
            let quotes = try reader.fetch(FetchDescriptor<Quote>(predicate: #Predicate {
                $0.userId == uid && $0.profileId == pid && $0.deletedAt == nil && $0.clientId == nil
            }))
            let invoices = try reader.fetch(FetchDescriptor<Invoice>(predicate: #Predicate {
                $0.userId == uid && $0.profileId == pid && $0.deletedAt == nil && $0.clientId == nil
            }))
            let matches = LegacyClientLinker.suggestions(client: client, userId: uid, profileId: pid,
                                                        quotes: quotes, invoices: invoices)
            let reasons = Dictionary(uniqueKeysWithValues: matches.map { ($0.reference, $0.reason) })
            var candidates = quotes.map { quote in
                let reference = ClientHistory.DocumentReference(kind: .quote, id: quote.id)
                return Candidate(reference: reference, number: quote.number, originalName: quote.clientName,
                                 originalEmail: quote.clientEmail, date: Self.date(quote.createdAt), createdAt: quote.createdAt,
                                 totalCents: quote.totalCents, currency: quote.currency, reason: reasons[reference])
            }
            candidates += invoices.map { invoice in
                let reference = ClientHistory.DocumentReference(kind: .invoice, id: invoice.id)
                return Candidate(reference: reference, number: invoice.number, originalName: invoice.clientName,
                                 originalEmail: invoice.clientEmail, date: invoice.issueDate ?? Self.date(invoice.createdAt), createdAt: invoice.createdAt,
                                 totalCents: invoice.totalCents, currency: invoice.currency, reason: reasons[reference])
            }
            candidates.sort {
                if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
                if $0.reference.kind != $1.reference.kind { return $0.reference.kind.rawValue < $1.reference.kind.rawValue }
                return $0.reference.id < $1.reference.id
            }
            suggested = candidates.filter { $0.reason != nil }
            manual = candidates.filter { $0.reason == nil }
            selected.formIntersection(Set(candidates.map(\.reference)))
        } catch {
            suggested = []; manual = []
            errorMessage = error.localizedDescription
        }
    }

    func toggle(_ reference: ClientHistory.DocumentReference) {
        if selected.contains(reference) { selected.remove(reference) }
        else { selected.insert(reference) }
    }

    @discardableResult
    func confirm(onLinked: () -> Void) -> Bool {
        errorMessage = nil
        guard !selected.isEmpty else { return false }
        do {
            try store.linkExistingDocuments(clientId: client.id, documents: Array(selected))
            onLinked()
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    private static func date(_ epoch: Int) -> String {
        Date(timeIntervalSince1970: Double(epoch) / 1000).formatted(date: .abbreviated, time: .omitted)
    }
}

/// Explicit selection and confirmation for suggestions and a separate manual picker.
struct LegacyDocumentLinkView: View {
    let onLinked: () -> Void
    let onClose: () -> Void
    @State private var vm: LegacyDocumentLinkViewModel
    @State private var showConfirmation = false
    @Environment(\.accent) private var accent

    init(store: ClientStore, client: ClientSelection, onLinked: @escaping () -> Void,
         onClose: @escaping () -> Void) {
        self.onLinked = onLinked
        self.onClose = onClose
        _vm = State(initialValue: LegacyDocumentLinkViewModel(store: store, client: client))
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Link existing documents", onClose: onClose)
            List {
                Section("Suggested documents") {
                    if vm.suggested.isEmpty { Text("No matching unlinked documents.") }
                    ForEach(vm.suggested) { candidate in row(candidate) }
                }
                Section("Choose other unlinked documents") {
                    if vm.manual.isEmpty { Text("No other unlinked documents in this business.") }
                    ForEach(vm.manual) { candidate in row(candidate) }
                }
                if let error = vm.errorMessage {
                    Text(error).foregroundStyle(Palette.alert)
                }
            }
            Button("Link selected documents (\(vm.selected.count))") { showConfirmation = true }
                .font(.ui(15, .semibold)).foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 46)
                .background(accent.base, in: RoundedRectangle(cornerRadius: 14))
                .disabled(vm.selected.isEmpty)
                .opacity(vm.selected.isEmpty ? 0.5 : 1)
                .padding(18)
        }
        .background(Palette.cream)
        .onAppear { vm.load() }
        .confirmationDialog("Link selected documents to this client?", isPresented: $showConfirmation, titleVisibility: .visible) {
            Button("Confirm association") { vm.confirm(onLinked: onLinked) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The original contact details, amounts, and dates will be preserved.")
        }
    }

    private func row(_ candidate: LegacyDocumentLinkViewModel.Candidate) -> some View {
        Button { vm.toggle(candidate.reference) } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: vm.selected.contains(candidate.reference) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(accent.base)
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(candidate.reference.kind == .quote ? "Quote" : "Invoice") \(candidate.number ?? "Draft")")
                        .font(.ui(15, .semibold))
                    Text(candidate.originalName ?? "No contact name")
                    if let email = candidate.originalEmail { Text(email) }
                    Text("\(candidate.date) · \(Double(candidate.totalCents) / 100, format: .currency(code: candidate.currency))")
                    if let reason = candidate.reason {
                        Text(reason == .email ? "Matching email" : "Matching name").font(.ui(12, .semibold))
                    }
                }.foregroundStyle(Palette.ink)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(vm.selected.contains(candidate.reference) ? .isSelected : [])
    }
}
