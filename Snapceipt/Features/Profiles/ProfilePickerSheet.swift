import SwiftUI
import SwiftData

/// Bottom sheet listing the user's profiles with an active check, plus a dashed
/// "Add a profile" row. Selecting a row activates it and dismisses.
struct ProfilePickerSheet: View {
    let store: ProfilesStore
    var onAddProfile: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        // No inner grabber / paper panel: the host `.sheet` already owns the
        // presentation chrome (rounded corners + system drag indicator). Drawing
        // our own grabber + white rounded panel on top produced a double-grabber
        // and a sheet-within-a-sheet artifact — render straight onto the sheet
        // surface, matching the sibling AddProfileView.
        VStack(spacing: 0) {
            HStack {
                Text("Switch profile")
                    .font(.display(20, .bold))
                    .foregroundStyle(Palette.ink)
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 14)

            VStack(spacing: 8) {
                ForEach(store.profiles, id: \.id) { p in
                    profileRow(p)
                }
                addRow
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 24)
        }
    }

    private func profileRow(_ p: Profile) -> some View {
        let isActive = p.id == store.activeProfileId
        let base = Color(hex: hex(p.accent1))
        let deep = Color(hex: hex(p.accent3))
        return Button {
            store.setActive(p.id)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Text(p.initials ?? "?")
                    .font(.display(15, .bold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(
                        LinearGradient(colors: [base, deep],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                    )
                VStack(alignment: .leading, spacing: 1) {
                    Text(p.name).font(.ui(15.5, .bold)).foregroundStyle(Palette.ink)
                    Text(ProfileType(rawValue: p.type)?.label ?? p.type)
                        .font(.ui(12.5, .regular)).foregroundStyle(Palette.ink3)
                }
                Spacer(minLength: 0)
                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(isActive ? base : Palette.line)
            }
            .padding(12)
            .background(Palette.paper, in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.inner, style: .continuous)
                    .stroke(isActive ? base : Palette.line2, lineWidth: isActive ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var addRow: some View {
        Button(action: onAddProfile) {
            HStack(spacing: 12) {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Palette.ink2)
                    .frame(width: 42, height: 42)
                Text("Add a profile").font(.ui(15.5, .semibold)).foregroundStyle(Palette.ink2)
                Spacer(minLength: 0)
            }
            .padding(12)
            .overlay(
                RoundedRectangle(cornerRadius: Radius.inner, style: .continuous)
                    .stroke(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                    .foregroundStyle(Palette.line)
            )
        }
        .buttonStyle(.plain)
    }
}

#if DEBUG
#Preview {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: Profile.self, configurations: config)
    let context = ModelContext(container)
    let store = ProfilesStore(context: context, sync: PreviewSync(), userId: "u1")
    let a = AddProfileViewModel(store: store, context: context, userId: "u1")
    a.name = "Personal"; a.swatch = AP_ACCENTS[0]; a.create()
    let b = AddProfileViewModel(store: store, context: context, userId: "u1")
    b.name = "Lumen Studio"; b.type = .business; b.swatch = AP_ACCENTS[2]; b.create()
    return ProfilePickerSheet(store: store, onAddProfile: {})
        .frame(maxHeight: .infinity, alignment: .bottom)
        .background(Color.black.opacity(0.4))
}
#endif
