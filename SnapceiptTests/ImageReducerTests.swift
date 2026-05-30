import Testing
import UIKit
@testable import Snapceipt

struct ImageReducerTests {
    /// A solid-color image of a given size. Noisy detail would only inflate bytes;
    /// a large dimension guarantees the downscale branch runs.
    private func image(width: CGFloat, height: CGFloat) -> UIImage {
        let size = CGSize(width: width, height: height)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }

    @Test("downscales the longest edge to <= 2000px and bounds bytes to <= 1_500_000")
    func reducesDimensionsAndBytes() {
        let reducer = ImageReducer()
        let big = image(width: 4032, height: 3024)
        let data = reducer.reduce(big)
        #expect(!data.isEmpty)
        #expect(data.count <= 1_500_000)
        let out = UIImage(data: data)!
        #expect(max(out.size.width, out.size.height) <= 2000)
        // Aspect preserved (4:3 within rounding).
        #expect(abs(out.size.width / out.size.height - 4032.0 / 3024.0) < 0.02)
    }

    @Test("a small image is not upscaled")
    func smallImageUnchangedDimensions() {
        let reducer = ImageReducer()
        let small = image(width: 800, height: 600)
        let out = UIImage(data: reducer.reduce(small))!
        #expect(max(out.size.width, out.size.height) <= 800)
    }
}
