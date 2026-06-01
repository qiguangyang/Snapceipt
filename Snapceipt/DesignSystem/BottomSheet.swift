import SwiftUI

/// Reusable bottom-sheet container: a dimmed scrim (tap-to-dismiss) plus a
/// bottom-anchored panel that rises in with the design's `sc-rise` curve.
///
/// The injected `content` supplies its own panel chrome (cream/paper background,
/// rounded top corners, grabber) — the Profiles sheets (`ProfilePickerSheet`,
/// `AddProfileView`) already do — so this container only owns the scrim and the
/// enter/exit motion, never a second background panel.
struct BottomSheet<Content: View>: View {
    var onClose: () -> Void
    @ViewBuilder var content: () -> Content

    @State private var appeared = false

    var body: some View {
        ZStack(alignment: .bottom) {
            // Scrim
            Color(red: 20/255, green: 16/255, blue: 12/255)
                .opacity(appeared ? 0.4 : 0)
                .ignoresSafeArea()
                .onTapGesture { onClose() }

            content()
                .frame(maxWidth: .infinity)
                .offset(y: appeared ? 0 : 18)
                .opacity(appeared ? 1 : 0)
                .scaleEffect(appeared ? 1 : 0.98, anchor: .bottom)
        }
        .onAppear {
            withAnimation(.timingCurve(0.22, 0.61, 0.36, 1, duration: 0.32)) {
                appeared = true
            }
        }
    }
}

#if DEBUG
#Preview {
    ZStack {
        Palette.cream.ignoresSafeArea()
        BottomSheet(onClose: {}) {
            VStack(alignment: .leading, spacing: 8) {
                Capsule().fill(Palette.line)
                    .frame(width: 40, height: 5)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 10).padding(.bottom, 14)
                Text("Switch profile")
                    .font(.display(20))
                    .foregroundStyle(Palette.ink)
                Text("Choose which profile to view.")
                    .font(.ui(13))
                    .foregroundStyle(Palette.ink3)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.cream)
            .clipShape(.rect(topLeadingRadius: 28, topTrailingRadius: 28))
            .popShadow()
        }
    }
}
#endif
