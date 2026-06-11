import SwiftUI

/// Saved confirmation: a filled green success disc (pulse ring + drawn white check)
/// over a light confetti burst, the spec summary sentence, and Snap another / Done.
struct SavedStep: View {
    @Environment(\.accent) private var accent
    /// Receipt total in dollars (drives the summary amount).
    let total: Decimal
    /// Active profile mode word ("personal" | "business"), capitalized in the summary.
    let mode: String
    /// Tax-deductible %, when present (drives the "tagged N% deductible" clause).
    let deductible: Int?
    let onSnapAnother: () -> Void
    let onDone: () -> Void

    @State private var pop = false

    var body: some View {
        VStack(spacing: 18) {
            // Filled income disc with a pulse ring behind + a drawn white check.
            // The green ring/circle/check stay --income in BOTH modes (spec §2 L123).
            ZStack {
                Circle().fill(Palette.income).opacity(pop ? 0 : 0.45)
                    .frame(width: 110, height: 110)
                    .scaleEffect(pop ? 1.5 : 0.6)
                    .animation(.easeOut(duration: 1.1).delay(0.1), value: pop)
                Confetti(active: pop, color: accent.base)
                Circle().fill(Palette.income).frame(width: 96, height: 96)
                    .shadow(color: Palette.income.opacity(0.5), radius: 14, x: 0, y: 10)
                Icon(name: "check", size: 44, color: .white)
            }
            .scaleEffect(pop ? 1 : 0.6)
            .animation(.spring(response: 0.45, dampingFraction: 0.6), value: pop)

            Text("Receipt saved!")
                .font(.display(24)).foregroundStyle(Palette.ink)
                .accessibilityIdentifier(AccessibilityID.captureSavedTitle)
            summary
                .font(.ui(14.5)).foregroundStyle(Palette.ink2)
                .multilineTextAlignment(.center)

            VStack(spacing: 10) {
                Button(action: onSnapAnother) {
                    HStack(spacing: 8) {
                        Icon(name: "camera", size: 20, color: .white)
                        Text("Snap another").font(.ui(16, .bold)).foregroundStyle(.white)
                    }
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .background(accent.base, in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(AccessibilityID.captureSnapAnother)
                Button(action: onDone) {
                    Text("Done").font(.ui(16, .bold)).foregroundStyle(Palette.ink)
                        .frame(maxWidth: .infinity, minHeight: 54)
                        .background(Palette.paper, in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: Radius.inner, style: .continuous)
                                .stroke(Palette.line, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(AccessibilityID.captureDone)
            }
            .padding(.horizontal, 28).padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.cream)
        .onAppear { pop = true }
    }

    /// "$42.50 added to Business expenses, and tagged 50% deductible." — total + mode +
    /// (optional) deductible interpolated, mode capitalized (spec §2 L165).
    private var summary: Text {
        var s = "\(amount(total)) added to \(mode.capitalized) expenses"
        if let d = deductible { s += ", and tagged \(d)% deductible" }
        return Text(s + ".")
    }

    /// Display a dollar Decimal as "$X.XX" (AUD).
    private func amount(_ d: Decimal) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "AUD"
        f.locale = Locale(identifier: "en_AU")
        return f.string(from: d as NSDecimalNumber) ?? "$0.00"
    }
}

/// A lightweight confetti burst (no dependency): random colored shards fanning out.
private struct Confetti: View {
    let active: Bool
    let color: Color
    var body: some View {
        ZStack {
            ForEach(0..<14, id: \.self) { i in
                let angle = Double(i) / 14 * 2 * .pi
                RoundedRectangle(cornerRadius: 1)
                    .fill([color, Palette.income, Palette.alert, Palette.ink3][i % 4])
                    .frame(width: 5, height: 9)
                    .offset(x: active ? cos(angle) * 90 : 0,
                            y: active ? sin(angle) * 90 : 0)
                    .opacity(active ? 0 : 1)
                    .animation(.easeOut(duration: 0.9).delay(0.05), value: active)
            }
        }
    }
}
