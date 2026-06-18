import SwiftUI

/// Paper card: 22pt radius, 1px line-2 border, sh-card shadow, default 16pt padding.
struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: () -> Content
    var body: some View {
        content()
            .padding(padding)
            .background(Palette.paper)
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(Palette.line2, lineWidth: 1)
                    // Decorative only — must not hit-test, or the border sits above the
                    // card's content and swallows taps on interactive rows inside it.
                    .allowsHitTesting(false)
            )
            .cardShadow()
    }
}

#if DEBUG
#Preview("Card") {
    Card { Text("Net this month").font(.ui(15, .semibold)) }
        .padding().background(Palette.cream)
}
#endif
