import SwiftUI
import SwiftData

/// The three first-run steps after the very first sign-in.
enum OnboardingStep { case profile, camera, notifications }

/// First-run flow: create the first profile, then prime Camera + Notifications.
///
/// The first-profile step is deliberately **self-contained** (an inline form that
/// creates a `Profile` `@Model` directly in the `ModelContext`) so onboarding does
/// not depend on the full Profiles UI (`ProfilesStore`/`AddProfileView`) shipped by
/// a later task. `RootView` detects "has a profile" by querying SwiftData, so once
/// the profile is inserted the root re-renders into the shell after priming.
struct OnboardingView: View {
    /// Called once the first profile exists and permissions have been primed.
    let onFinished: () -> Void
    var requester: PermissionRequesting = LivePermissionRequester()

    @State private var step: OnboardingStep = .profile

    var body: some View {
        ZStack {
            Palette.cream.ignoresSafeArea()
            switch step {
            case .profile:
                FirstProfileForm(onCreated: { withAnimation { step = .camera } })
            case .camera:
                PermissionPrimingView(kind: .camera, requester: requester) {
                    withAnimation { step = .notifications }
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            case .notifications:
                PermissionPrimingView(kind: .notifications, requester: requester) {
                    onFinished()
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
    }
}

// MARK: - First profile form (self-contained)

/// Minimal inline first-profile creator: name + Personal/Business type + an accent
/// pick. Inserts a default `Profile` into the `ModelContext` and enqueues it via the
/// `SyncEngine` if one is in the environment. Replaced/refined by the Profiles task.
private struct FirstProfileForm: View {
    let onCreated: () -> Void

    @Environment(\.modelContext) private var context
    @Environment(AuthStore.self) private var auth
    @Environment(SyncEngine.self) private var sync: SyncEngine?

    @State private var name = ""
    @State private var type: ProfileType = .personal
    @State private var accentIndex = 0
    @FocusState private var nameFocused: Bool

    /// Accent swatches offered at onboarding. The first two are the canonical
    /// personal/business presets; the rest are extra terracotta/teal-adjacent picks.
    private static let swatches: [(base: UInt32, soft: UInt32, deep: UInt32)] = [
        (0xE8602C, 0xFDEBE0, 0xC2461A), // personal terracotta
        (0x0E7C72, 0xDCF0ED, 0x0A5950), // business teal
        (0x3B6FE0, 0xE4ECFC, 0x274FB0), // blue
        (0x8A4FD6, 0xEEE6FB, 0x6A37AE), // violet
        (0xD64578, 0xFCE6EE, 0xAE2F5A), // pink
        (0xC79A1E, 0xFBF1D2, 0x9C7610), // gold
    ]

    private var accent: AccentPalette {
        let s = Self.swatches[accentIndex]
        return AccentPalette(base: Color(hex: s.base), soft: Color(hex: s.soft), deep: Color(hex: s.deep))
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            VStack(spacing: 10) {
                Text("Create your first profile")
                    .font(.display(24, .bold))
                    .foregroundStyle(Palette.ink)
                    .multilineTextAlignment(.center)
                Text("Profiles keep personal and work spending apart. You can add more later.")
                    .font(.ui(14))
                    .foregroundStyle(Palette.ink2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
            }
            .padding(.bottom, 26)

            VStack(alignment: .leading, spacing: 16) {
                TextField("Profile name", text: $name)
                    .font(.ui(16))
                    .focused($nameFocused)
                    .submitLabel(.done)
                    .padding(.horizontal, 14)
                    .frame(height: 52)
                    .background(Palette.paper, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Palette.line, lineWidth: 1)
                    )

                // Type
                HStack(spacing: 10) {
                    ForEach(ProfileType.allCases, id: \.self) { t in
                        Button { type = t } label: {
                            Text(t.label)
                                .font(.ui(15, .semibold))
                                .foregroundStyle(type == t ? .white : Palette.ink2)
                                .frame(maxWidth: .infinity, minHeight: 46)
                                .background(
                                    (type == t ? accent.base : Palette.paper),
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .stroke(Palette.line, lineWidth: type == t ? 0 : 1)
                                )
                        }
                    }
                }

                // Accent picker
                HStack(spacing: 12) {
                    ForEach(Self.swatches.indices, id: \.self) { i in
                        Button { accentIndex = i } label: {
                            Circle()
                                .fill(Color(hex: Self.swatches[i].base))
                                .frame(width: 34, height: 34)
                                .overlay(
                                    Circle().stroke(Palette.ink.opacity(accentIndex == i ? 0.9 : 0),
                                                    lineWidth: 2)
                                        .padding(-3)
                                )
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 22)

            Spacer(minLength: 0)

            Button(action: create) {
                Text("Continue")
                    .font(.ui(16, .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .background(accent.base, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .disabled(trimmedName.isEmpty)
            .opacity(trimmedName.isEmpty ? 0.5 : 1)
            .padding(.horizontal, 22)
            .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.accent, accent)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func create() {
        let cleanName = trimmedName
        guard !cleanName.isEmpty else { return }
        let userId = auth.session?.userId ?? ""
        let s = Self.swatches[accentIndex]
        let profile = Profile(
            userId: userId,
            name: cleanName,
            type: type.rawValue,
            initials: Self.initials(from: cleanName),
            accent1: hex(s.base),
            accent2: hex(s.soft),
            accent3: hex(s.deep),
            sortOrder: 0,
            isDefault: true,
            lastEditedDeviceId: nil
        )
        context.insert(profile)
        try? context.save()
        sync?.enqueue(op: "upsert", entityType: .profile, entity: profile)
        onCreated()
    }

    private func hex(_ value: UInt32) -> String {
        "#" + String(format: "%06X", value)
    }

    private static func initials(from name: String) -> String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first }.map(String.init)
        return letters.joined().uppercased()
    }
}

#if DEBUG
#Preview {
    OnboardingView(onFinished: {}, requester: NoopPermissionRequester())
        .environment(AuthStore(keychain: Keychain(service: "sc.preview")))
        .environment(\.accent, .personal)
        .modelContainer(makeSnapceiptContainer(inMemory: true))
}
#endif
