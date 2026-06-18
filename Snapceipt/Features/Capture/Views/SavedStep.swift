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
    /// True when the receipt was captured offline (HeuristicParser fallback) and is
    /// queued in the outbox awaiting a reconnect drain — surfaces the "Queued" badge.
    var queued: Bool = false
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
                Circle().fill(Palette.income).frame(width: 96, height: 96)
                    .shadow(color: Palette.income.opacity(0.5), radius: 14, x: 0, y: 10)
                Icon(name: "check", size: 44, color: .white)
            }
            .scaleEffect(pop ? 1 : 0.6)
            .animation(.spring(response: 0.45, dampingFraction: 0.6), value: pop)

            Text("Receipt saved!")
                .font(.display(24)).foregroundStyle(Palette.ink)
                .accessibilityIdentifier(AccessibilityID.captureSavedTitle)
            if queued {
                // Offline capture: the on-device heuristic filled the draft and it is
                // queued in the outbox; it syncs + re-extracts when the device reconnects.
                HStack(spacing: 6) {
                    Icon(name: "clock", size: 13, color: Palette.ink2)
                    Text("Queued — syncs when you're back online")
                        .font(.ui(12.5, .bold)).foregroundStyle(Palette.ink2)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Palette.paper, in: Capsule())
                .overlay(Capsule().stroke(Palette.line, lineWidth: 1))
                .accessibilityIdentifier(AccessibilityID.captureQueuedBadge)
            }
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
        // Confetti rains DOWN from across the top of the screen.
        .overlay(alignment: .top) {
            Confetti(active: pop, accent: accent.base)
                .allowsHitTesting(false)
        }
        .onAppear { pop = true }
        // Success haptic on the save confirmation (fires once as the disc pops in).
        .sensoryFeedback(.success, trigger: pop)
    }

    /// "$42.50 added to Business expenses, and tagged 50% deductible." — total + mode +
    /// (optional) deductible interpolated, mode capitalized (spec §2 L165).
    private var summary: Text {
        var s = "\(fmt(total)) added to \(mode.capitalized) expenses"
        if let d = deductible { s += ", and tagged \(d)% deductible" }
        return Text(s + ".")
    }
}

/// A lightweight confetti shower (no dependency): 14 colored shards spread across
/// the top of the screen, raining DOWN as the success disc pops in.
private struct Confetti: View {
    let active: Bool
    let accent: Color

    private static let shardCount = 14
    /// 5-colour palette: accent, income-green, violet, gold, blue.
    private var palette: [Color] {
        [accent, Palette.income, Color(hex: 0x7B5BD6), Color(hex: 0xC99A22), Color(hex: 0x2F6FB0)]
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                ForEach(0..<Self.shardCount, id: \.self) { i in
                    // x spread evenly from ~8%..92% of the available width.
                    let frac = Double(i) / Double(Self.shardCount - 1)
                    let x = geo.size.width * (0.08 + 0.84 * frac)
                    let fall = geo.size.height * 0.85
                    RoundedRectangle(cornerRadius: 2)
                        .fill(palette[i % palette.count])
                        .frame(width: 8, height: 12)
                        .position(x: x, y: active ? fall : -20)
                        .opacity(active ? 0 : 1)
                        .animation(.easeIn(duration: 1.0 + Double(i % 5) * 0.18)
                            .delay(Double(i % 4) * 0.06), value: active)
                }
            }
        }
    }
}
