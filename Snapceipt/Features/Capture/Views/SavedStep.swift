import SwiftUI

/// Saved confirmation: a green success ring/checkmark with a light confetti burst,
/// a one-line summary, and Snap another / Done.
struct SavedStep: View {
    @Environment(\.accent) private var accent
    let merchant: String
    let onSnapAnother: () -> Void
    let onDone: () -> Void

    @State private var pop = false

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle().stroke(Palette.income, lineWidth: 4).frame(width: 96, height: 96)
                Icon(name: "check", size: 40, color: Palette.income)
                Confetti(active: pop, color: accent.base)
            }
            .scaleEffect(pop ? 1 : 0.6)
            .animation(.spring(response: 0.45, dampingFraction: 0.6), value: pop)

            Text("Receipt saved!")
                .font(.display(24)).foregroundStyle(Palette.ink)
                .accessibilityIdentifier(AccessibilityID.captureSavedTitle)
            Text(merchant.isEmpty ? "Synced to your ledger." : "\(merchant) — synced to your ledger.")
                .font(.ui(13.5)).foregroundStyle(Palette.ink2)

            VStack(spacing: 10) {
                Button(action: onSnapAnother) {
                    Text("Snap another").font(.ui(16, .bold)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(accent.base, in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(AccessibilityID.captureSnapAnother)
                Button(action: onDone) {
                    Text("Done").font(.ui(15, .semibold)).foregroundStyle(Palette.ink2)
                        .frame(maxWidth: .infinity, minHeight: 48)
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
                    .offset(x: active ? cos(angle) * 70 : 0,
                            y: active ? sin(angle) * 70 : 0)
                    .opacity(active ? 0 : 1)
                    .animation(.easeOut(duration: 0.9).delay(0.05), value: active)
            }
        }
    }
}
