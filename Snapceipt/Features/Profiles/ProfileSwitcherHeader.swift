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

    /// True for ~2s right after a sync completes successfully (`.syncing → .idle`) — drives the
    /// green "synced" flash ring, which then clears.
    @State private var showSuccess = false
    @State private var successTask: Task<Void, Never>?

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
        .onChange(of: syncStatus) { old, new in
            switch new {
            case .idle:
                guard old == .syncing else { return }   // sync just succeeded → green flash, 2s
                showSuccess = true
                successTask?.cancel()
                successTask = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    if !Task.isCancelled { showSuccess = false }
                }
            case .syncing, .offline, .error:
                successTask?.cancel()
                showSuccess = false
            }
        }
        .onDisappear { successTask?.cancel() }
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
            // Sync ring: WHITE while syncing, GREEN for ~2s on success (then clears), RED when the
            // server is unreachable, none when idle. Drawn ON the avatar's edge (not outside) so the
            // colours sit on the coloured avatar at high contrast — white especially would vanish
            // against the cream background.
            .overlay(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(ringColor ?? .clear, lineWidth: ringColor == nil ? 0 : 1.25)
            )
            .shadow(color: base.opacity(0.45), radius: 7, x: 0, y: 6)
            .animation(.easeInOut(duration: 0.3), value: syncStatus)
            .animation(.easeInOut(duration: 0.35), value: showSuccess)
    }

    /// Avatar ring colour: white while syncing, green during the post-success flash, red when the
    /// server is unreachable, nil (no ring) when idle/connected.
    private var ringColor: Color? {
        switch syncStatus {
        case .syncing:          return .white
        case .offline, .error:  return Palette.alert
        case .idle:             return showSuccess ? Color(hex: hex("#2EAD5A")) : nil
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
