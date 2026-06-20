import SwiftUI

/// CamScanner-style edge adjustment: shows the captured still with the auto-detected document
/// quad drawn over it and a draggable handle on each corner. "Confirm scan" perspective-
/// corrects (dewarps) the image to the (possibly adjusted) quad → a clean scanned receipt,
/// which flows into the existing OCR → review pipeline. "Retake" reopens the camera.
struct EdgeAdjustView: View {
    let image: UIImage
    /// Delivered the dewarped, cropped image.
    let onConfirm: (UIImage) -> Void
    let onRetake: () -> Void
    let onClose: () -> Void

    @Environment(\.accent) private var accent
    /// The quad in IMAGE pixel coordinates (top-left origin). Detected on appear.
    @State private var quad: DocumentQuad?

    private var imageSize: CGSize { image.size }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            GeometryReader { geo in
                let rect = Self.aspectFitRect(imageSize: imageSize, in: geo.size)
                ZStack(alignment: .topLeading) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geo.size.width, height: geo.size.height)

                    if let quad {
                        quadShape(quad, in: rect)
                        ForEach(Corner.allCases, id: \.self) { corner in
                            handle(corner, quad: quad, rect: rect)
                        }
                    }
                }
                .onAppear {
                    if quad == nil {
                        quad = DocumentScan.detect(in: image)
                            ?? DocumentQuad.defaultInset(width: imageSize.width, height: imageSize.height)
                    }
                }
            }
            .padding(.top, 64)
            .padding(.bottom, 128)

            controls
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.captureConfirmScreen)
    }

    // MARK: Overlay

    private func quadShape(_ quad: DocumentQuad, in rect: CGRect) -> some View {
        Path { path in
            let tl = Self.toView(quad.topLeft, imageSize: imageSize, rect: rect)
            let tr = Self.toView(quad.topRight, imageSize: imageSize, rect: rect)
            let br = Self.toView(quad.bottomRight, imageSize: imageSize, rect: rect)
            let bl = Self.toView(quad.bottomLeft, imageSize: imageSize, rect: rect)
            path.move(to: tl); path.addLine(to: tr); path.addLine(to: br)
            path.addLine(to: bl); path.closeSubpath()
        }
        .stroke(accent.base, lineWidth: 2)
        .background(
            Path { path in
                let tl = Self.toView(quad.topLeft, imageSize: imageSize, rect: rect)
                let tr = Self.toView(quad.topRight, imageSize: imageSize, rect: rect)
                let br = Self.toView(quad.bottomRight, imageSize: imageSize, rect: rect)
                let bl = Self.toView(quad.bottomLeft, imageSize: imageSize, rect: rect)
                path.move(to: tl); path.addLine(to: tr); path.addLine(to: br)
                path.addLine(to: bl); path.closeSubpath()
            }.fill(accent.base.opacity(0.12))
        )
        .allowsHitTesting(false)
    }

    private func handle(_ corner: Corner, quad: DocumentQuad, rect: CGRect) -> some View {
        let viewPoint = Self.toView(corner.point(in: quad), imageSize: imageSize, rect: rect)
        return Circle()
            .fill(.white)
            .overlay(Circle().stroke(accent.base, lineWidth: 3))
            .frame(width: 24, height: 24)
            .position(viewPoint)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let clamped = Self.clampToImage(
                            Self.toImage(value.location, imageSize: imageSize, rect: rect),
                            imageSize: imageSize)
                        var q = self.quad ?? quad
                        corner.set(clamped, in: &q)
                        self.quad = q
                    }
            )
            .accessibilityIdentifier(corner.accessibilityID)
    }

    private var controls: some View {
        VStack {
            HStack {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 40, height: 40).background(.white.opacity(0.18), in: Circle())
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

                Button(action: confirm) {
                    Label("Confirm scan", systemImage: "checkmark")
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

    private func confirm() {
        guard let quad else { onConfirm(image); return }
        onConfirm(DocumentScan.dewarp(image, quad: quad) ?? image)
    }

    // MARK: Geometry

    /// The aspect-fit rect of `imageSize` centered in `container` (matches `.scaledToFit()`).
    static func aspectFitRect(imageSize: CGSize, in container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, container.width > 0, container.height > 0
        else { return CGRect(origin: .zero, size: container) }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let w = imageSize.width * scale, h = imageSize.height * scale
        return CGRect(x: (container.width - w) / 2, y: (container.height - h) / 2, width: w, height: h)
    }

    /// Image px (top-left origin) → view point inside the displayed image rect.
    static func toView(_ p: CGPoint, imageSize: CGSize, rect: CGRect) -> CGPoint {
        guard imageSize.width > 0, imageSize.height > 0 else { return rect.origin }
        return CGPoint(x: rect.minX + p.x / imageSize.width * rect.width,
                       y: rect.minY + p.y / imageSize.height * rect.height)
    }

    /// View point → image px (top-left origin).
    static func toImage(_ p: CGPoint, imageSize: CGSize, rect: CGRect) -> CGPoint {
        guard rect.width > 0, rect.height > 0 else { return .zero }
        return CGPoint(x: (p.x - rect.minX) / rect.width * imageSize.width,
                       y: (p.y - rect.minY) / rect.height * imageSize.height)
    }

    static func clampToImage(_ p: CGPoint, imageSize: CGSize) -> CGPoint {
        CGPoint(x: min(max(p.x, 0), imageSize.width), y: min(max(p.y, 0), imageSize.height))
    }

    enum Corner: CaseIterable {
        case topLeft, topRight, bottomRight, bottomLeft
        func point(in q: DocumentQuad) -> CGPoint {
            switch self {
            case .topLeft: return q.topLeft
            case .topRight: return q.topRight
            case .bottomRight: return q.bottomRight
            case .bottomLeft: return q.bottomLeft
            }
        }
        func set(_ p: CGPoint, in q: inout DocumentQuad) {
            switch self {
            case .topLeft: q.topLeft = p
            case .topRight: q.topRight = p
            case .bottomRight: q.bottomRight = p
            case .bottomLeft: q.bottomLeft = p
            }
        }
        var accessibilityID: String {
            switch self {
            case .topLeft: return "capture.crop.tl"
            case .topRight: return "capture.crop.tr"
            case .bottomRight: return "capture.crop.br"
            case .bottomLeft: return "capture.crop.bl"
            }
        }
    }
}
