import SwiftUI
import AVFoundation
import UIKit

/// Single-shot camera for receipt capture. Owns an `AVCaptureSession` + photo output and
/// hands the captured still (orientation-normalized to `.up`) to `onCapture`, which the
/// capture flow routes into the Confirm/Retake step — no multi-page scanner loop.
///
/// Device-only: the simulator has no camera, so `CameraStep` shows a neutral placeholder
/// under the hermetic test seam and this controller is never started there.
final class CameraController: NSObject, AVCapturePhotoCaptureDelegate {
    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "snapceipt.camera.session")
    private var configured = false

    /// Delivered on the main thread with the captured, orientation-normalized image.
    var onCapture: ((UIImage) -> Void)?
    /// Set true when access is denied so the UI can prompt for Settings.
    var onAccessDenied: (() -> Void)?

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

    /// Configure once on the session queue. Back wide-angle camera + JPEG photo output.
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
}

/// Live preview layer for the capture session.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
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
