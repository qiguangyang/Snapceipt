import SwiftUI

/// Pill chip toggle. Active = accent fill + white text (+ soft shadow); inactive = paper + ink-2 + line border.
struct Chip: View {
    let title: String
    var isActive: Bool
    var iconName: String? = nil
    var action: () -> Void = {}
    @Environment(\.accent) private var accent

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let iconName {
                    Icon(name: iconName, size: 15, color: isActive ? .white : Palette.ink2, lineWidth: 1.85)
                }
                Text(title).font(.ui(13.5, .semibold))
            }
            .padding(.vertical, 8).padding(.horizontal, 14)
            .foregroundStyle(isActive ? .white : Palette.ink2)
            .background(isActive ? accent.base : Palette.paper)
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(isActive ? accent.base : Palette.line, lineWidth: 1))
            .shadow(color: isActive ? Color.black.opacity(0.18) : .clear, radius: 6, x: 0, y: 4)
            .animation(.timingCurve(0.22, 0.61, 0.36, 1, duration: 0.18), value: isActive)
        }
        .buttonStyle(.plain)
    }
}

#if DEBUG
#Preview("Chip") {
    HStack { Chip(title: "All", isActive: true); Chip(title: "Expenses", isActive: false) }
        .padding().background(Palette.cream).environment(\.accent, .personal)
}
#endif
