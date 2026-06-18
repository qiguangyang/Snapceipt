import SwiftUI
import SwiftData

/// Categories & smart-rules screen (F7). Bound to `CategoriesViewModel`
/// (built-in category rows + live receipt counts + editable default deductible %)
/// and `SmartRulesViewModel` (the profile's auto-categorization rules). Matches the
/// design's sub-page chrome: a header row with a trailing accent "+", a "Smart rules"
/// gradient banner, the rules `Card`, and a "Categories · {n}" group of category rows.
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
                header
                if let vm, let rulesVM {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            rulesBanner(rulesVM)
                            rulesSection(rulesVM)
                            categoriesSection(vm)
                        }
                        .padding(.horizontal, 18).padding(.top, 6).padding(.bottom, 60)
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

    // MARK: - Header

    /// Sub-page header: back button (keeps `logbookClose`) | centered title | trailing
    /// accent "+" (the rule-add control, keeps `ruleAddButton`).
    private var header: some View {
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

            Text("Categories & rules").font(.ui(16, .bold)).foregroundStyle(Palette.ink)
                .frame(maxWidth: .infinity).lineLimit(1)

            Button(action: { onEditRule(nil) }) {
                Icon(name: "plus", size: 20, color: Palette.paper, lineWidth: 2.2)
                    .frame(width: 40, height: 40)
                    .background(accent.base, in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
                    .cardShadow()
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(AccessibilityID.ruleAddButton)
        }
        .padding(.top, 12).padding(.horizontal, 18).padding(.bottom, 12)
    }

    // MARK: - Smart rules

    /// Gradient banner introducing the auto-file rules: accent-soft -> white wash,
    /// 1px accent border, sparkles glyph, "{n} active" pill.
    @ViewBuilder private func rulesBanner(_ rulesVM: SmartRulesViewModel) -> some View {
        let activeCount = rulesVM.rules.filter(\.enabled).count
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                IconCircle(name: "sparkles", tint: accent.base, soft: .white.opacity(0.6),
                           size: 34, iconSize: 18, filled: true)
                Text("Smart rules").font(.ui(15, .bold)).foregroundStyle(Palette.ink)
                Spacer(minLength: 8)
                Text("\(activeCount) active")
                    .font(.ui(11.5, .bold)).foregroundStyle(accent.deep)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.white.opacity(0.7), in: Capsule(style: .continuous))
            }
            Text("Snapceipt auto-files receipts that match these rules.")
                .font(.ui(12.5)).foregroundStyle(Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [accent.soft, Palette.paper],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(accent.base.opacity(0.45), lineWidth: 1)
                .allowsHitTesting(false)
        )
    }

    @ViewBuilder private func rulesSection(_ rulesVM: SmartRulesViewModel) -> some View {
        if rulesVM.rules.isEmpty {
            Card {
                Text("No smart rules yet. Tap + to auto-categorise matching receipts.")
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
        let meta = ruleCategoryMeta(rule)
        HStack(spacing: 12) {
            Button(action: { onEditRule(rule.id) }) {
                HStack(spacing: 12) {
                    IconCircle(name: meta.icon,
                               tint: meta.tint, soft: meta.soft, size: 38, iconSize: 18)
                    VStack(alignment: .leading, spacing: 3) {
                        // "If contains …" + the match keyword.
                        (Text(matchVerb(rule.matchType) + " ").foregroundStyle(Palette.ink2)
                            + Text(rule.matcher.isEmpty ? "anything" : rule.matcher).foregroundStyle(Palette.ink))
                            .font(.ui(14, .semibold)).lineLimit(1)
                        HStack(spacing: 6) {
                            // "→ {category label}" in the category tint.
                            Text("→ \(meta.label)")
                                .font(.ui(12.5, .semibold)).foregroundStyle(meta.tint).lineLimit(1)
                            if let note = ruleNote(rule) {
                                Text(note).font(.ui(12.5, .semibold)).foregroundStyle(Palette.income).lineLimit(1)
                            }
                        }
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

    /// "If contains" / "If equals" / "If matches" verb fragment for a rule's match type.
    private func matchVerb(_ t: String) -> String {
        switch t {
        case "merchant_equals": return "If equals"
        case "merchant_regex": return "If matches"
        default: return "If contains"
        }
    }

    /// Tail note (deductible % + mode) rendered in `income`; nil when neither is set.
    private func ruleNote(_ rule: SmartRule) -> String? {
        var parts: [String] = []
        if let pct = rule.setDeductiblePct { parts.append("· \(pct)%") }
        if let mode = rule.setMode, !mode.isEmpty { parts.append("· \(mode.capitalized)") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// The category metadata a rule resolves to (label + tint/icon), falling back to a
    /// neutral accent receipt tile when the rule has no target category.
    private func ruleCategoryMeta(_ rule: SmartRule)
        -> (label: String, icon: String, tint: Color, soft: Color) {
        if let id = rule.categoryId, let cat = vm?.categories.first(where: { $0.id == id }) {
            let meta = CategoryKey(rawValue: cat.key).flatMap { CATS[$0] }
            return (cat.label, safeIcon(cat.icon),
                    meta?.tint ?? accent.base, meta?.soft ?? accent.soft)
        }
        return ("No category", "receipt", accent.base, accent.soft)
    }

    // MARK: - Categories

    @ViewBuilder private func categoriesSection(_ vm: CategoriesViewModel) -> some View {
        groupLabel("Categories · \(vm.categories.count)")
        Card(padding: 0) {
            VStack(spacing: 0) {
                ForEach(Array(vm.categories.enumerated()), id: \.element.id) { idx, cat in
                    categoryRow(vm, cat)
                    if idx < vm.categories.count - 1 {
                        Rectangle().fill(Palette.line2).frame(height: 1).padding(.leading, 64)
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
            Icon(name: "chevR", size: 16, color: Palette.ink3)
        }
        .padding(14)
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

    // MARK: - Helpers

    private func groupLabel(_ s: String) -> some View {
        Text(s.uppercased()).font(.ui(12.5, .bold)).tracking(0.3).foregroundStyle(Palette.ink3)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
    }

    /// Some seeded category icons (e.g. "cup"/"cart"/"fuel") are theme.jsx glyphs not
    /// yet ported into `Icons.paths`; fall back to a present glyph so the tile renders.
    private func safeIcon(_ name: String) -> String {
        Icons.paths[name] != nil ? name : "receipt"
    }
}
