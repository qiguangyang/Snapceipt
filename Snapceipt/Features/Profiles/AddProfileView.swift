import SwiftUI
import SwiftData

/// Two-step "Add a profile": a form with live accent preview, then a success
/// screen. Persists optimistically (local-first) via `AddProfileViewModel.create`.
struct AddProfileView: View {
    @Bindable var vm: AddProfileViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if vm.didCreate { successStep } else { formStep }
        }
        .background(Palette.cream)
    }

    // MARK: Form

    private var formStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                preview
                typePicker
                field("Profile name") {
                    TextField("e.g. Lumen Studio", text: $vm.name)
                        .font(.ui(16, .regular))
                        .textInputAutocapitalization(.words)
                }
                if vm.type == .business {
                    field("ABN (optional)") {
                        TextField("12 345 678 901", text: $vm.abn)
                            .font(.ui(16, .regular))
                            .keyboardType(.numbersAndPunctuation)
                    }
                    Toggle(isOn: $vm.gstRegistered) {
                        Text("Registered for GST").font(.ui(15.5, .semibold))
                            .foregroundStyle(Palette.ink)
                    }
                    .tint(Color(hex: hex(vm.swatch.base)))
                    .padding(14)
                    .background(Palette.paper, in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
                }
                accentPicker
                createButton
            }
            .padding(18)
        }
    }

    private var preview: some View {
        let base = Color(hex: hex(vm.swatch.base))
        let deep = Color(hex: hex(vm.swatch.deep))
        return HStack(spacing: 12) {
            Text(vm.derivedInitials.isEmpty ? "?" : vm.derivedInitials)
                .font(.display(17, .bold)).foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(
                    LinearGradient(colors: [base, deep], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 15, style: .continuous)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(vm.name.isEmpty ? "New profile" : vm.name)
                    .font(.display(19, .bold)).foregroundStyle(Palette.ink)
                Text(vm.type.label).font(.ui(12.5, .regular)).foregroundStyle(Palette.ink3)
            }
            Spacer()
        }
        .padding(16)
        .background(Palette.paper, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .cardShadow()
    }

    private var typePicker: some View {
        Picker("Type", selection: $vm.type) {
            ForEach(ProfileType.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
    }

    private var accentPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ACCENT").font(.ui(11.5, .bold)).tracking(0.4).foregroundStyle(Palette.ink3)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                ForEach(AP_ACCENTS) { sw in
                    let selected = sw.id == vm.swatch.id
                    Circle()
                        .fill(Color(hex: hex(sw.base)))
                        .frame(width: 44, height: 44)
                        .overlay(Circle().stroke(Palette.ink, lineWidth: selected ? 3 : 0))
                        .overlay(Circle().stroke(Palette.line, lineWidth: selected ? 0 : 1))
                        .onTapGesture { vm.swatch = sw }
                }
            }
        }
        .padding(16)
        .background(Palette.paper, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .cardShadow()
    }

    private func field<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased()).font(.ui(11.5, .bold)).tracking(0.4).foregroundStyle(Palette.ink3)
            content()
                .padding(14)
                .background(Palette.paper, in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.inner, style: .continuous).stroke(Palette.line, lineWidth: 1))
        }
    }

    private var createButton: some View {
        Button { _ = vm.create() } label: {
            Text("Create profile")
                .font(.ui(17, .bold)).foregroundStyle(.white)
                .frame(maxWidth: .infinity).frame(height: 56)
                .background(Color(hex: hex(vm.swatch.base)),
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!vm.isValid)
        .opacity(vm.isValid ? 1 : 0.5)
    }

    // MARK: Success

    private var successStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64, weight: .bold))
                .foregroundStyle(Color(hex: hex(vm.swatch.base)))
            Text("Profile created")
                .font(.display(24, .bold)).foregroundStyle(Palette.ink)
            Text("\(vm.createdProfile?.name ?? "") is now your active profile.")
                .font(.ui(14.5, .regular)).foregroundStyle(Palette.ink2)
                .multilineTextAlignment(.center)
            Button { dismiss() } label: {
                Text("Done").font(.ui(16, .bold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 54)
                    .background(Color(hex: hex(vm.swatch.base)),
                                in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.top, 14)
        }
        .padding(30)
        .frame(maxHeight: .infinity)
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
