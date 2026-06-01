import UIKit
import Vision

/// One recognized line of text with its geometry. `boundingBox` is normalized
/// [0,1] with origin at BOTTOM-LEFT (Vision convention).
struct RecognizedLine: Identifiable {
    let id = UUID()
    let text: String
    let confidence: Float
    let boundingBox: CGRect
}

/// On-device text recognition (the engine behind Live Text). AUD receipts are
/// English; Vision has no `en-AU` tag, so we request `["en-US","en-GB"]`.
enum OCR {
    enum Failure: Error { case noCGImage }

    static func recognize(in image: UIImage,
                          languages: [String] = ["en-US", "en-GB"]) async throws -> [RecognizedLine] {
        guard let cgImage = image.cgImage else { throw Failure.noCGImage }

        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error { continuation.resume(throwing: error); return }
                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                let lines: [RecognizedLine] = observations.compactMap { obs in
                    guard let best = obs.topCandidates(1).first else { return nil }
                    return RecognizedLine(text: best.string,
                                          confidence: best.confidence,
                                          boundingBox: obs.boundingBox)
                }
                continuation.resume(returning: lines)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = languages

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do { try handler.perform([request]) }
            catch { continuation.resume(throwing: error) }
        }
    }
}
