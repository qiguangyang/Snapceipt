import SwiftUI
import SwiftData

/// Smart-rule editor (F7). Creates or edits a `SmartRule` for the active profile via
/// `SmartRulesViewModel`. The target-category picker is sourced from
/// `CategoriesViewModel.categories`. Mirrors the app's overlay chrome: cream
/// background, `SheetHeader`, a grouped `Form`. Save routes to
/// `rulesVM.create(...)` (new) or `rulesVM.update(...)` (existing), then `onClose()`.
struct RuleEditorView: View {
    let context: ModelContext
    let sync: any SyncEnqueuing
    let userId: String
    let profileId: String
    let ruleId: String?
    let onClose: () -> Void

    @Environment(\.accent) private var accent
    @State private var rulesVM: SmartRulesViewModel?
    @State private var categoriesVM: CategoriesViewModel?

    // Editable mirrors.
    @State private var matchType = "merchant_contains"
    @State private var matcher = ""
    @State private var categoryId: String? = nil
    @State private var deductibleText = ""
    @State private var setMode = "none"        // "business" | "personal" | "none"
    @State private var enabled = true
    @State private var priority = 0
    @State private var loaded = false

    private let matchTypes: [(value: String, label: String)] = [
        ("merchant_contains", "Merchant contains"),
        ("merchant_equals", "Merchant equals"),
        ("merchant_regex", "Merchant matches (regex)"),
    ]
    private let modes: [(value: String, label: String)] = [
        ("none", "No change"),
        ("business", "Business"),
        ("personal", "Personal"),
    ]

    var body: some View {
        ZStack {
            Palette.cream.ignoresSafeArea()
            VStack(spacing: 0) {
                SheetHeader(title: ruleId == nil ? "New smart rule" : "Edit smart rule", onClose: onClose)
                if rulesVM != nil {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            matchSection
                            actionSection
                            optionsSection
                            saveButton
                        }
                        .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 60)
                    }
                } else { Color.clear }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.ruleEditorScreen)
        .transition(.opacity)
        .task {
            if rulesVM == nil {
                let rvm = SmartRulesViewModel(context: context, sync: sync, userId: userId, profileId: profileId)
                let cvm = CategoriesViewModel(context: context, sync: sync, userId: userId, profileId: profileId)
                if let id = ruleId, let existing = rvm.rules.first(where: { $0.id == id }), !loaded {
                    matchType = existing.matchType
                    matcher = existing.matcher
                    categoryId = existing.categoryId
                    deductibleText = existing.setDeductiblePct.map(String.init) ?? ""
                    setMode = existing.setMode ?? "none"
                    enabled = existing.enabled
                    priority = existing.priority
                    loaded = true
                }
                categoriesVM = cvm
                rulesVM = rvm
            }
        }
    }

    // MARK: - When

    @ViewBuilder private var matchSection: some View {
        groupLabel("When a receipt's merchant…")
        Card {
            VStack(alignment: .leading, spacing: 14) {
                menuRow(title: "Match", value: matchTypes.first { $0.value == matchType }?.label ?? matchType,
                        options: matchTypes.map(\.label)) { label in
                    if let m = matchTypes.first(where: { $0.label == label }) { matchType = m.value }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Text to match").font(.ui(12.5, .semibold)).foregroundStyle(Palette.ink3)
                    TextField("e.g. uber", text: $matcher)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .padding(12).background(Palette.paper2, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    // MARK: - Then

    @ViewBuilder private var actionSection: some View {
        groupLabel("Then apply")
        Card {
            VStack(alignment: .leading, spacing: 14) {
                menuRow(title: "Category", value: categoryLabel, options: categoryOptionLabels) { label in
                    selectCategory(label: label)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Deductible %").font(.ui(12.5, .semibold)).foregroundStyle(Palette.ink3)
                    TextField("leave blank to skip", text: $deductibleText)
                        .keyboardType(.numberPad)
                        .padding(12).background(Palette.paper2, in: RoundedRectangle(cornerRadius: 12))
                }
                menuRow(title: "Mode", value: modes.first { $0.value == setMode }?.label ?? setMode,
                        options: modes.map(\.label)) { label in
                    if let m = modes.first(where: { $0.label == label }) { setMode = m.value }
                }
            }
        }
    }

    // MARK: - Options

    @ViewBuilder private var optionsSection: some View {
        groupLabel("Options")
        Card {
            VStack(alignment: .leading, spacing: 14) {
                Toggle("Enabled", isOn: $enabled)
                    .font(.ui(14.5, .semibold)).foregroundStyle(Palette.ink)
                    .tint(accent.base)
                HStack {
                    Text("Priority").font(.ui(14.5, .semibold)).foregroundStyle(Palette.ink)
                    Spacer()
                    Text("\(priority)").font(.ui(14.5, .semibold)).foregroundStyle(accent.base)
                    Stepper("", value: $priority, in: 0...100).labelsHidden()
                }
            }
        }
    }

    // MARK: - Save

    @ViewBuilder private var saveButton: some View {
        Button(action: save) {
            Text("Save rule").font(.ui(15, .semibold)).foregroundStyle(Palette.paper)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(accent.base, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(matcher.trimmingCharacters(in: .whitespaces).isEmpty)
        .opacity(matcher.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
        .accessibilityIdentifier(AccessibilityID.ruleEditorSave)
        .padding(.top, 6)
    }

    private func save() {
        guard let rulesVM else { return }
        let trimmed = matcher.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let pct = Int(deductibleText.trimmingCharacters(in: .whitespaces))
        let mode: String? = setMode == "none" ? nil : setMode
        if let id = ruleId, let existing = rulesVM.rules.first(where: { $0.id == id }) {
            rulesVM.update(existing) {
                $0.matchType = matchType
                $0.matcher = trimmed
                $0.categoryId = categoryId
                $0.setDeductiblePct = pct
                $0.setMode = mode
                $0.enabled = enabled
                $0.priority = priority
            }
        } else {
            let created = rulesVM.create(matchType: matchType, matcher: trimmed,
                                         categoryId: categoryId, setDeductiblePct: pct, setMode: mode)
            rulesVM.update(created) { $0.enabled = enabled; $0.priority = priority }
        }
        onClose()
    }

    // MARK: - Category picker helpers

    private var categories: [Category] { categoriesVM?.categories ?? [] }

    private var categoryOptionLabels: [String] {
        ["No change"] + categories.map(\.label)
    }

    private var categoryLabel: String {
        guard let id = categoryId, let cat = categories.first(where: { $0.id == id }) else { return "No change" }
        return cat.label
    }

    private func selectCategory(label: String) {
        if label == "No change" { categoryId = nil; return }
        categoryId = categories.first(where: { $0.label == label })?.id
    }

    // MARK: - Helpers

    private func groupLabel(_ s: String) -> some View {
        Text(s).font(.ui(12.5, .semibold)).foregroundStyle(Palette.ink3)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
    }

    private func menuRow(title: String, value: String, options: [String], onSelect: @escaping (String) -> Void) -> some View {
        Menu {
            ForEach(options, id: \.self) { opt in Button(opt) { onSelect(opt) } }
        } label: {
            HStack {
                Text(title).font(.ui(14.5, .semibold)).foregroundStyle(Palette.ink)
                Spacer()
                Text(value).foregroundStyle(Palette.ink2).lineLimit(1)
                Icon(name: "chevD", size: 14, color: Palette.ink3)
            }
            .font(.ui(14.5))
        }
    }
}
