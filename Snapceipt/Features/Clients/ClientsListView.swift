import SwiftUI

struct ClientsListView: View {
    @Bindable var vm: ClientWorkspaceViewModel
    var body: some View {
        List {
            Picker("View", selection: $vm.showFollowUps) {
                Text("All clients").tag(false)
                Text("Follow-ups").tag(true)
            }.pickerStyle(.segmented).accessibilityIdentifier(AccessibilityID.clientsFilter)
            if let error = vm.errorMessage { Text(error).foregroundStyle(.red) }
            if vm.showFollowUps {
                if vm.openFollowUps.isEmpty { Text("No open follow-ups. Set a reminder from a client.").foregroundStyle(.secondary) }
                ForEach(vm.openFollowUps) { reminder in
                    Button { vm.select(reminder.clientId) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(reminder.title)
                            Text(vm.clients.first { $0.id == reminder.clientId }?.name ?? "Client").font(.subheadline)
                            Text(ClientDetailView.dueDescription(reminder)).font(.caption).foregroundStyle(.secondary)
                            if reminder.dueAt <= Epoch.nowMs() { Text("Due").font(.caption.weight(.bold)) }
                        }
                    }.accessibilityIdentifier(AccessibilityID.clientReminderRowPrefix + reminder.id)
                }
            } else {
                if vm.filteredClients.isEmpty { Text(vm.search.isEmpty ? "No clients yet. Add your first client." : "No matching clients.").foregroundStyle(.secondary) }
                ForEach(vm.filteredClients) { client in
                    Button { vm.select(client.id) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(client.name).font(.headline)
                            if let email = client.email { Text(email).font(.subheadline) }
                            if let phone = client.mobilePhone { Text(phone).font(.subheadline) }
                        }
                    }.accessibilityIdentifier(AccessibilityID.clientWorkspaceRowPrefix + client.id)
                }
            }
            Button("Add client", systemImage: "plus") { vm.presentation = .client(nil) }
                .accessibilityIdentifier(AccessibilityID.clientsAdd)
        }
        .navigationTitle("Clients")
        .searchable(text: $vm.search, prompt: "Search name, email or phone")
        .scrollDismissesKeyboard(.interactively)
        .keyboardDismissButton()
    }
}
