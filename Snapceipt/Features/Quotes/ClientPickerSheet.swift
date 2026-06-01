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
                        ForEach(vm.filtered(search: search)) { client in
                            Button { onPick(client.name, client.email) } label: { row(client) }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier(AccessibilityID.clientRowPrefix + client.id)
                        }
                    }
                    .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 40)
                }
            } else { Color.clear }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Palette.cream)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.clientPickerScreen)
        .task {
            if vm == nil {
                vm = ClientPickerViewModel(context: context, sync: sync, userId: userId, profileId: profileId)
            }
        }
    }

    private var searchField: some View {
        TextField("Search clients", text: $search)
            .padding(12).background(Palette.paper, in: RoundedRectangle(cornerRadius: 12))
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
        HStack(spacing: 12) {
            IconCircle(name: "building", tint: accent.base, soft: accent.soft, size: 38, iconSize: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(client.name).font(.ui(14.5, .semibold)).foregroundStyle(Palette.ink)
                if let email = client.email {
                    Text(email).font(.ui(12)).foregroundStyle(Palette.ink3)
                }
            }
            Spacer()
            Icon(name: "chevD", size: 14, color: Palette.ink3)
        }
        .padding(.vertical, 6)
    }
}
