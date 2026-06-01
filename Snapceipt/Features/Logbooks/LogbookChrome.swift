import SwiftUI

/// Shared logbook header: back button + centered title + accent plus button.
struct LbHeader: View {
    let title: String
    let onClose: () -> Void
    let onAdd: () -> Void
    /// When false, the trailing add button is omitted (its slot kept for symmetry).
    var showsAdd: Bool = true
    @Environment(\.accent) private var accent

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

            if showsAdd {
                Button(action: onAdd) {
                    Icon(name: "plus", size: 20, color: .white, lineWidth: 2.3)
                        .frame(width: 40, height: 40)
                        .background(accent.base, in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
                        .shadow(color: accent.base.opacity(0.4), radius: 7, x: 0, y: 6)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(AccessibilityID.logbookAdd)
            } else {
                // Keep the title centered by reserving the add button's footprint.
                Color.clear.frame(width: 40, height: 40)
            }
        }
        .padding(.top, 54).padding(.horizontal, 18).padding(.bottom, 12)
    }
}

/// Uppercase section label.
struct LbLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.ui(12.5, .bold)).foregroundStyle(Palette.ink3)
            .kerning(0.3)
            .padding(.top, 20).padding(.horizontal, 2).padding(.bottom, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One hero stat group (label + value).
struct LbStat: View {
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.ui(12, .semibold)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
            Text(value).font(.display(18, .bold)).foregroundStyle(.white)
        }
    }
}

/// Gradient logbook hero: icon + label + method pill, big number + unit, 3 stats.
struct LbHero: View {
    let icon: String
    let label: String
    let pill: String
    let bigNumber: String
    let unit: String
    let stats: [(String, String)]
    @Environment(\.accent) private var accent

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Icon(name: icon, size: 20, color: .white)
                    Text(label).font(.ui(13, .semibold)).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
                    Spacer()
                    Text(pill).font(.ui(11.5, .bold)).foregroundStyle(.white)
                        .padding(.vertical, 4).padding(.horizontal, 10)
                        .background(Color.white.opacity(0.2), in: Capsule())
                }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(bigNumber).font(.display(38, .bold)).foregroundStyle(.white)
                    Text(unit).font(.display(20, .semibold)).foregroundStyle(.white.opacity(0.85))
                }
                .padding(.top, 6)
                HStack(spacing: 18) {
                    ForEach(Array(stats.enumerated()), id: \.offset) { idx, s in
                        if idx > 0 { Rectangle().fill(Color.white.opacity(0.25)).frame(width: 1, height: 34) }
                        LbStat(label: s.0, value: s.1)
                    }
                }
                .padding(.top, 14)
            }
            .padding(18)
        }
        .background(
            LinearGradient(colors: [accent.base, accent.deep],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .shadow(color: accent.base.opacity(0.5), radius: 15, x: 0, y: 14)
    }
}

/// The cream fade scrim + a full-width accent CTA pinned to the bottom of a logbook.
struct LbFloatingCTA: View {
    let title: String
    let a11yId: String
    let action: () -> Void
    @Environment(\.accent) private var accent

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Icon(name: "plus", size: 20, color: .white, lineWidth: 2.3)
                Text(title).font(.ui(16, .semibold)).foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(accent.base, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            .shadow(color: accent.base.opacity(0.5), radius: 12, x: 0, y: 12)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(a11yId)
        .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 34)
        .background(
            LinearGradient(colors: [Palette.cream.opacity(0), Palette.cream],
                           startPoint: .top, endPoint: .bottom)
        )
    }
}
