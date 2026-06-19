import SwiftUI
import SwiftData

/// Profile detail / edit / delete screen (F7). Bound to `ProfilesStore` over a single
/// profile resolved by `profileId`. Mirrors the Settings chrome (cream background,
/// `SheetHeader`, a `ScrollView` of grouped `Card`s) and the `AddProfileView` accent
/// picker. Sections: a palette hero (switch-to-active / "Active" pill), editable
/// details (name / type / business ABN+GST / accent), real per-profile stats derived
/// via `FetchDescriptor<Transaction>`, and a Manage group (export link + delete with a
/// `confirmationDialog` gated on the last/active-profile rules in `ProfilesStore.delete`).
struct ProfileDetailView: View {
    let profiles: ProfilesStore
    let sync: any SyncEnqueuing
    let profileId: String
    let onClose: () -> Void
    let onExport: () -> Void

    // Local edit mirrors (committed to ProfilesStore.update on change / commit).
    @State private var nameText = ""
    @State private var abnText = ""
    @State private var didLoad = false
    @State private var showDeleteConfirm = false
    @State private var deleteBlockedNote: String?

    private var profile: Profile? {
        profiles.profiles.first { $0.id == profileId }
    }

    private var isActive: Bool { profileId == profiles.activeProfileId }

    /// The accent triad parsed from the profile's stored hexes.
    private func palette(_ p: Profile) -> AccentPalette {
        AccentPalette(
            base: Color(hex: hex(p.accent1)),
            soft: Color(hex: hex(p.accent2)),
            deep: Color(hex: hex(p.accent3))
        )
    }

    /// Match the profile's stored base hex back to a canonical swatch (so the picker
    /// shows the selected ring), falling back to the profile's own hexes.
    private func currentSwatch(_ p: Profile) -> AccentSwatch {
        let base = p.accent1.lowercased()
        if let match = AP_ACCENTS.first(where: { $0.base.lowercased() == base }) {
            return match
        }
        return AccentSwatch(
            id: "current", name: "Current",
            base: p.accent1, soft: p.accent2, deep: p.accent3,
            palette: palette(p)
        )
    }

