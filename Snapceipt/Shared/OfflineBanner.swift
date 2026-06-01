import SwiftUI

/// A slim banner shown when the device has no connectivity. Reads the shared
/// `Reachability` (@Observable). Renders nothing while online.
struct OfflineBanner: View {
    @Bindable var reachability: Reachability

    var body: some View {
        if !reachability.isOnline {
            HStack(spacing: 7) {
                Icon(name: "bell", size: 14, color: .white)
                Text("You’re offline — changes will sync later")
                    .font(.ui(12.5, .semibold))
                    .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .padding(.horizontal, 14)
            .background(Palette.alert)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

#if DEBUG
#Preview {
    // `Reachability.isOnline` is read-only, so the preview shows the banner's
    // offline appearance directly rather than mutating the live monitor.
    VStack(spacing: 0) {
        HStack(spacing: 7) {
            Icon(name: "bell", size: 14, color: .white)
            Text("You’re offline — changes will sync later")
                .font(.ui(12.5, .semibold))
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .padding(.horizontal, 14)
        .background(Palette.alert)
        Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Palette.cream)
}
#endif
