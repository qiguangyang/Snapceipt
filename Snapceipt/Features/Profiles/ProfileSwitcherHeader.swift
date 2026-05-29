import SwiftUI
import SwiftData

/// Home header: gradient avatar + "ACTIVE PROFILE" + name + (chevron when
/// multiple profiles). Tapping opens the picker via the supplied closure.
struct ProfileSwitcherHeader: View {
    let store: ProfilesStore
    /// Invoked when the user taps to switch (only meaningful with >1 profile).
    var onTapSwitch: () -> Void

    private var profile: Profile? { store.activeProfile }
    private var canSwitch: Bool { store.profiles.count > 1 }

    var body: some View {
        Button(action: { if canSwitch { onTapSwitch() } }) {
            HStack(spacing: 12) {
                avatar
                VStack(alignment: .leading, spacing: 2) {
                    Text("ACTIVE PROFILE")
                        .font(.ui(11.5, .bold))
                        .tracking(0.4)
                        .foregroundStyle(Palette.ink3)
                    HStack(spacing: 8) {
                        Text(profile?.name ?? "No profile")
                            .font(.display(19, .bold))
                            .tracking(-0.3)
                            .foregroundStyle(Palette.ink)
                        if canSwitch { chevronPill }
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canSwitch)
    }

    private var avatar: some View {
        let base = Color(hex: hex(profile?.accent1 ?? "#E8602C"))
        let deep = Color(hex: hex(profile?.accent3 ?? "#C2461A"))
        return Text(profile?.initials ?? "?")
            .font(.display(17, .bold))
            .foregroundStyle(.white)
            .frame(width: 46, height: 46)
            .background(
                LinearGradient(colors: [base, deep],
                               startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 15, style: .continuous)
            )
            .shadow(color: base.opacity(0.45), radius: 7, x: 0, y: 6)
    }

    private var chevronPill: some View {
        Image(systemName: "chevron.down")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(Palette.ink2)
            .frame(width: 22, height: 22)
            .background(Palette.paper2, in: Circle())
    }
}

#if DEBUG
/// Preview-only no-op sync seam (lives behind `#if DEBUG` so it never ships).
@MainActor
final class PreviewSync: SyncEnqueuing {
    func enqueue(op: String, entityType: EntityType, entity: any Syncable) {}
}

#Preview {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: Profile.self, configurations: config)
    let context = ModelContext(container)
    let store = ProfilesStore(context: context, sync: PreviewSync(), userId: "u1")
    let vm = AddProfileViewModel(store: store, context: context, userId: "u1")
    vm.name = "Lumen Studio"; vm.type = .business; vm.swatch = AP_ACCENTS[2]
    vm.create()
    let v2 = AddProfileViewModel(store: store, context: context, userId: "u1")
    v2.name = "Personal"; v2.swatch = AP_ACCENTS[0]; v2.create()
    return ProfileSwitcherHeader(store: store, onTapSwitch: {})
        .padding()
        .background(Palette.cream)
}
#endif
