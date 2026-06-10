import SwiftUI
import SwiftData

/// Shared full-screen header with a back button + centered title and NO add button
/// (LbHeader always shows a "+"). Reused by the budget editor / alerts / settings screens.
struct SheetHeader: View {
    let title: String
    let onClose: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            Button(action: onClose) {
                Icon(name: "arrowLeft", size: 20, color: Palette.ink2)
                    .frame(width: 40, height: 40)
                    .background(Palette.paper, in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                        .strokeBorder(Palette.line, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(AccessibilityID.logbookClose)
            Text(title).font(.ui(16, .bold)).foregroundStyle(Palette.ink)
                .frame(maxWidth: .infinity).lineLimit(1)
            // Spacer matching the back button's width so the title stays centered.
            Color.clear.frame(width: 40, height: 40)
        }
        .padding(.top, 12).padding(.horizontal, 18).padding(.bottom, 12)
    }
}

/// Full-screen add/edit budget overlay. Scope picker (Whole profile | a category) ->
/// default label; cap amount (dollars -> cents); alert threshold % (default 90); period
/// read-only Monthly. Save -> create/update + enqueue; Delete when editing.
struct BudgetEditorView: View {
    let context: ModelContext
    let sync: any SyncEnqueuing
    let userId: String
    let profileId: String
    let budgetId: String?            // nil = add
    let onClose: () -> Void

    @Environment(\.accent) private var accent
    @State private var vm: BudgetListViewModel?
    @State private var editing: Budget?
    @State private var scopeCategory = false
    @State private var catKey: String = CategoryKey.meals.rawValue
    @State private var label = ""
    @State private var capText = ""
    @State private var threshold = 90.0

    private var categoryOptions: [SegmentOption] {
        [SegmentOption(id: "profile", label: "Whole profile"),
         SegmentOption(id: "category", label: "Category")]
    }
    @State private var scopeSelection = "profile"

    var body: some View {
        ZStack(alignment: .bottom) {
            Palette.cream.ignoresSafeArea()
            VStack(spacing: 0) {
                SheetHeader(title: budgetId == nil ? "New budget" : "Edit budget", onClose: onClose)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Segmented(options: categoryOptions, selection: $scopeSelection)
                            .accessibilityIdentifier(AccessibilityID.budgetEditorScopeProfile)
                        if scopeSelection == "category" { categoryPicker }
                        field("Label", text: $label)
                        capField
                        thresholdField
                        periodRow
                        if budgetId != nil { deleteButton }
                    }
                    .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 110)
                }
            }
            saveButton
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.budgetEditorScreen)
        .transition(.opacity)
        .onChange(of: scopeSelection) { _, v in scopeCategory = (v == "category"); applyDefaultLabel() }
        .onChange(of: catKey) { _, _ in applyDefaultLabel() }
        .task {
            if vm == nil {
                let model = BudgetListViewModel(context: context, sync: sync,
                                                userId: userId, profileId: profileId)
                vm = model
                if let id = budgetId, let b = model.budgets.first(where: { $0.id == id }) {
                    editing = b
                    scopeCategory = b.categoryId != nil
                    scopeSelection = scopeCategory ? "category" : "profile"
                    catKey = b.catKey ?? CategoryKey.meals.rawValue
                    label = b.label
                    capText = String(b.capCents / 100)
                    threshold = Double(b.alertThresholdPct)
                } else {
                    applyDefaultLabel()
                }
            }
        }
    }

    private var categoryPicker: some View {
        Menu {
            ForEach(CategoryKey.allCases, id: \.self) { key in
                Button(CATS[key]?.label ?? key.rawValue) { catKey = key.rawValue }
            }
        } label: {
            HStack {
                Text(CATS[CategoryKey(rawValue: catKey) ?? .meals]?.label ?? catKey)
                    .foregroundStyle(Palette.ink)
                Spacer(); Icon(name: "chevD", size: 14, color: Palette.ink3)
            }
            .padding(12).background(Palette.paper, in: RoundedRectangle(cornerRadius: 12))
        }
        .accessibilityIdentifier(AccessibilityID.budgetEditorScopeCategory)
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.ui(12.5, .semibold)).foregroundStyle(Palette.ink3)
            TextField(title, text: text)
                .padding(12).background(Palette.paper, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var capField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Monthly cap ($)").font(.ui(12.5, .semibold)).foregroundStyle(Palette.ink3)
            TextField("0", text: $capText).keyboardType(.numberPad)
                .padding(12).background(Palette.paper, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityIdentifier(AccessibilityID.budgetEditorCap)
        }
    }

    private var thresholdField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Alert at \(Int(threshold))%").font(.ui(12.5, .semibold)).foregroundStyle(Palette.ink3)
            Slider(value: $threshold, in: 50...100, step: 5)
                .tint(accent.base)
                .accessibilityIdentifier(AccessibilityID.budgetEditorThreshold)
        }
    }

    private var periodRow: some View {
        HStack { Text("Period").foregroundStyle(Palette.ink3); Spacer(); Text("Monthly").foregroundStyle(Palette.ink) }
            .font(.ui(13.5)).padding(.vertical, 4)
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            if let editing { vm?.delete(editing); onClose() }
        } label: {
            Text("Delete budget").font(.ui(14, .semibold)).foregroundStyle(Palette.alert)
                .frame(maxWidth: .infinity).padding(.vertical, 12)
        }
        .accessibilityIdentifier(AccessibilityID.budgetEditorDelete)
    }

    private var saveButton: some View {
        Button(action: save) {
            Text("Save").font(.ui(16, .semibold)).foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(accent.base, in: RoundedRectangle(cornerRadius: 16))
        }
        .padding(.horizontal, 18).padding(.bottom, 26)
        .accessibilityIdentifier(AccessibilityID.budgetEditorSave)
    }

    private func applyDefaultLabel() {
        guard label.isEmpty || isDefaultLabel(label) else { return }
        label = scopeCategory ? (CATS[CategoryKey(rawValue: catKey) ?? .meals]?.label ?? "Category")
                              : "Whole profile"
    }
    private func isDefaultLabel(_ s: String) -> Bool {
        s == "Whole profile" || CategoryKey.allCases.contains { CATS[$0]?.label == s }
    }

    private func save() {
        let capCents = (Int(capText) ?? 0) * 100
        let categoryId: String? = scopeCategory ? resolveCategoryId(catKey) : nil
        vm?.save(existing: editing, categoryId: categoryId,
                 catKey: scopeCategory ? catKey : nil,
                 label: label.isEmpty ? (scopeCategory ? catKey : "Whole profile") : label,
                 capCents: capCents, alertThresholdPct: Int(threshold))
        onClose()
    }

    /// Resolve the active profile's Category.id for a catKey (nil if none exists yet —
    /// the budget still scopes by catKey for display; spend uses categoryId when set).
    private func resolveCategoryId(_ key: String) -> String? {
        let pid = profileId
        var d = FetchDescriptor<Category>(predicate: #Predicate { $0.profileId == pid && $0.key == key && $0.deletedAt == nil })
        d.fetchLimit = 1
        return (try? context.fetch(d))?.first?.id
    }
}
