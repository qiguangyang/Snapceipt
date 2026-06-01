import SwiftUI
import SwiftData

/// Categories & smart-rules screen (F7). Bound to `CategoriesViewModel`
/// (built-in category rows + live receipt counts + editable default deductible %)
/// and `SmartRulesViewModel` (the profile's auto-categorization rules). Mirrors
/// `NotificationsSettingsView`/`TaxSettingsView` chrome: cream background,
/// `SheetHeader`, a `ScrollView` of grouped `Card`s.
struct CategoriesView: View {
    let context: ModelContext
    let sync: any SyncEnqueuing
    let userId: String
    let profileId: String
    let onEditRule: (String?) -> Void
    let onClose: () -> Void

    @Environment(\.accent) private var accent
    @State private var vm: CategoriesViewModel?
    @State private var rulesVM: SmartRulesViewModel?

    var body: some View {
        ZStack {
            Palette.cream.ignoresSafeArea()
            VStack(spacing: 0) {
                SheetHeader(title: "Categories & rules", onClose: onClose)
                if let vm, let rulesVM {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            categoriesSection(vm)
                            rulesSection(rulesVM)
                        }
                        .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 60)
                    }
                } else { Color.clear }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.categoriesScreen)
        .transition(.opacity)
        .task {
            if vm == nil {
                vm = CategoriesViewModel(context: context, sync: sync, userId: userId, profileId: profileId)
            }
            if rulesVM == nil {
                rulesVM = SmartRulesViewModel(context: context, sync: sync, userId: userId, profileId: profileId)
            }
        }
    }

    // MARK: - Categories

    @ViewBuilder private func categoriesSection(_ vm: CategoriesViewModel) -> some View {
        groupLabel("Categories")
        Card {
            VStack(spacing: 14) {
                ForEach(Array(vm.categories.enumerated()), id: \.element.id) { idx, cat in
                    categoryRow(vm, cat)
                    if idx < vm.categories.count - 1 {
                        Rectangle().fill(Palette.line2).frame(height: 1)
                    }
                }
            }
        }
    }

    @ViewBuilder private func categoryRow(_ vm: CategoriesViewModel, _ cat: Category) -> some View {
        let meta = CategoryKey(rawValue: cat.key).flatMap { CATS[$0] }
        HStack(spacing: 12) {
            IconCircle(name: safeIcon(cat.icon),
                       tint: meta?.tint ?? accent.base,
                       soft: meta?.soft ?? accent.soft,
                       size: 38, iconSize: 19)
            VStack(alignment: .leading, spacing: 2) {
                Text(cat.label).font(.ui(14.5, .semibold)).foregroundStyle(Palette.ink).lineLimit(1)
                Text(receiptCountLabel(vm.receiptCount(cat)))
                    .font(.ui(12)).foregroundStyle(Palette.ink3)
            }
            Spacer(minLength: 8)
            deductibleMenu(vm, cat)
        }
        .accessibilityIdentifier(AccessibilityID.categoryRowPrefix + cat.id)
    }

    private func receiptCountLabel(_ n: Int) -> String {
        n == 1 ? "1 receipt" : "\(n) receipts"
    }

    @ViewBuilder private func deductibleMenu(_ vm: CategoriesViewModel, _ cat: Category) -> some View {
        Menu {
            ForEach([0, 25, 50, 75, 100], id: \.self) { pct in
                Button("\(pct)%") { vm.setDefaultDeductible(cat, pct: pct) }
            }
        } label: {
            HStack(spacing: 4) {
                Text(cat.defaultDeductiblePct.map { "\($0)%" } ?? "—")
                    .font(.ui(13.5, .semibold)).foregroundStyle(accent.base)
                Icon(name: "chevD", size: 12, color: Palette.ink3)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(accent.soft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    // MARK: - Smart rules

    @ViewBuilder private func rulesSection(_ rulesVM: SmartRulesViewModel) -> some View {
        HStack {
            groupLabel("Smart rules")
            Spacer()
            Button(action: { onEditRule(nil) }) {
                HStack(spacing: 4) {
                    Icon(name: "plus", size: 14, color: accent.base, lineWidth: 2.2)
                    Text("Add").font(.ui(13.5, .semibold)).foregroundStyle(accent.base)
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(AccessibilityID.ruleAddButton)
        }
        if rulesVM.rules.isEmpty {
            Card {
                Text("No smart rules yet. Add one to auto-categorise matching receipts.")
                    .font(.ui(13.5)).foregroundStyle(Palette.ink3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Card(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(rulesVM.rules.enumerated()), id: \.element.id) { idx, rule in
                        ruleRow(rulesVM, rule)
                        if idx < rulesVM.rules.count - 1 {
                            Rectangle().fill(Palette.line2).frame(height: 1).padding(.leading, 16)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func ruleRow(_ rulesVM: SmartRulesViewModel, _ rule: SmartRule) -> some View {
        HStack(spacing: 12) {
            Button(action: { onEditRule(rule.id) }) {
                HStack(spacing: 12) {
                    IconCircle(name: "receipt", tint: accent.base, soft: accent.soft, size: 34, iconSize: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(rule.matcher.isEmpty ? "Any" : rule.matcher)
                            .font(.ui(14, .semibold)).foregroundStyle(Palette.ink).lineLimit(1)
                        Text(ruleSubtitle(rule)).font(.ui(12)).foregroundStyle(Palette.ink3).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if !rule.enabled {
                        Text("Off").font(.ui(11.5, .semibold)).foregroundStyle(Palette.ink3)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Palette.paper2, in: Capsule())
                    }
                    Icon(name: "chevR", size: 16, color: Palette.ink3)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button(role: .destructive, action: { rulesVM.delete(rule) }) {
                Icon(name: "close", size: 16, color: Palette.alert)
                    .frame(width: 32, height: 32)
                    .background(Palette.paper2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete rule")
        }
        .padding(14)
        .accessibilityIdentifier(AccessibilityID.ruleRowPrefix + rule.id)
    }

    private func ruleSubtitle(_ rule: SmartRule) -> String {
        var parts: [String] = [matchTypeLabel(rule.matchType)]
        if let pct = rule.setDeductiblePct { parts.append("\(pct)% deductible") }
        if let mode = rule.setMode, !mode.isEmpty { parts.append(mode.capitalized) }
        return parts.joined(separator: " · ")
    }

    private func matchTypeLabel(_ t: String) -> String {
        switch t {
        case "merchant_equals": return "Merchant equals"
        case "merchant_regex": return "Merchant matches"
        default: return "Merchant contains"
        }
    }

    // MARK: - Helpers

    private func groupLabel(_ s: String) -> some View {
        Text(s).font(.ui(12.5, .semibold)).foregroundStyle(Palette.ink3)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
    }

    /// Some seeded category icons (e.g. "cup"/"cart"/"fuel") are theme.jsx glyphs not
    /// yet ported into `Icons.paths`; fall back to a present glyph so the tile renders.
    private func safeIcon(_ name: String) -> String {
        Icons.paths[name] != nil ? name : "receipt"
    }
}