    var body: some View {
        ZStack {
            Palette.cream.ignoresSafeArea()
            VStack(spacing: 0) {
                SheetHeader(title: "Profile", onClose: onClose)
                if let p = profile {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            hero(p)
                            details(p)
                            stats(p)
                            manage(p)
                        }
                        .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 60)
                    }
                    .keyboardDismissButton() // hide-keyboard accessory for name / ABN fields
                } else {
                    Spacer()
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.profileDetailScreen)
        .transition(.opacity)
        .task {
            if !didLoad, let p = profile {
                nameText = p.name
                abnText = p.abn ?? ""
                didLoad = true
            }
        }
    }

    // MARK: - Hero

    @ViewBuilder private func hero(_ p: Profile) -> some View {
        let pal = palette(p)
        VStack(spacing: 16) {
            HStack(spacing: 14) {
                Text(initials(p.name))
                    .font(.display(21, .bold)).foregroundStyle(pal.deep)
                    .frame(width: 56, height: 56)
                    .background(.white.opacity(0.92),
                                in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.name.isEmpty ? "Untitled profile" : p.name)
                        .font(.display(21, .bold)).foregroundStyle(.white).lineLimit(1)
                    Text("\(p.type.capitalized) profile")
                        .font(.ui(13, .regular)).foregroundStyle(.white.opacity(0.82))
                }
                Spacer(minLength: 0)
                if isActive {
                    HStack(spacing: 4) {
                        Icon(name: "check", size: 13, color: .white, lineWidth: 2.4)
                        Text("Currently active").font(.ui(11.5, .bold)).foregroundStyle(.white)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.white.opacity(0.22), in: Capsule(style: .continuous))
                }
            }
            if !isActive {
                Button {
                    profiles.setActive(profileId)
                    onClose()
                } label: {
                    Text("Switch to this profile")
                        .font(.ui(15, .bold)).foregroundStyle(pal.deep)
                        .frame(maxWidth: .infinity).frame(height: 46)
                        .background(.white.opacity(0.92), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(AccessibilityID.profileDetailSwitch)
            }
        }
        .padding(20)
        .background(
            // The decorative circle is an OVERLAY (not a ZStack sibling) so its fixed 150pt
            // size can't inflate the background's layout height — previously it grew the
            // background to 150pt and the green bled ~27pt below the card, overlapping the
            // "Details" label beneath it.
            LinearGradient(colors: [pal.base, pal.deep],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .overlay(alignment: .topTrailing) {
                    Circle().fill(.white.opacity(0.08))
                        .frame(width: 150, height: 150)
                        .offset(x: 50, y: -60)
                        .allowsHitTesting(false)
                }
                .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        )
        .cardShadow()
    }

    // MARK: - Details (editable)

    @ViewBuilder private func details(_ p: Profile) -> some View {
        groupLabel("Details")
        Card {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("PROFILE NAME").font(.ui(11.5, .bold)).tracking(0.4).foregroundStyle(Palette.ink3)
                    TextField("e.g. Lumen Studio", text: $nameText)
                        .font(.ui(16, .regular))
                        .textInputAutocapitalization(.words)
                        .padding(12)
                        .background(Palette.paper2, in: RoundedRectangle(cornerRadius: 12))
                        .onSubmit { commitName(p) }
                        .accessibilityIdentifier(AccessibilityID.profileDetailNameField)
                }
                divider
                HStack {
                    Text("Type").font(.ui(14.5, .semibold)).foregroundStyle(Palette.ink2)
                    Spacer()
                    Text(p.type.capitalized).font(.ui(14.5, .bold)).foregroundStyle(Palette.ink)
                }
                if p.type == ProfileType.business.rawValue {
                    divider
                    VStack(alignment: .leading, spacing: 6) {
                        Text("ABN").font(.ui(11.5, .bold)).tracking(0.4).foregroundStyle(Palette.ink3)
                        TextField("12 345 678 901", text: $abnText)
                            .font(.ui(16, .regular))
                            .keyboardType(.numbersAndPunctuation)
                            .padding(12)
                            .background(Palette.paper2, in: RoundedRectangle(cornerRadius: 12))
                            .onSubmit { commitAbn(p) }
                    }
                    divider
                    Toggle("Registered for GST", isOn: Binding(
                        get: { p.gstRegistered },
                        set: { newValue in profiles.update(p) { $0.gstRegistered = newValue } }))
                        .toggleStyle(MiniSwitchToggleStyle())
                        .font(.ui(14.5, .semibold)).foregroundStyle(Palette.ink2)
                }
                divider
                accentPicker(p)
            }
        }
    }

    @ViewBuilder private func accentPicker(_ p: Profile) -> some View {
        let selected = currentSwatch(p)
        VStack(alignment: .leading, spacing: 10) {
            Text("ACCENT COLOUR").font(.ui(11.5, .bold)).tracking(0.4).foregroundStyle(Palette.ink3)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                ForEach(AP_ACCENTS) { sw in
                    let isSelected = sw.base.lowercased() == selected.base.lowercased()
                    Circle()
                        .fill(Color(hex: hex(sw.base)))
                        .frame(width: 44, height: 44)
                        .overlay(Circle().stroke(Palette.ink, lineWidth: isSelected ? 3 : 0))
                        .overlay(Circle().stroke(Palette.line, lineWidth: isSelected ? 0 : 1))
                        .onTapGesture {
                            profiles.update(p) {
                                $0.accent1 = sw.base
                                $0.accent2 = sw.soft
                                $0.accent3 = sw.deep
                            }
                        }
                }
            }
        }
    }

    // MARK: - Stats (real, derived)

    @ViewBuilder private func stats(_ p: Profile) -> some View {
        let s = computeStats(for: p.id)
        let pal = palette(p)
        groupLabel("This profile")
        HStack(spacing: 12) {
            statPill(icon: "receipt", tint: pal.base, soft: pal.soft,
                     value: "\(s.count)", caption: "Receipts")
            statPill(icon: "shield", tint: Palette.income, soft: Palette.incomeSoft,
                     value: fmt(s.deductibleCents, showCents: false), caption: "Deductible YTD")
        }
    }

    private func statPill(icon: String, tint: Color, soft: Color, value: String, caption: String) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                IconCircle(name: icon, tint: tint, soft: soft, size: 38, iconSize: 19)
                VStack(alignment: .leading, spacing: 2) {
                    Text(value).numeric(20).foregroundStyle(Palette.ink)
                    Text(caption).font(.ui(12, .regular)).foregroundStyle(Palette.ink3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var divider: some View {
        Rectangle().fill(Palette.line2).frame(height: 1)
    }

    /// Real per-profile stats from non-deleted `Transaction` rows scoped to `profileId`:
    /// receipt count, total spent (sum of expense magnitudes), and deductible amount
    /// (expense magnitude × deductiblePct, default 100% when nil).
    private func computeStats(for pid: String) -> (count: Int, spentCents: Int, deductibleCents: Int) {
        let descriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate { $0.profileId == pid && $0.deletedAt == nil }
        )
        let txns = (try? profiles.context.fetch(descriptor)) ?? []
        var spent = 0
        var deductible = 0
        for t in txns where t.amountCents < 0 {
            let mag = -t.amountCents
            spent += mag
            let pct = t.deductiblePct ?? 100
            deductible += Int((Double(mag) * Double(pct) / 100.0).rounded())
        }
        return (txns.count, spent, deductible)
    }

    // MARK: - Manage (export + delete)

    @ViewBuilder private func manage(_ p: Profile) -> some View {
        groupLabel("Manage")
        Card(padding: 0) {
            VStack(spacing: 0) {
                Button(action: onExport) {
                    HStack(spacing: 12) {
                        IconCircle(name: "download", tint: palette(p).base, soft: palette(p).soft, size: 38, iconSize: 19)
                        Text("Export this profile").font(.ui(14.5, .semibold)).foregroundStyle(Palette.ink)
                        Spacer(); Icon(name: "chevR", size: 16, color: Palette.ink3)
                    }
                    .padding(14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Rectangle().fill(Palette.line2).frame(height: 1).padding(.leading, 64)
                Button {
                    deleteBlockedNote = nil
                    showDeleteConfirm = true
                } label: {
                    HStack(spacing: 12) {
                        IconCircle(name: "trash", tint: Palette.alert, soft: Palette.alert.opacity(0.12), size: 38, iconSize: 19)
                        Text("Delete profile").font(.ui(14.5, .semibold)).foregroundStyle(Palette.alert)
                        Spacer()
                    }
                    .padding(14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(AccessibilityID.profileDetailDelete)
            }
        }
        if let note = deleteBlockedNote {
            Text(note).font(.ui(12.5, .regular)).foregroundStyle(Palette.alert)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        Color.clear.frame(height: 0)
            .confirmationDialog("Delete this profile?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { attemptDelete(p) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes \(p.name) and stops syncing it to your other devices.")
            }
    }

    private func attemptDelete(_ p: Profile) {
        if profiles.delete(p) {
            onClose()
        } else if profiles.profiles.count <= 1 {
            deleteBlockedNote = "You can't delete your only profile."
        } else {
            deleteBlockedNote = "Switch to another profile first."
        }
    }

    // MARK: - Commit helpers

    private func commitName(_ p: Profile) {
        let trimmed = nameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != p.name else { return }
        profiles.update(p) { $0.name = trimmed }
    }

    private func commitAbn(_ p: Profile) {
        let trimmed = abnText.trimmingCharacters(in: .whitespacesAndNewlines)
        let newValue: String? = trimmed.isEmpty ? nil : trimmed
        guard newValue != p.abn else { return }
        profiles.update(p) { $0.abn = newValue }
    }

    // MARK: - Helpers

    private func groupLabel(_ s: String) -> some View {
        Text(s.uppercased()).font(.ui(12.5, .bold)).tracking(0.3).foregroundStyle(Palette.ink3)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
    }

    /// Up-to-two-letter uppercased initials from a profile name.
    private func initials(_ name: String) -> String {
        let words = name.split(separator: " ").prefix(2)
        let letters = words.compactMap { $0.first }.map(String.init).joined().uppercased()
        return letters.isEmpty ? "?" : letters
    }
}

#if DEBUG
#Preview {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: Profile.self, Transaction.self, configurations: config)
    let context = ModelContext(container)
    let p = Profile(userId: "u1", name: "Lumen Studio", type: "business",
                    accent1: "#0E7C72", accent2: "#DCF0ED", accent3: "#0A5950",
                    isDefault: true)
    context.insert(p)
    try? context.save()
    let store = ProfilesStore(context: context, sync: PreviewSync(), userId: "u1")
    return ProfileDetailView(profiles: store, sync: PreviewSync(),
                             profileId: p.id, onClose: {}, onExport: {})
}
#endif
