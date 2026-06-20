import Testing
import UIKit
@testable import Snapceipt

/// The edge-adjust geometry (image px ↔ view points) and the dewarp are pure functions; the
/// coordinate mapping is where corner-handle bugs hide, so it's pinned here.
struct DocumentScanTests {
    private func solidImage(_ size: CGSize) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
        }
    }

    @Test("aspectFitRect centers a portrait image fit by height")
    func aspectFit() {
        let rect = EdgeAdjustView.aspectFitRect(imageSize: CGSize(width: 100, height: 200),
                                                in: CGSize(width: 100, height: 100))
        #expect(rect.width == 50)
        #expect(rect.height == 100)
        #expect(rect.minX == 25)   // centered horizontally
        #expect(rect.minY == 0)
    }

    @Test("toView / toImage are inverses")
    func roundTrip() {
        let imageSize = CGSize(width: 300, height: 400)
        let rect = EdgeAdjustView.aspectFitRect(imageSize: imageSize, in: CGSize(width: 200, height: 200))
        let p = CGPoint(x: 120, y: 250)
        let view = EdgeAdjustView.toView(p, imageSize: imageSize, rect: rect)
        let back = EdgeAdjustView.toImage(view, imageSize: imageSize, rect: rect)
        #expect(abs(back.x - p.x) < 0.001)
        #expect(abs(back.y - p.y) < 0.001)
    }

    @Test("clampToImage keeps points within bounds")
    func clamp() {
        let size = CGSize(width: 100, height: 100)
        #expect(EdgeAdjustView.clampToImage(CGPoint(x: -20, y: 130), imageSize: size) == CGPoint(x: 0, y: 100))
        #expect(EdgeAdjustView.clampToImage(CGPoint(x: 40, y: 60), imageSize: size) == CGPoint(x: 40, y: 60))
    }

    @Test("defaultInset is inside the image and ordered")
    func defaultInset() {
        let q = DocumentQuad.defaultInset(width: 100, height: 100)
        #expect(q.topLeft.x > 0 && q.topLeft.y > 0)
        #expect(q.topRight.x > q.topLeft.x)
        #expect(q.bottomLeft.y > q.topLeft.y)
        #expect(q.bottomRight.x < 100 && q.bottomRight.y < 100)
    }

    @Test("Corner set/get round-trips each corner")
    func corners() {
        var q = DocumentQuad.defaultInset(width: 100, height: 100)
        for corner in EdgeAdjustView.Corner.allCases {
            let p = CGPoint(x: 42, y: 7)
            corner.set(p, in: &q)
            #expect(corner.point(in: q) == p)
        }
    }

    @Test("dewarp returns a non-nil image for a valid quad")
    func dewarp() {
        let img = solidImage(CGSize(width: 200, height: 300))
        let quad = DocumentQuad(topLeft: CGPoint(x: 10, y: 10),
                                topRight: CGPoint(x: 190, y: 20),
                                bottomRight: CGPoint(x: 180, y: 290),
                                bottomLeft: CGPoint(x: 20, y: 280))
        let out = DocumentScan.dewarp(img, quad: quad)
        #expect(out != nil)
        #expect((out?.size.width ?? 0) > 0)
    }
}
