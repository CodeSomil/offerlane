import XCTest
import AppKit

/// WCAG contrast measured from an element's own pixels, worst case: the strongest text pixel against the
/// weakest background pixel on the element's border (where there's no text). Used to confirm or reject the
/// accessibility audit's contrast sampler, which misreads text over gradients and long scroll views.
enum MeasuredContrast {
    static func ratio(_ element: XCUIElement) -> Double {
        // Pad the frame: it hugs the glyphs, and the border must be background only.
        guard let screen = XCUIScreen.main.screenshot().image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let points = NSScreen.main?.frame.width else { return 0 }
        let scale = CGFloat(screen.width) / points
        let f = element.frame.insetBy(dx: -4, dy: -4)
        guard let crop = screen.cropping(to: CGRect(x: f.minX * scale, y: f.minY * scale, width: f.width * scale, height: f.height * scale)) else { return 0 }
        return ratio(crop)
    }

    static func ratio(_ cg: CGImage) -> Double {
        let w = cg.width, h = cg.height
        guard w > 4, h > 4 else { return 0 }
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        func lum(_ x: Int, _ y: Int) -> Double {
            let i = (y * w + x) * 4
            func c(_ v: UInt8) -> Double { let s = Double(v) / 255; return s <= 0.03928 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4) }
            return 0.2126 * c(px[i]) + 0.7152 * c(px[i + 1]) + 0.0722 * c(px[i + 2])
        }
        var all: [Double] = [], border: [Double] = []
        for y in 0..<h { for x in 0..<w {
            let l = lum(x, y); all.append(l)
            if x < 2 || y < 2 || x >= w - 2 || y >= h - 2 { border.append(l) }
        } }
        border.sort()
        let lightBackground = border[border.count / 2] > 0.4
        let (text, bg) = lightBackground ? (all.min()!, border.first!) : (all.max()!, border.last!)
        return (max(text, bg) + 0.05) / (min(text, bg) + 0.05)
    }
}

final class MeasuredContrastTests: XCTestCase {
    /// The measurer itself: dark text on a light gradient passes, faint text fails.
    func testMeasurer() {
        XCTAssertGreaterThan(MeasuredContrast.ratio(image(text: 0x4A, bg: (0xDD, 0xF3))), 4.5)
        XCTAssertLessThan(MeasuredContrast.ratio(image(text: 0xB0, bg: (0xDD, 0xF3))), 4.5)
    }

    private func image(text: UInt8, bg: (UInt8, UInt8)) -> CGImage {
        let w = 40, h = 20
        var px = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let i = (y * w + x) * 4
            let v = (8..<12).contains(y) && (8..<32).contains(x) ? text : UInt8(Int(bg.0) + (Int(bg.1) - Int(bg.0)) * x / w)
            px[i] = v; px[i + 1] = v; px[i + 2] = v
        } }
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }
}
