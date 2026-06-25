import SwiftUI
import SwiftData

/// Home header: gradient avatar + "ACTIVE PROFILE" + name + chevron.
/// Tapping always opens the picker via the supplied closure — even with a
/// single profile, so the user can switch or add another from one place.
struct ProfileSwitcherHeader: View {
    let store: ProfilesStore
    /// Drives the avatar's sync ring (replaces the old floating "Syncing…" pill): a GREEN border
    /// while a sync is running, RED when the server can't be reached, and NO border once connected
    /// / idle.
    var syncStatus: SyncStatus = .idle
    /// Invoked when the user taps the header to open the profile picker.
    var onTapSwitch: () -> Void

    private var profile: Profile? { store.activeProfile }

    var body: some View {
        Button(action: onTapSwitch) {
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
                        chevronPill
                    }
                }
            }
            // Sized to its content (no trailing greedy Spacer) so the header's tap
            // area can't bleed across the row and swallow the adjacent alerts bell.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AccessibilityID.profileSwitcher)
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
            // Sync ring: green while syncing, red when the server is unreachable, none when idle.
            // Drawn OUTSIDE the avatar with a small cream gap (`.padding(-4)`) so it stays legible
            // on any profile accent — incl. a green-accented avatar where an edge ring would blend.
            .overlay(
                RoundedRectangle(cornerRadius: 19, style: .continuous)
                    .strokeBorder(syncRingColor ?? .clear, lineWidth: syncRingColor == nil ? 0 : 2.5)
                    .padding(-4)
            )
            .shadow(color: base.opacity(0.45), radius: 7, x: 0, y: 6)
            .animation(.easeInOut(duration: 0.3), value: syncStatus)
    }

    /// Avatar ring colour for the current sync state, or nil for no ring (idle/connected).
    private var syncRingColor: Color? {
        switch syncStatus {
        case .syncing:          return Color(hex: hex("#2EAD5A"))  // green — sync running
        case .offline, .error:  return Palette.alert               // red — can't reach the server
        case .idle:             return nil                         // connected / idle — no ring
        }
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
