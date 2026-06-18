import SwiftUI
import SwiftData

/// The Activity tab — the active profile's saved receipts, matching the design's
/// Transactions screen: a month picker, search, All/Expenses/Income filter chips, a
/// count + net summary, and rows grouped by day into shared cards. Reloads on appear
/// so a just-saved receipt shows immediately.
struct ActivityTabView: View {
    let context: ModelContext
    let profileId: String
    let onOpenReceipt: (String) -> Void
    let onSnap: () -> Void
    @Environment(\.accent) private var accent
    @State private var vm: ReceiptsListViewModel?
    @State private var query = ""
    @State private var kind: Kind = .all
    @State private var monthKey: String = ActivityDate.currentMonthKey

    enum Kind: String { case all, expense, income }

    var body: some View {
        let rows = filtered(vm?.rows ?? [])
        return ZStack {
            Palette.cream.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 0) {
                    controls(count: rows.count, net: rows.reduce(0) { $0 + $1.amountCents },
                             code: rows.first?.currency ?? "AUD")
                    if rows.isEmpty {
                        emptyState.padding(.top, 30)
                    } else {
                        ForEach(groups(rows), id: \.key) { group in
                            section(group)
                        }
                    }
                }
                .padding(.bottom, 120)
            }
        }
        .accessibilityIdentifier(AccessibilityID.activityScreen)
        .task(id: profileId) {
            vm = ReceiptsListViewModel(context: context, profileId: profileId)
        }
    }

    // MARK: - Header / controls

    @ViewBuilder
    private func controls(count: Int, net: Int, code: String) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("Activity").font(.display(30)).foregroundStyle(Palette.ink).tracking(-0.6)
                Spacer()
                monthPicker
            }
            searchField.padding(.top, 14)
            HStack(spacing: 8) {
                chip("All", .all); chip("Expenses", .expense); chip("Income", .income)
                Spacer(minLength: 0)
            }
            .padding(.top, 12)
            HStack(alignment: .firstTextBaseline) {
                Text("\(count) transaction\(count == 1 ? "" : "s")")
                    .font(.ui(13, .semibold)).foregroundStyle(Palette.ink3)
                Spacer()
                Text("Net \(Self.signed(net, code: code))")
                    .numeric(16).foregroundStyle(net >= 0 ? Palette.income : Palette.ink)
            }
            .padding(.top, 16)
        }
        .padding(.horizontal, 18).padding(.top, 14)
    }

    private var monthPicker: some View {
        Menu {
            ForEach(ActivityDate.recentMonthKeys, id: \.self) { key in
                Button { monthKey = key } label: {
                    if key == monthKey { Label(ActivityDate.monthLabel(key), systemImage: "checkmark") }
                    else { Text(ActivityDate.monthLabel(key)) }
                }
            }
        } label: {
            HStack(spacing: 7) {
                Icon(name: "calendar", size: 18, color: accent.base)
                Text(ActivityDate.monthLabel(monthKey)).font(.ui(13.5, .bold)).foregroundStyle(Palette.ink)
                Icon(name: "chevD", size: 15, color: Palette.ink3)
            }
            .frame(height: 42).padding(.horizontal, 13)
            .background(Palette.paper, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.line, lineWidth: 1))
            .cardShadow()
        }
        .accessibilityIdentifier(AccessibilityID.activityMonthPicker)
    }

    private var searchField: some View {
        HStack(spacing: 9) {
            Icon(name: "search", size: 19, color: Palette.ink3)
            TextField("Search merchant or category", text: $query)
                .font(.ui(15)).foregroundStyle(Palette.ink)
                .accessibilityIdentifier(AccessibilityID.activitySearch)
            if !query.isEmpty {
                Button { query = "" } label: { Icon(name: "close", size: 17, color: Palette.ink3) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(Palette.paper, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.line, lineWidth: 1))
        .cardShadow()
    }

    private func chip(_ title: String, _ k: Kind) -> some View {
        Chip(title: title, isActive: kind == k) { kind = k }
            .accessibilityIdentifier(chipID(k))
    }

    private func chipID(_ k: Kind) -> String {
        switch k {
        case .all: return AccessibilityID.activityFilterAll
        case .expense: return AccessibilityID.activityFilterExpenses
        case .income: return AccessibilityID.activityFilterIncome
        }
    }

    // MARK: - Groups

    private func section(_ group: (key: String, label: String, rows: [ReceiptRow])) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(group.label).font(.ui(13, .bold)).foregroundStyle(Palette.ink3)
                .padding(.horizontal, 20).padding(.bottom, 8)
            VStack(spacing: 0) {
                ForEach(Array(group.rows.enumerated()), id: \.element.id) { idx, row in
                    Button { onOpenReceipt(row.id) } label: {
                        ReceiptRowView(row: row, showDivider: idx < group.rows.count - 1)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(AccessibilityID.activityRowPrefix + row.id)
                }
            }
            .padding(.horizontal, 14)
            .background(Palette.paper, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Palette.line2, lineWidth: 1))
            .cardShadow()
            .padding(.horizontal, 18)
        }
        .padding(.top, 18)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            EmptyArt()
            Text("Nothing here yet").font(.ui(18, .bold)).foregroundStyle(Palette.ink)
            Text("No matches for this filter. Snap a receipt to add your first one.")
                .font(.ui(14)).foregroundStyle(Palette.ink2).multilineTextAlignment(.center).lineSpacing(2)
            Button(action: onSnap) {
                HStack(spacing: 8) {
                    Icon(name: "camera", size: 18, color: .white)
                    Text("Snap a receipt").font(.ui(15, .bold)).foregroundStyle(.white)
                }
                .padding(.horizontal, 22).padding(.vertical, 12)
                .background(accent.base, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .padding(.horizontal, 36)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier(AccessibilityID.activityEmpty)
    }

    // MARK: - Filtering / grouping

    private func filtered(_ rows: [ReceiptRow]) -> [ReceiptRow] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return rows.filter { r in
            guard r.txnDate.hasPrefix(monthKey) else { return false }
            switch kind {
            case .all: break
            case .expense: if r.amountCents >= 0 { return false }
            case .income: if r.amountCents <= 0 { return false }
            }
            if q.isEmpty { return true }
            let label = r.category.flatMap { CATS[$0]?.label } ?? ""
            return r.merchant.lowercased().contains(q) || label.lowercased().contains(q)
        }
    }

    private func groups(_ rows: [ReceiptRow]) -> [(key: String, label: String, rows: [ReceiptRow])] {
        let byDate = Dictionary(grouping: rows, by: { $0.txnDate })
        return byDate.keys.sorted(by: >).map { key in
            (key: key, label: ActivityDate.dayLabel(key), rows: byDate[key] ?? [])
        }
    }

    /// "+$42.50" / "−$42.50" for the net summary.
    static func signed(_ cents: Int, code: String) -> String {
        let base = (Decimal(abs(cents)) / 100).formatted(.currency(code: code))
        return (cents < 0 ? "−" : "+") + base
    }
}

/// Date helpers for the Activity month picker + day-group headers.
enum ActivityDate {
    static var currentMonthKey: String { monthKeyFormatter.string(from: Date()) }

    static var recentMonthKeys: [String] {
        let cal = Calendar.current
        return (0..<8).compactMap { i in
            cal.date(byAdding: .month, value: -i, to: Date()).map { monthKeyFormatter.string(from: $0) }
        }
    }

    static func monthLabel(_ key: String) -> String {
        guard let d = monthKeyFormatter.date(from: key) else { return key }
        return monthLabelFormatter.string(from: d)
    }

    /// "Today" / "Yesterday" / "Monday, 5 May" for a "YYYY-MM-DD" key.
    static func dayLabel(_ key: String) -> String {
        guard let d = isoFormatter.date(from: key) else { return key }
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        return dayLabelFormatter.string(from: d)
    }

    private static let monthKeyFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM"; return f
    }()
    private static let monthLabelFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM yyyy"; return f
    }()
    private static let isoFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f
    }()
    private static let dayLabelFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEEE, d MMM"; return f
    }()
}
