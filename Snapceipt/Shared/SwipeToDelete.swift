import SwiftUI

/// Wraps a card-style row (NOT a `List` row) so a left-swipe reveals a trailing red Delete
/// button. SwiftUI `.swipeActions` only works inside `List`; this gives the same gesture for the
/// app's custom ScrollView/VStack card lists (e.g. the Bill-to client picker). Tapping the row
/// still works (the drag has a minimum distance, so a tap passes through to the inner button).
struct SwipeToDelete<Content: View>: View {
    var onDelete: () -> Void
    @ViewBuilder var content: () -> Content

    @State private var offset: CGFloat = 0
    private let reveal: CGFloat = 84

    var body: some View {
        ZStack(alignment: .trailing) {
            // Red Delete affordance revealed under the row; sizes to the row's height.
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Palette.alert)
                .overlay(alignment: .trailing) {
                    Button(role: .destructive) {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { offset = 0 }
                        onDelete()
                    } label: {
                        Image(systemName: "trash.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: reveal)
                            .frame(maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(AccessibilityID.swipeDeleteButton)
                }

            content()
                .offset(x: offset)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 20)
                        .onChanged { v in
                            let dx = v.translation.width
                            if dx < 0 { offset = max(-reveal, dx) }            // swiping open
                            else if offset < 0 { offset = min(0, -reveal + dx) } // swiping closed
                        }
                        .onEnded { v in
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                offset = v.translation.width < -reveal / 2 ? -reveal : 0
                            }
                        }
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
