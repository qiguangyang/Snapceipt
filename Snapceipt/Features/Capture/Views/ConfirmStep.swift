import SwiftUI

/// Shows the just-captured receipt full-screen with Confirm / Retake before OCR runs, so a
/// misframed or wrong shot can be retaken without processing it. Confirm proceeds to the
/// scan/extract pipeline; Retake reopens the camera.
struct ConfirmStep: View {
    let image: UIImage?
    let onConfirm: () -> Void
    let onRetake: () -> Void
    let onClose: () -> Void

    @Environment(\.accent) private var accent

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(.top, 64)
                    .padding(.bottom, 128)
                    .accessibilityIdentifier(AccessibilityID.captureConfirmImage)
            }

            VStack {
                HStack {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(.white.opacity(0.18), in: Circle())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding(.horizontal, 18).padding(.top, 8)

                Spacer()

                HStack(spacing: 14) {
                    Button(action: onRetake) {
                        Label("Retake", systemImage: "arrow.counterclockwise")
                            .font(.ui(16, .semibold)).foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .background(.white.opacity(0.2), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .contentShape(Rectangle())
                    }
                    .accessibilityIdentifier(AccessibilityID.captureRetake)

                    Button(action: onConfirm) {
                        Label("Confirm", systemImage: "checkmark")
                            .font(.ui(16, .semibold)).foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .background(accent.base, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .contentShape(Rectangle())
                    }
                    .accessibilityIdentifier(AccessibilityID.captureConfirm)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 18).padding(.bottom, 36)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.captureConfirmScreen)
    }
}
