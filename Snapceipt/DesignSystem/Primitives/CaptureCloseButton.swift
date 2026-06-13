import SwiftUI

/// The capture-flow close chip: a 40x40 paper tile with a continuous chip radius, a
/// line stroke, and a 20pt `close` glyph in ink-2. Carries `AccessibilityID.captureClose`
/// and fires `onClose`. Extracted so Scan and Review share one definition instead of an
/// 11-line verbatim copy-paste.
struct CaptureCloseButton: View {
    let onClose: () -> Void

    var body: some View {
        Button(action: onClose) {
            Icon(name: "close", size: 20, color: Palette.ink2)
                .frame(width: 40, height: 40)
                .background(Palette.paper, in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                        .stroke(Palette.line, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AccessibilityID.captureClose)
    }
}

#if DEBUG
#Preview("CaptureCloseButton") {
    CaptureCloseButton(onClose: {})
        .padding().background(Palette.cream)
}
#endif
