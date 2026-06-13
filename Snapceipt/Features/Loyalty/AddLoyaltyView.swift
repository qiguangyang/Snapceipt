import SwiftUI
import SwiftData

/// Full-screen add-loyalty-card overlay. Scan CTA presents the live scanner (prefills
/// number + format); a searchable brand grid (catalog + Custom) reveals the number
/// field; Add-to-wallet is disabled until a brand is chosen. Save -> create + enqueue
/// -> animated success -> onSaved (back to the wallet).
struct AddLoyaltyView: View {
    let context: ModelContext
    let sync: any SyncEnqueuing
    let userId: String
    let profileId: String
    let onClose: () -> Void
    let onSaved: () -> Void

    @Environment(\.accent) private var accent
    @State private var vm: AddLoyaltyViewModel?
    @State private var showScanner = false
    @State private var saved = false

    private let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        ZStack(alignment: .bottom) {
            Palette.cream.ignoresSafeArea()
            VStack(spacing: 0) {
                SheetHeader(title: "Add a card", onClose: onClose)
                if let vm { content(vm) } else { Color.clear }
            }
            if let vm { saveBar(vm) }
            if saved { successOverlay }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.loyaltyAddScreen)
        .transition(.opacity)
        .task { if vm == nil { vm = AddLoyaltyViewModel(context: context, sync: sync, userId: userId, profileId: profileId) } }
        .sheet(isPresented: $showScanner) {
            if LoyaltyBarcodeScanner.isAvailable {
                LoyaltyBarcodeScanner { value, format in
                    vm?.number = value
                    vm?.scannedFormat = format
                    showScanner = false
                }
                .ignoresSafeArea()
            } else {
                // No camera (e.g. simulator) -> dismiss back to manual entry, no crash.
                Color.clear.onAppear { showScanner = false }
            }
        }
    }

    @ViewBuilder private func content(_ vm: AddLoyaltyViewModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                scanButton
                TextField("Search brands", text: Binding(get: { vm.search }, set: { vm.search = $0 }))
                    .padding(12).background(Palette.paper, in: RoundedRectangle(cornerRadius: 12))
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(vm.filteredBrands) { brand in
                        brandTile(brand, selected: vm.selectedBrand?.key == brand.key) {
                            vm.selectedBrand = brand
                        }
                    }
                }
                if vm.selectedBrand?.key == "custom" {
                    field("Brand name", text: Binding(get: { vm.customName }, set: { vm.customName = $0 }))
                }
                if vm.selectedBrand != nil {
                    numberField(vm)
                }
            }
            .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 160)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var scanButton: some View {
        Button { showScanner = true } label: {
            HStack(spacing: 8) {
                Icon(name: "camera", size: 18, color: .white)
                Text("Scan card barcode").font(.ui(15, .semibold)).foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(Palette.ink, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AccessibilityID.loyaltyAddScan)
    }

    @ViewBuilder private func brandTile(_ brand: LoyaltyBrand, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(LinearGradient(colors: [brand.c1, brand.c2], startPoint: .topLeading, endPoint: .bottomTrailing))
                    Text(brand.monogram).font(.ui(18, .bold)).foregroundStyle(.white)
                }
                .frame(height: 54)
                Text(brand.name).font(.ui(11.5, .semibold)).foregroundStyle(Palette.ink2)
                    .lineLimit(1)
            }
            .padding(6)
            .background(Palette.paper, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(selected ? accent.base : Palette.line2, lineWidth: selected ? 2 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AccessibilityID.loyaltyAddBrandPrefix + brand.key)
    }

    @ViewBuilder private func numberField(_ vm: AddLoyaltyViewModel) -> some View {
        let brand = vm.selectedBrand
        VStack(alignment: .leading, spacing: 4) {
            Text((brand.map { $0.key == "custom" ? "Member" : $0.name } ?? "Member") + " number")
                .font(.ui(12.5, .semibold)).foregroundStyle(Palette.ink3)
            HStack(spacing: 10) {
                if let brand {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(LinearGradient(colors: [brand.c1, brand.c2], startPoint: .topLeading, endPoint: .bottomTrailing))
                        Text(brand.monogram).font(.ui(12, .bold)).foregroundStyle(.white)
                    }
                    .frame(width: 30, height: 30)
                }
                TextField("Number", text: Binding(get: { vm.number }, set: { vm.number = $0 }))
                    .keyboardType(.numbersAndPunctuation)
                    .accessibilityIdentifier(AccessibilityID.loyaltyAddNumber)
            }
            .padding(12).background(Palette.paper, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.ui(12.5, .semibold)).foregroundStyle(Palette.ink3)
            TextField(title, text: text)
                .padding(12).background(Palette.paper, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    @ViewBuilder private func saveBar(_ vm: AddLoyaltyViewModel) -> some View {
        Button {
            // sortOrder = end of the current wallet for this profile.
            let wallet = LoyaltyWalletViewModel(context: context, sync: sync, userId: userId, profileId: profileId)
            if vm.save(sortOrder: wallet.nextSortOrder()) != nil {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { saved = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { onSaved() }
            }
        } label: {
            Text("Add to wallet").font(.ui(16, .semibold)).foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(vm.canSave ? accent.base : Palette.ink3,
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!vm.canSave)
        .padding(.horizontal, 18).padding(.bottom, 26)
        .accessibilityIdentifier(AccessibilityID.loyaltyAddSave)
    }

    private var successOverlay: some View {
        ZStack {
            Palette.cream.opacity(0.96).ignoresSafeArea()
            VStack(spacing: 14) {
                ZStack {
                    Circle().fill(Palette.income).frame(width: 72, height: 72)
                    Icon(name: "check", size: 34, color: .white, lineWidth: 3)
                }
                Text("Card added!").font(.display(20, .bold)).foregroundStyle(Palette.ink)
            }
        }
        .transition(.opacity)
    }
}
