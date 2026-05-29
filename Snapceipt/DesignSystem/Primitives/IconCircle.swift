import SwiftUI

/// Rounded-square tinted icon tile: soft background, 13pt radius, centered Icon (sw 1.9).
struct IconCircle: View {
    let name: String
    var tint: Color
    var soft: Color
    var size: CGFloat = 42
    var iconSize: CGFloat = 21
    var filled: Bool = false
    var body: some View {
        RoundedRectangle(cornerRadius: 13, style: .continuous)
            .fill(soft)
            .frame(width: size, height: size)
            .overlay(Icon(name: name, size: iconSize, color: tint, lineWidth: 1.9, filled: filled))
    }
}

#if DEBUG
#Preview("IconCircle") {
    HStack(spacing: 12) {
        IconCircle(name: "receipt", tint: Color(hex: 0xE8602C), soft: Color(hex: 0xFBEADF))
        IconCircle(name: "wallet", tint: Color(hex: 0xC99A22), soft: Color(hex: 0xF6EECE))
    }.padding().background(Palette.cream)
}
#endif
