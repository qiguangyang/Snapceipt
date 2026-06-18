import SwiftUI
import SwiftData

/// Bill-to client picker, presented as a `.sheet` from the editor. Lists the active
/// profile's saved clients (searchable), plus an inline "New client" form. Picking or
/// creating a client hands its name/email snapshot back via `onPick`.
struct ClientPickerSheet: View {
    let context: ModelContext
    let sync: any SyncEnqueuing
    let userId: String
    let profileId: String
    let onPick: (_ name: String, _ email: String?) -> Void
    let onClose: () -> Void

    @Environment(\.accent) private var accent
    @State private var vm: ClientPickerViewModel?
    @State private var search = ""
    @State private var showNew = false
    @State private var newName = ""
    @State private var newEmail = ""

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Bill to", onClose: onClose)
            if let vm {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        searchField
                        newClientButton
                        if showNew { newClientForm(vm) }
                        let clients = vm.filtered(search: search)
                        if !clients.isEmpty {
                            Text("CLIENTS").font(.ui(12.5, .bold)).foregroundStyle(Palette.ink3).kerning(0.3)
                                .padding(.top, 8)
                            VStack(spacing: 10) {
                                ForEach(clients) { client in
                                    Button { onPick(client.name, client.email) } label: { row(client) }
                                        .buttonStyle(.plain)
                                        .accessibilityIdentifier(AccessibilityID.clientRowPrefix + client.id)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 40)
                }
            } else { Color.clear }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Palette.cream)
        .keyboardDismissButton() // hide-keyboard accessory for search + new-client fields
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.clientPickerScreen)
        .task {
            if vm == nil {
                vm = ClientPickerViewModel(context: context, sync: sync, userId: userId, profileId: profileId)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Icon(name: "search", size: 17, color: Palette.ink3)
            TextField("Search clients", text: $search)
        }
        .padding(12)
        .background(Palette.paper, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.line2, lineWidth: 1))
    }

    private var newClientButton: some View {
        Button { withAnimation { showNew.toggle() } } label: {
            HStack(spacing: 8) {
                Icon(name: "plus", size: 16, color: accent.base, lineWidth: 2)
                Text("New client").font(.ui(14.5, .semibold)).foregroundStyle(accent.base)
                Spacer()
            }
            .padding(12)
            .background(Palette.paper, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(accent.base.opacity(0.4), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AccessibilityID.clientPickerAdd)
    }

    @ViewBuilder private func newClientForm(_ vm: ClientPickerViewModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            field("Client name", text: $newName)
            field("Email (optional)", text: $newEmail)
            Button {
                if let c = vm.create(name: newName, email: newEmail) {
                    onPick(c.name, c.email)
                }
            } label: {
                Text("Save client").font(.ui(15, .semibold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .background(newName.trimmingCharacters(in: .whitespaces).isEmpty ? Palette.ink3 : accent.base,
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(12)
        .background(Palette.paper, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.ui(12.5, .semibold)).foregroundStyle(Palette.ink3)
            TextField(title, text: text)
                .padding(12).background(Palette.cream, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func row(_ client: Client) -> some View {
        Card(padding: 14) {
            HStack(spacing: 12) {
                clientTile(client.name)
                VStack(alignment: .leading, spacing: 2) {
                    Text(client.name).font(.ui(15, .bold)).foregroundStyle(Palette.ink)
                    if let email = client.email {
                        Text(email).font(.ui(12.5)).foregroundStyle(Palette.ink3)
                    }
                }
                Spacer(minLength: 0)
                Icon(name: "chevR", size: 14, color: Palette.ink3)
            }
            .contentShape(Rectangle())
        }
    }

    /// 42×42 accent-soft tile showing the client's first initial.
    @ViewBuilder private func clientTile(_ name: String) -> some View {
        if let initial = name.trimmingCharacters(in: .whitespaces).first {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(accent.soft)
                .frame(width: 42, height: 42)
                .overlay(Text(String(initial).uppercased()).font(.ui(16, .bold)).foregroundStyle(accent.base))
        } else {
            IconCircle(name: "building", tint: accent.base, soft: accent.soft, size: 42, iconSize: 19)
        }
    }
}
