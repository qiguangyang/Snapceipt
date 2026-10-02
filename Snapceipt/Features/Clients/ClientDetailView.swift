import SwiftUI

struct ClientDetailView: View {
    @Bindable var vm: ClientWorkspaceViewModel
    let scheduler: FollowUpNotificationScheduler
    @State private var showCompleted = false
    @State private var confirmDelete = false
    var body: some View {
        List {
            if let client = vm.selectedClient {
                Section("Contact") {
                    if let email = client.email { Text(email) }
                    if let phone = client.mobilePhone { Text(phone) }
                    if let address = client.address { Text(address) }
                    Button("Edit client and notes") { vm.presentation = .client(client.id) }
                        .accessibilityIdentifier(AccessibilityID.clientEdit)
                }
                Section("Notes") { Text(client.notes ?? "No notes yet.").textSelection(.enabled) }
                Section("Outstanding balance") {
                    if vm.history.outstandingByCurrency.isEmpty { Text("No outstanding balance.").foregroundStyle(.secondary) }
                    ForEach(vm.history.outstandingByCurrency.keys.sorted(), id: \.self) { currency in
                        HStack {
                            Text(currency)
                            Spacer()
                            Text(Money(cents: vm.history.outstandingByCurrency[currency] ?? 0).decimal.formatted(.currency(code: currency)))
                                .font(.headline)
                        }
                    }
                }
                Section("Prepare work") {
                    Button("New quote") { vm.createDocument(kind: .quote) }.accessibilityIdentifier(AccessibilityID.clientNewQuote)
                    Button("New invoice") { vm.createDocument(kind: .invoice) }.accessibilityIdentifier(AccessibilityID.clientNewInvoice)
                    Button("Set reminder") { vm.presentation = .followUp(nil) }.accessibilityIdentifier(AccessibilityID.clientSetReminder)
                    Text("Review prices and dates before sending.").font(.footnote).foregroundStyle(.secondary)
                }
                if let error = vm.errorMessage { Text(error).foregroundStyle(.red) }
                Section("Document history") {
                    if vm.history.documents.isEmpty { Text("No linked quotes or invoices yet.").foregroundStyle(.secondary) }
                    ForEach(vm.history.documents) { document in
                        VStack(alignment: .leading, spacing: 8) {
                            Button {
                                vm.presentation = document.kind == .quote ? .quote(document.id) : .invoice(document.id)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("\(document.kind == .quote ? "Quote" : "Invoice") \(document.number ?? "Draft")")
                                    Text("\(document.status.capitalized)\(document.paymentState.map { " · \($0.rawValue.capitalized)" } ?? "") · \(Money(cents: document.totalCents).decimal.formatted(.currency(code: document.currency)))").font(.subheadline)
                                }
                            }.accessibilityIdentifier(AccessibilityID.clientDocumentRowPrefix + document.id)
                            Button("Create again") { vm.createAgain(document) }
                                .accessibilityLabel("Create \(document.kind.rawValue) \(document.number ?? "draft") again")
                                .accessibilityIdentifier(AccessibilityID.clientCreateAgainPrefix + document.id)
                        }
                    }
                    Button("Link existing documents") { vm.presentation = .link }.accessibilityIdentifier(AccessibilityID.clientLinkDocuments)
                }
                Section("Follow-ups") {
                    let rows = vm.followUps.filter { $0.clientId == client.id }
                    if rows.filter({ $0.completedAt == nil }).isEmpty { Text("No open follow-ups.").foregroundStyle(.secondary) }
                    ForEach(rows.filter { $0.completedAt == nil }) { row in followUpRow(row) }
                    DisclosureGroup("Completed follow-ups", isExpanded: $showCompleted) {
                        ForEach(rows.filter { $0.completedAt != nil }) { row in followUpRow(row) }
                    }
                }
                Section {
                    Button("Delete client", role: .destructive) { confirmDelete = true }
                }
            } else { Text("This client is no longer available.") }
        }
        .buttonStyle(.borderless)
        .navigationTitle(vm.selectedClient?.name ?? "Client")
        .accessibilityIdentifier(AccessibilityID.clientDetailScreen)
        .confirmationDialog("Delete this client and its follow-ups?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete client", role: .destructive) { vm.deleteSelectedClient(); Task { await scheduler.refresh() } }
        } message: { Text("Existing documents and payments remain available.") }
    }
    @ViewBuilder private func followUpRow(_ row: ClientFollowUp) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Button(row.title) { vm.presentation = .followUp(row.id) }
            Text(Self.dueDescription(row)).font(.caption).foregroundStyle(.secondary)
            Text(row.completedAt == nil ? scheduler.status(for: row).rawValue : "Completed").font(.caption)
            HStack {
                Button(row.completedAt == nil ? "Mark complete" : "Reopen") { vm.mutateFollowUp(row); Task { await scheduler.refresh() } }
                Spacer()
                Button("Delete", role: .destructive) { vm.mutateFollowUp(row, delete: true); Task { await scheduler.refresh() } }
            }.font(.subheadline)
        }.accessibilityIdentifier(AccessibilityID.clientReminderRowPrefix + row.id)
    }
    static func dueDescription(_ row: ClientFollowUp) -> String {
        let formatter = DateFormatter(); formatter.dateStyle = .medium; formatter.timeStyle = .short
        formatter.timeZone = TimeZone(identifier: row.timezone)
        return "\(formatter.string(from: Date(timeIntervalSince1970: Double(row.dueAt) / 1000))) · \(row.timezone)"
    }
}
