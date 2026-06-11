import Foundation

private let auLocale = Locale(identifier: "en_AU")

/// Decimal (NOT currency) formatter so we control the literal "$" prefix
/// and avoid the "A$" symbol a currency formatter would emit — matching
/// theme.jsx's `Number.toLocaleString('en-AU', …)` + literal '$'.
private func makeMoneyFormatter(showCents: Bool) -> NumberFormatter {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.locale = auLocale
    f.usesGroupingSeparator = true
    f.minimumFractionDigits = showCents ? 2 : 0
    f.maximumFractionDigits = showCents ? 2 : 0
    f.roundingMode = .halfUp
    return f
}

private let moneyWithCents = makeMoneyFormatter(showCents: true)
private let moneyNoCents = makeMoneyFormatter(showCents: false)

/// Format Int **cents** as AUD: "$42.50", "−$42.50" (U+2212), "+$850.00".
/// - sign: when true, prefix "+" for positive (non-zero) amounts.
/// - showCents: when false, drop the decimals (budgets/summary use this).
func fmt(_ cents: Int, sign: Bool = false, showCents: Bool = true) -> String {
    let absCents = abs(cents)
    let dollars = Decimal(absCents) / 100
    let formatter = showCents ? moneyWithCents : moneyNoCents
    let body = formatter.string(from: dollars as NSDecimalNumber) ?? (showCents ? "0.00" : "0")
    let prefix: String
    if cents < 0 {
        prefix = "\u{2212}" // MINUS SIGN, not hyphen-minus
    } else if sign && cents > 0 {
        prefix = "+"
    } else {
        prefix = ""
    }
    return prefix + "$" + body
}

/// Format a dollar **Decimal** as AUD "$42.50" using the same cached decimal
/// formatter (literal "$", en-AU grouping, no "A$" currency symbol). Used where a
/// `Decimal` amount — not Int cents — is on hand (e.g. the capture draft total).
func fmt(_ dollars: Decimal) -> String {
    let body = moneyWithCents.string(from: dollars as NSDecimalNumber) ?? "0.00"
    return "$" + body
}

/// Compact AUD: "$500", "$1.2k", "$12k". Threshold mirrors theme.jsx:
/// dollars >= 10000 -> integer "k"; >= 1000 -> one-decimal "k"; else plain "$N".
func fmtK(_ cents: Int) -> String {
    let absCents = abs(cents)
    let dollars = Double(absCents) / 100.0
    if dollars >= 1000 {
        let k = dollars / 1000.0
        let digits = dollars >= 10000 ? 0 : 1
        return "$" + String(format: "%.\(digits)f", k) + "k"
    }
    return "$" + String(format: "%.0f", dollars)
}

/// Date display style for `fmtDate`.
enum DateStyle {
    case short // "28 May"
    case long  // "28 May 2026"
}

private let isoDateParser: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "yyyy-MM-dd"
    return f
}()

private func makeDateFormatter(_ format: String) -> DateFormatter {
    let f = DateFormatter()
    f.locale = auLocale
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = format
    return f
}

private let dateShort = makeDateFormatter("d MMM")
private let dateLong = makeDateFormatter("d MMM yyyy")

/// Format a `'YYYY-MM-DD'` string as en-AU "28 May" (short) or "28 May 2026" (long).
/// Returns the raw input unchanged if it cannot be parsed.
func fmtDate(_ iso: String, style: DateStyle = .short) -> String {
    guard let date = isoDateParser.date(from: iso) else { return iso }
    switch style {
    case .short: return dateShort.string(from: date)
    case .long: return dateLong.string(from: date)
    }
}

/// en-AU "28 Jul 2026" (day-month-year, no comma) for a BAS due `Date`.
///
/// Unlike `dateLong` (UTC, for parsing UTC-anchored ISO strings), this pins the
/// time zone to **Australia/Sydney** to match `BasSchedule.nextDue`'s anchor
/// (`BasSchedule.swift`): that returns the 28th/21st at Sydney midnight, so
/// rendering in the device zone would show the deadline a day early west of
/// Sydney (e.g. Perth/Adelaide render '27 Jul' for the 28-Jul due). Statutory BAS
/// dates must read as their AU wall-clock day regardless of the device's offset.
private let basDueFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = auLocale
    f.timeZone = TimeZone(identifier: "Australia/Sydney")
    f.dateFormat = "d MMM yyyy"
    return f
}()

/// Format a BAS-due `Date` as en-AU "28 Jul 2026", anchored to Australia/Sydney
/// (see `basDueFormatter`). Used by `TaxSettingsView`'s "Next BAS due" row.
func fmtBasDue(_ date: Date) -> String {
    basDueFormatter.string(from: date)
}
