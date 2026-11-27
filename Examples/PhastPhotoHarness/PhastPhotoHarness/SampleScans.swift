import UIKit

/// Synthetic scans for exercising the pipeline without a scanner: a 6×4 in print, tilted a little, on the
/// FF-680W's grey backing across the full 8.5 in feeder width, at the chosen resolution, as JPEG. The back has
/// two lines of "handwriting" (so on a device Vision has something to read) and a lab-style code the
/// human-text filter should drop. Nothing here comes from a real photo.
enum SampleScans {
    static let backing = UIColor(red: 176 / 255, green: 172 / 255, blue: 165 / 255, alpha: 1)
    static let paper = UIColor(red: 236 / 255, green: 232 / 255, blue: 222 / 255, alpha: 1)
    static let backLines = ["Summer 1974", "at the beach"]
    static let labCode = "0423 17 N 2"

    /// The picture (side B) and the back (side A) of sample `seed`. The same seed gives the same picture,
    /// which the duplicate check should flag.
    static func pair(dpi: Int, seed: Int) -> (picture: Data, back: Data) {
        (scan(dpi: dpi) { drawPicture(in: $0, seed: seed) }, scan(dpi: dpi, drawBack))
    }

    private static func scan(dpi: Int, _ drawPrint: (CGRect) -> Void) -> Data {
        let d = CGFloat(dpi)
        let size = CGSize(width: 8.5 * d, height: 4.8 * d)
        let print = CGRect(x: 1.1 * d, y: 0.4 * d, width: 6 * d, height: 4 * d)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            backing.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let cg = context.cgContext
            cg.translateBy(x: print.midX, y: print.midY)
            cg.rotate(by: 1.5 * .pi / 180)  // a slightly skewed feed: the crop should straighten it
            cg.translateBy(x: -print.width / 2, y: -print.height / 2)
            drawPrint(CGRect(origin: .zero, size: print.size))
        }
        return image.jpegData(compressionQuality: 0.9) ?? Data()
    }

    /// A simple landscape: sky, sun, sea, sand and beach umbrellas. The seed moves the horizon, the sun and
    /// the umbrellas, enough for the difference hash to tell samples apart.
    private static func drawPicture(in rect: CGRect, seed: Int) {
        let cg = UIGraphicsGetCurrentContext()!
        let w = rect.width, h = rect.height
        let horizon = h * [0.42, 0.55, 0.35, 0.62][seed % 4]
        let space = CGColorSpaceCreateDeviceRGB()
        let sky = CGGradient(colorsSpace: space, colors: [UIColor(red: 0.25, green: 0.45, blue: 0.85, alpha: 1).cgColor,
                                                          UIColor(red: 0.75, green: 0.85, blue: 0.95, alpha: 1).cgColor] as CFArray,
                             locations: [0, 1])!
        cg.saveGState()
        cg.clip(to: CGRect(x: 0, y: 0, width: w, height: horizon))
        cg.drawLinearGradient(sky, start: .zero, end: CGPoint(x: 0, y: horizon), options: [])
        cg.restoreGState()

        UIColor(red: 1, green: 0.85, blue: 0.3, alpha: 1).setFill()
        let sunX = w * [0.2, 0.75, 0.5, 0.85][(seed / 4 + seed) % 4]
        cg.fillEllipse(in: CGRect(x: sunX - 0.07 * h, y: horizon * 0.3, width: 0.14 * h, height: 0.14 * h))

        UIColor(red: 0.1, green: 0.35, blue: 0.55, alpha: 1).setFill()
        cg.fill(CGRect(x: 0, y: horizon, width: w, height: (h - horizon) * 0.45))
        UIColor(red: 0.88, green: 0.78, blue: 0.55, alpha: 1).setFill()
        cg.fill(CGRect(x: 0, y: horizon + (h - horizon) * 0.45, width: w, height: (h - horizon) * 0.55))

        let colours: [UIColor] = [.systemRed, .systemOrange, .systemGreen, .systemPurple]
        for i in 0 ..< 3 {
            let x = w * (0.15 + 0.3 * Double(i) + 0.05 * Double((seed + i) % 3))
            let top = horizon + (h - horizon) * 0.55
            UIColor.darkGray.setFill()
            cg.fill(CGRect(x: x - 0.004 * w, y: top, width: 0.008 * w, height: (h - top) * 0.7))
            colours[(seed + i) % colours.count].setFill()
            cg.move(to: CGPoint(x: x - 0.08 * w, y: top + 0.02 * h))
            cg.addQuadCurve(to: CGPoint(x: x + 0.08 * w, y: top + 0.02 * h), control: CGPoint(x: x, y: top - 0.12 * h))
            cg.closePath()
            cg.fillPath()
        }
    }

    private static func drawBack(in rect: CGRect) {
        paper.setFill()
        UIRectFill(rect)
        let hand = UIFont(name: "Noteworthy-Bold", size: rect.height * 0.11) ?? .systemFont(ofSize: rect.height * 0.11)
        let ink = UIColor(red: 0.15, green: 0.15, blue: 0.4, alpha: 1)
        for (i, line) in backLines.enumerated() {
            (line as NSString).draw(at: CGPoint(x: rect.width * 0.12, y: rect.height * (0.25 + 0.17 * Double(i))),
                                    withAttributes: [.font: hand, .foregroundColor: ink])
        }
        let code = UIFont.monospacedSystemFont(ofSize: rect.height * 0.035, weight: .regular)
        (labCode as NSString).draw(at: CGPoint(x: rect.width * 0.62, y: rect.height * 0.88),
                                   withAttributes: [.font: code, .foregroundColor: UIColor.gray])
    }
}
