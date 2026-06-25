import SwiftUI
import SwiftData

/// Two-step "Add a profile": a form with a live gradient preview, then a success
/// screen. Persists optimistically (local-first) via `AddProfileViewModel.create`.
struct AddProfileView: View {
    /// Owned in `@State` so the view-model survives the shell's re-renders. Creating
    /// a profile activates it, which mutates the observed `ProfilesStore` and re-renders
    /// RootView; if the VM were rebuilt on each render the `didCreate` success step would
    /// be wiped back to an empty form (J26 scoping probe). `@State` pins it to this view's
    /// identity for the sheet's lifetime.
    @State private var vm: AddProfileViewModel
    @Environment(\.dismiss) private var dismiss

    init(vm: AddProfileViewModel) {
        _vm = State(wrappedValue: vm)
    }

    /// The accent the chosen swatch resolves to (drives the live preview + buttons).
    private var base: Color { Color(hex: hex(vm.swatch.base)) }
    private var deep: Color { Color(hex: hex(vm.swatch.deep)) }

    var body: some View {
        Group {
            if vm.didCreate { successStep } else { formStep }
        }
        .background(Palette.cream)
    }

    // MARK: - Form

    private var formStep: some View {
        ZStack(alignment: .top) {
            Palette.cream.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    preview
                    typePicker
                    detailsGroup
                    businessDetailsGroup
                    accentPicker
                    infoNote
                }
                .padding(.horizontal, 18).padding(.top, 70).padding(.bottom, 120)
            }
            .keyboardDismissButton() // hide-keyboard accessory for name + ABN fields
            header
            createBar
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Button { dismiss() } label: {
                Icon(name: "arrowLeft", size: 19, color: Palette.ink2)
                    .frame(width: 40, height: 40)
                    .background(Palette.paper, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.line, lineWidth: 1))
            }
            .buttonStyle(.plain)
            Spacer()
            Text("New profile").font(.ui(16, .bold)).foregroundStyle(Palette.ink)
            Spacer()
            Color.clear.frame(width: 40, height: 40)
        }
        .padding(.horizontal, 18).padding(.top, 14)
    }

    // MARK: - Live preview

    private var preview: some View {
        HStack(spacing: 14) {
            Text(vm.derivedInitials.isEmpty ? "?" : vm.derivedInitials)
                .font(.display(20, .bold)).foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(
                    .white.opacity(0.2),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
            VStack(alignment: .leading, spacing: 3) {
                Text(vm.name.isEmpty ? "New profile" : vm.name)
                    .font(.display(18, .bold)).foregroundStyle(.white).lineLimit(1)
                Text(previewSubtitle)
                    .font(.ui(12.5, .regular)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(vm.type == .business ? "Business" : "Personal")
                .font(.ui(11.5, .bold)).foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(.white.opacity(0.2), in: Capsule(style: .continuous))
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(colors: [base, deep], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        )
        .overlay(alignment: .topTrailing) {
            // Decorative translucent circle (above the gradient, below the text row,
            // and non-interactive).
            Circle().fill(.white.opacity(0.08))
                .frame(width: 110, height: 110)
                .offset(x: 36, y: -42)
                .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .cardShadow()
    }

    private var previewSubtitle: String {
        if vm.type == .business {
            let trimmed = vm.abn.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? "Business profile" : "ABN \(trimmed)"
        }
        return "Personal profile"
    }

    // MARK: - Profile type

    private var typePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            groupLabel("Profile type")
            VStack(spacing: 10) {
                typeCard(.personal,
                         icon: "wallet",
                         tint: AccentPalette.personal.base,
                         soft: AccentPalette.personal.soft,
                         subtitle: "Everyday spending & budgets")
                typeCard(.business,
                         icon: "building",
                         tint: AccentPalette.business.base,
                         soft: AccentPalette.business.soft,
                         subtitle: "ABN, GST & tax deductions")
            }
        }
    }

    private func typeCard(_ type: ProfileType, icon: String, tint: Color, soft: Color, subtitle: String) -> some View {
        let selected = vm.type == type
        return Button { vm.type = type } label: {
            HStack(spacing: 12) {
                IconCircle(name: icon, tint: tint, soft: soft, size: 44, iconSize: 21, filled: false)
                VStack(alignment: .leading, spacing: 2) {
                    Text(type.label).font(.ui(15.5, .bold)).foregroundStyle(Palette.ink)
                    Text(subtitle).font(.ui(12.5, .regular)).foregroundStyle(Palette.ink2)
                }
                Spacer(minLength: 8)
                radio(selected: selected, tint: tint)
            }
            .padding(14)
            .background(selected ? soft : Palette.paper,
                        in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.inner, style: .continuous)
                    .strokeBorder(selected ? tint : Palette.line, lineWidth: selected ? 1.5 : 1)
                    .allowsHitTesting(false)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Expose each card as a button labelled exactly "Personal"/"Business" so the
        // XCUI suite (which taps `buttons["Business"]`) and VoiceOver get one clear
        // element instead of the concatenated title + subtitle.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(type.label)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    /// 22pt radio: a ring, filled with a tint disc + white check when selected.
    private func radio(selected: Bool, tint: Color) -> some View {
        ZStack {
            Circle()
                .strokeBorder(selected ? tint : Palette.line, lineWidth: selected ? 0 : 2)
                .background(Circle().fill(selected ? tint : Color.clear))
                .frame(width: 22, height: 22)
            if selected {
                Icon(name: "check", size: 12, color: .white, lineWidth: 2.4)
            }
        }
    }

    // MARK: - Details

    private var detailsGroup: some View {
        VStack(alignment: .leading, spacing: 10) {
            groupLabel("Details")
            Card {
                VStack(alignment: .leading, spacing: 14) {
                    apField(label: "Profile name") {
                        TextField("e.g. Lumen Studio", text: $vm.name)
                            .font(.ui(16, .regular)).foregroundStyle(Palette.ink)
                            .textInputAutocapitalization(.words)
                            .accessibilityIdentifier(AccessibilityID.addProfileName)
                    }
                    if vm.type == .business {
                        Rectangle().fill(Palette.line2).frame(height: 1)
                        apField(label: "ABN (optional)") {
                            TextField("12 345 678 901", text: $vm.abn)
                                .font(.ui(16, .regular)).foregroundStyle(Palette.ink)
                                .keyboardType(.numbersAndPunctuation)
                        }
                        Rectangle().fill(Palette.line2).frame(height: 1)
                        gstRow
                    }
                }
            }
        }
    }

    @ViewBuilder private var businessDetailsGroup: some View {
        if vm.type == .business {
            VStack(alignment: .leading, spacing: 10) {
                groupLabel("Business details (optional)")
                Card {
                    VStack(alignment: .leading, spacing: 14) {
                        apField(label: "Business email") {
                            TextField("you@business.com", text: $vm.businessEmail)
                                .font(.ui(16, .regular)).foregroundStyle(Palette.ink)
                                .keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                                .accessibilityIdentifier(AccessibilityID.addProfileBusinessEmail)
                        }
                        Rectangle().fill(Palette.line2).frame(height: 1)
                        apField(label: "Phone") {
                            TextField("0400 000 000", text: $vm.phone)
                                .font(.ui(16, .regular)).foregroundStyle(Palette.ink)
                                .keyboardType(.phonePad)
                                .accessibilityIdentifier(AccessibilityID.addProfileBusinessPhone)
                        }
                        Rectangle().fill(Palette.line2).frame(height: 1)
                        apField(label: "Website") {
                            TextField("yourbusiness.com", text: $vm.website)
                                .font(.ui(16, .regular)).foregroundStyle(Palette.ink)
                                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                                .accessibilityIdentifier(AccessibilityID.addProfileBusinessWebsite)
                        }
                        Rectangle().fill(Palette.line2).frame(height: 1)
                        apField(label: "Address") {
                            TextField("Street, suburb, state", text: $vm.address, axis: .vertical)
                                .lineLimit(2...4)
                                .font(.ui(16, .regular)).foregroundStyle(Palette.ink)
                                .accessibilityIdentifier(AccessibilityID.addProfileBusinessAddress)
                        }
                        Rectangle().fill(Palette.line2).frame(height: 1)
                        apField(label: "Bank / payment details") {
                            TextField("BSB + account, PayID, or international", text: $vm.bankDetails, axis: .vertical)
                                .lineLimit(2...4)
                                .font(.ui(16, .regular)).foregroundStyle(Palette.ink)
                                .accessibilityIdentifier(AccessibilityID.addProfileBankDetails)
                        }
                    }
                }
            }
        }
    }

    private var gstRow: some View {
        HStack(spacing: 12) {
            IconCircle(name: "shield", tint: Palette.income, soft: Palette.incomeSoft,
                       size: 40, iconSize: 19)
            VStack(alignment: .leading, spacing: 2) {
                Text("Registered for GST").font(.ui(14.5, .semibold)).foregroundStyle(Palette.ink)
                Text("Track GST on every receipt").font(.ui(12, .regular)).foregroundStyle(Palette.ink2)
            }
            Spacer(minLength: 8)
            MiniSwitch(isOn: $vm.gstRegistered)
        }
    }

    private func apField<Content: View>(label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased()).font(.ui(11.5, .bold)).tracking(0.4).foregroundStyle(Palette.ink3)
            content()
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.paper2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    // MARK: - Accent

    private var accentPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            groupLabel("Accent colour")
            Card {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                    ForEach(AP_ACCENTS) { sw in
                        let selected = sw.id == vm.swatch.id
                        Button { vm.swatch = sw } label: {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(LinearGradient(
                                    colors: [Color(hex: hex(sw.base)), Color(hex: hex(sw.deep))],
                                    startPoint: .topLeading, endPoint: .bottomTrailing))
                                .frame(width: 44, height: 44)
                                .overlay(
                                    // Double ring on selection: a paper gap + an ink ring.
                                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                                        .stroke(Palette.ink, lineWidth: selected ? 2 : 0)
                                        .padding(-4)
                                        .allowsHitTesting(false)
                                )
                                .overlay {
                                    if selected {
                                        Icon(name: "check", size: 16, color: .white, lineWidth: 2.4)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(sw.name)
                        .accessibilityAddTraits(selected ? [.isSelected] : [])
                    }
                }
            }
        }
    }

    // MARK: - Info note

    private var infoNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Icon(name: "info", size: 16, color: Palette.ink3)
                .padding(.top, 1)
            Text(vm.type == .business
                 ? "We'll set up tax categories (GST, deductions) for this profile. You can change them later."
                 : "We'll set up everyday categories for this profile. You can change them later.")
                .font(.ui(12.5, .regular)).foregroundStyle(Palette.ink2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(Palette.paper2, in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
    }

    // MARK: - Create bar

    private var createBar: some View {
        VStack {
            Spacer()
            Button { _ = vm.create() } label: {
                HStack(spacing: 8) {
                    Icon(name: "plus", size: 19, color: .white, lineWidth: 2.2)
                    Text("Create profile").font(.ui(17, .bold)).foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity).frame(height: 56)
                .background(vm.isValid ? base : Palette.line,
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .foregroundStyle(vm.isValid ? .white : Palette.ink3)
                .shadow(color: base.opacity(vm.isValid ? 0.4 : 0), radius: 12, x: 0, y: 10)
            }
            .buttonStyle(.plain)
            .disabled(!vm.isValid)
            .accessibilityIdentifier(AccessibilityID.addProfileCreate)
            .padding(.horizontal, 18).padding(.bottom, 20)
        }
        .background(
            LinearGradient(colors: [Palette.cream.opacity(0), Palette.cream],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 130).frame(maxHeight: .infinity, alignment: .bottom)
                .allowsHitTesting(false)
        )
    }

    // MARK: - Helpers

    private func groupLabel(_ s: String) -> some View {
        Text(s.uppercased()).font(.ui(12.5, .bold)).tracking(0.3).foregroundStyle(Palette.ink3)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Success

    private var successStep: some View {
        VStack(spacing: 16) {
            Text(vm.derivedInitials.isEmpty ? "?" : vm.derivedInitials)
                .font(.display(34, .bold)).foregroundStyle(.white)
                .frame(width: 92, height: 92)
                .background(
                    LinearGradient(colors: [base, deep], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 28, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .strokeBorder(.white.opacity(0.5), lineWidth: 3)
                        .padding(-5)
                        .allowsHitTesting(false)
                )
            // Exact title kept as "Profile created" (no exclamation): the XCUI suite
            // asserts `staticTexts["Profile created"]` by exact label.
            Text("Profile created")
                .font(.display(24, .bold)).foregroundStyle(Palette.ink)
            Text("\(vm.createdProfile?.name ?? "") is now your active profile.")
                .font(.ui(14.5, .regular)).foregroundStyle(Palette.ink2)
                .multilineTextAlignment(.center)
            Button { dismiss() } label: {
                Text("Done").font(.ui(16, .bold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 54)
                    .background(base, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.top, 14)
        }
        .padding(30)
        .frame(maxHeight: .infinity)
    }
}

/// The design's "MiniSwitch": a 46×28 pill, ON track = `Palette.income`, OFF track =
/// `Palette.line`, with a 22pt white knob that slides between ends.
private struct MiniSwitch: View {
    @Binding var isOn: Bool
    var body: some View {
        Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) { isOn.toggle() }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? Palette.income : Palette.line)
                    .frame(width: 46, height: 28)
                Circle().fill(.white)
                    .frame(width: 22, height: 22)
                    .shadow(color: Palette.ink.opacity(0.18), radius: 2, x: 0, y: 1)
                    .padding(.horizontal, 3)
            }
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
    let vm = AddProfileViewModel(store: store, context: context, userId: "u1")
    return AddProfileView(vm: vm)
}
#endif
