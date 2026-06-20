import SwiftUI
import AVFoundation
import UIKit
import Vision

/// Four corners of a live-detected rectangle, in Vision NORMALIZED coordinates (0–1,
/// bottom-left origin). Mapped to preview-layer points by `CameraPreview.PreviewView`.
struct NormalizedQuad: Equatable {
    var topLeft: CGPoint
    var topRight: CGPoint
    var bottomRight: CGPoint
    var bottomLeft: CGPoint
}

/// Single-shot camera for receipt capture. Owns an `AVCaptureSession` + photo output and
/// hands the captured still (orientation-normalized to `.up`) to `onCapture`, which the
/// capture flow routes into the edge-adjust step — no multi-page scanner loop. A video data
/// output runs live document detection (`onLiveQuad`, via VNDetectDocumentSegmentation) so
/// the preview can highlight the receipt's edges before capture.
///
/// Device-only: the simulator has no camera, so `CameraStep` shows a neutral placeholder
/// under the hermetic test seam and this controller is never started there.
final class CameraController: NSObject, AVCapturePhotoCaptureDelegate,
                             AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "snapceipt.camera.session")
    private let detectQueue = DispatchQueue(label: "snapceipt.camera.detect")
    private var configured = false

    /// Delivered on the main thread with the captured, orientation-normalized image.
    var onCapture: ((UIImage) -> Void)?
    /// Set true when access is denied so the UI can prompt for Settings.
    var onAccessDenied: (() -> Void)?
    /// Live detected document (or nil) + the source buffer's pixel size, delivered on the
    /// main thread for the preview overlay (the size drives the aspect-fill mapping).
    var onLiveQuad: ((NormalizedQuad?, CGSize) -> Void)?

    // Apple's ML document detector (same family the system scanner uses) — far more accurate
    // on receipts/cluttered backgrounds than the geometric VNDetectRectanglesRequest.
    private let docRequest = VNDetectDocumentSegmentationRequest()
    /// Throttle live detection (segmentation is heavier than rectangle detection).
    private var lastDetect: CFTimeInterval = 0

    func start() {
        requestAccess { [weak self] granted in
            guard let self else { return }
            guard granted else { self.onAccessDenied?(); return }
            self.queue.async {
                self.configureIfNeeded()
                if !self.session.isRunning { self.session.startRunning() }
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    func capture(flashOn: Bool) {
        queue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            let settings = AVCapturePhotoSettings()
            if self.output.supportedFlashModes.contains(flashOn ? .on : .off) {
                settings.flashMode = flashOn ? .on : .off
            }
            self.output.capturePhoto(with: settings, delegate: self)
        }
    }

    // MARK: Setup

    private func requestAccess(_ done: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            done(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { done(granted) }
            }
        default:
            DispatchQueue.main.async { done(false) }
        }
    }

    /// Configure once on the session queue. Back wide-angle camera + JPEG photo output + a
    /// portrait-oriented video data output for live detection.
    private func configureIfNeeded() {
        guard !configured else { return }
        configured = true
        session.beginConfiguration()
        session.sessionPreset = .photo
        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
        }
        if session.canAddOutput(output) { session.addOutput(output) }

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: detectQueue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        // Deliver portrait-upright buffers so Vision (.up) + the portrait preview agree.
        if let conn = videoOutput.connection(with: .video) {
            if #available(iOS 17.0, *) {
                if conn.isVideoRotationAngleSupported(90) { conn.videoRotationAngle = 90 }
            } else if conn.isVideoOrientationSupported {
                conn.videoOrientation = .portrait
            }
        }
        session.commitConfiguration()
    }

    // MARK: AVCapturePhotoCaptureDelegate

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil,
              let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data) else { return }
        let normalized = image.normalizedUp()
        DispatchQueue.main.async { [weak self] in self?.onCapture?(normalized) }
    }

    // MARK: AVCaptureVideoDataOutputSampleBufferDelegate (live edge detection)

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard onLiveQuad != nil, let pixel = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let now = CACurrentMediaTime()
        guard now - lastDetect >= 0.1 else { return }   // ~10 fps cap (runs on the serial queue)
        lastDetect = now
        let size = CGSize(width: CVPixelBufferGetWidth(pixel), height: CVPixelBufferGetHeight(pixel))
        let handler = VNImageRequestHandler(cvPixelBuffer: pixel, orientation: .up, options: [:])
        try? handler.perform([docRequest])
        let quad = docRequest.results?.first.map { obs in
            NormalizedQuad(topLeft: obs.topLeft, topRight: obs.topRight,
                           bottomRight: obs.bottomRight, bottomLeft: obs.bottomLeft)
        }
        DispatchQueue.main.async { [weak self] in self?.onLiveQuad?(quad, size) }
    }
}

/// Live preview layer for the capture session, with an optional detected-edge overlay drawn
/// on top (mapped from Vision normalized coords through the preview layer's own geometry, so
/// it tracks the `.resizeAspectFill` crop correctly).
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    var quad: NormalizedQuad?
    var bufferSize: CGSize

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.showQuad(quad, bufferSize: bufferSize)
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        private let shape = CAShapeLayer()

        override init(frame: CGRect) {
            super.init(frame: frame)
            shape.fillColor = UIColor.systemGreen.withAlphaComponent(0.16).cgColor
            shape.strokeColor = UIColor.systemGreen.cgColor
            shape.lineWidth = 2
            layer.addSublayer(shape)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layoutSubviews() { super.layoutSubviews(); shape.frame = bounds }

        /// Map the Vision quad (normalized, bottom-left origin, in the portrait video buffer)
        /// to view points by replicating the preview layer's `.resizeAspectFill` transform —
        /// scale the buffer to fill the view (cropping overflow) and center it. This mirrors
        /// exactly what the preview draws, so the overlay aligns regardless of the
        /// capture-device coordinate-space ambiguity in `layerPointConverted`.
        func showQuad(_ quad: NormalizedQuad?, bufferSize: CGSize) {
            guard let quad, bufferSize.width > 0, bufferSize.height > 0,
                  bounds.width > 0, bounds.height > 0 else { shape.path = nil; return }
            let bw = bufferSize.width, bh = bufferSize.height
            let scale = max(bounds.width / bw, bounds.height / bh)   // aspect-FILL
            let ox = (bounds.width - bw * scale) / 2
            let oy = (bounds.height - bh * scale) / 2
            func cv(_ p: CGPoint) -> CGPoint {
                // norm (bottom-left) → buffer px (top-left) → scaled+offset view point.
                CGPoint(x: ox + (p.x * bw) * scale, y: oy + ((1 - p.y) * bh) * scale)
            }
            let path = UIBezierPath()
            path.move(to: cv(quad.topLeft))
            path.addLine(to: cv(quad.topRight))
            path.addLine(to: cv(quad.bottomRight))
            path.addLine(to: cv(quad.bottomLeft))
            path.close()
            // Disable implicit animation so the overlay tracks the receipt without lag.
            CATransaction.begin(); CATransaction.setDisableActions(true)
            shape.path = path.cgPath
            CATransaction.commit()
        }
    }
}

extension UIImage {
    /// Redraw to `.up` orientation so downstream OCR, cropping, and display don't have to
    /// reason about EXIF orientation. No-op when already upright.
    func normalizedUp() -> UIImage {
        guard imageOrientation != .up else { return self }
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in draw(in: CGRect(origin: .zero, size: size)) }
    }
}
