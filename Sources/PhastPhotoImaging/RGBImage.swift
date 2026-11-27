import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One pixel. Always red, green, blue: unlike ffscan's BMP thumbnails, there is no blue-green-red order here.
public struct RGB: Hashable, Sendable, CustomStringConvertible {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8

    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }

    public var max: Int { Swift.max(Int(r), Int(g), Int(b)) }
    public var min: Int { Swift.min(Int(r), Int(g), Int(b)) }
    /// Spread between the brightest and darkest channel: 0 for neutral grey.
    public var chroma: Int { max - min }
    public var mean: Double { Double(Int(r) + Int(g) + Int(b)) / 3 }

    /// Sum of absolute channel differences.
    public func distance(to other: RGB) -> Int {
        abs(Int(r) - Int(other.r)) + abs(Int(g) - Int(other.g)) + abs(Int(b) - Int(other.b))
    }

    public var description: String { "(\(r), \(g), \(b))" }
}

/// 8-bit RGB pixels, top row first, three bytes per pixel with no row padding.
///
/// Images keep their *stored* orientation: decoding never applies the EXIF Orientation tag, because crop boxes
/// and Vision coordinates are in stored pixels.
public struct RGBImage: Hashable, Sendable {
    public let width: Int
    public let height: Int
    public var pixels: [UInt8]
    /// ICC profile of the colour space the pixel values are in, or `nil` for untagged (device) RGB.
    /// Decoding keeps an RGB source's own profile, so values are never converted; encoding writes it back.
    public var iccProfile: Data?

    public init(width: Int, height: Int, pixels: [UInt8], iccProfile: Data? = nil) {
        precondition(width > 0 && height > 0 && pixels.count == width * height * 3, "bad RGB buffer")
        self.width = width
        self.height = height
        self.pixels = pixels
        self.iccProfile = iccProfile
    }

    public init(width: Int, height: Int, fill: RGB) {
        var buffer = [UInt8](repeating: 0, count: width * height * 3)
        buffer.withUnsafeMutableBufferPointer { p in
            for i in stride(from: 0, to: p.count, by: 3) {
                p[i] = fill.r; p[i + 1] = fill.g; p[i + 2] = fill.b
            }
        }
        self.init(width: width, height: height, pixels: buffer)
    }

    /// Build an image from a function of (x, y); handy for synthetic test scans.
    public init(width: Int, height: Int, _ pixel: (Int, Int) -> RGB) {
        var buffer = [UInt8](repeating: 0, count: width * height * 3)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let p = pixel(x, y), o = (y * width + x) * 3
                buffer[o] = p.r; buffer[o + 1] = p.g; buffer[o + 2] = p.b
            }
        }
        self.init(width: width, height: height, pixels: buffer)
    }

    @inline(__always)
    public subscript(x: Int, y: Int) -> RGB {
        get {
            let o = (y * width + x) * 3
            return RGB(pixels[o], pixels[o + 1], pixels[o + 2])
        }
        set {
            let o = (y * width + x) * 3
            pixels[o] = newValue.r; pixels[o + 1] = newValue.g; pixels[o + 2] = newValue.b
        }
    }

    // MARK: - Geometry

    /// The pixels in `x0 ..< x1`, `y0 ..< y1`, clamped to the image.
    public func cropped(x0: Int, y0: Int, x1: Int, y1: Int) -> RGBImage {
        let x0 = Swift.max(0, Swift.min(width - 1, x0)), y0 = Swift.max(0, Swift.min(height - 1, y0))
        let x1 = Swift.max(x0 + 1, Swift.min(width, x1)), y1 = Swift.max(y0 + 1, Swift.min(height, y1))
        var out = [UInt8]()
        out.reserveCapacity((x1 - x0) * (y1 - y0) * 3)
        for y in y0 ..< y1 {
            let start = (y * width + x0) * 3
            out.append(contentsOf: pixels[start ..< start + (x1 - x0) * 3])
        }
        return RGBImage(width: x1 - x0, height: y1 - y0, pixels: out, iccProfile: iccProfile)
    }

    /// Scaled to fit within `maxPixelSize` on its longer side, keeping the aspect ratio (never enlarged).
    public func thumbnail(maxPixelSize: Int) -> RGBImage {
        let scale = Double(maxPixelSize) / Double(Swift.max(width, height))
        guard scale < 1 else { return self }
        return resized(width: Swift.max(1, Int((Double(width) * scale).rounded())),
                       height: Swift.max(1, Int((Double(height) * scale).rounded())))
    }

    /// Resampled with Core Graphics' high-quality interpolation.
    public func resized(width newWidth: Int, height newHeight: Int) -> RGBImage {
        guard newWidth != width || newHeight != height else { return self }
        guard let context = Self.context(width: newWidth, height: newHeight, space: colorSpace) else { return self }
        context.interpolationQuality = .high
        context.draw(cgImage(), in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
        return Self.read(context, width: newWidth, height: newHeight, iccProfile: iccProfile)
    }

    // MARK: - Core Graphics and ImageIO

    public enum CodingError: Error, Hashable, Sendable {
        case unreadableImage
        case encodingFailed
    }

    /// Pixels of `cgImage`. An RGB image keeps its own colour space (no conversion, profile kept in
    /// ``iccProfile``); grey and other models are converted to device RGB.
    public init(cgImage: CGImage) {
        let w = cgImage.width, h = cgImage.height
        var space = CGColorSpaceCreateDeviceRGB()
        var icc: Data?
        if let source = cgImage.colorSpace, source.model == .rgb, let data = source.copyICCData() as Data? {
            space = source
            icc = data
        }
        let context: CGContext
        if let own = Self.context(width: w, height: h, space: space) {
            context = own
        } else {  // a colour space CGBitmapContext can't draw into: convert
            context = Self.context(width: w, height: h, space: CGColorSpaceCreateDeviceRGB())!
            icc = nil
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        self = Self.read(context, width: w, height: h, iccProfile: icc)
    }

    /// The colour space for ``iccProfile`` (device RGB when untagged or unreadable).
    public var colorSpace: CGColorSpace {
        iccProfile.flatMap { CGColorSpace(iccData: $0 as CFData) } ?? CGColorSpaceCreateDeviceRGB()
    }

    /// Decode JPEG (or any ImageIO format) data in its stored orientation. With `maxPixelSize`, ImageIO decodes
    /// at reduced size (fast for JPEG), like Pillow's `draft` + `thumbnail`.
    public static func decode(_ data: Data, maxPixelSize: Int? = nil) throws -> RGBImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw CodingError.unreadableImage }
        let image: CGImage?
        if let maxPixelSize {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                kCGImageSourceCreateThumbnailWithTransform: false,  // stored orientation
                kCGImageSourceShouldCacheImmediately: true,
            ]
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        } else {
            image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        }
        guard let image else { throw CodingError.unreadableImage }
        return RGBImage(cgImage: image)
    }

    public func cgImage() -> CGImage {
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: width * 3,
                       space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    }

    /// JPEG data. `properties` are ImageIO properties to write (EXIF, IPTC, XMP dictionaries, DPI), for example
    /// those read from the original file.
    public func jpegData(quality: Double = 0.95, properties: [CFString: Any] = [:]) throws -> Data {
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CodingError.encodingFailed
        }
        var options = properties
        options[kCGImageDestinationLossyCompressionQuality] = quality
        CGImageDestinationAddImage(destination, cgImage(), options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CodingError.encodingFailed }
        return out as Data
    }

    static func context(width: Int, height: Int, space: CGColorSpace) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    }

    static func read(_ context: CGContext, width: Int, height: Int, iccProfile: Data?) -> RGBImage {
        let rowBytes = context.bytesPerRow
        let source = context.data!.assumingMemoryBound(to: UInt8.self)
        var out = [UInt8](repeating: 0, count: width * height * 3)
        // CGContext memory is top row first
        out.withUnsafeMutableBufferPointer { d in
            for y in 0 ..< height {
                var s = y * rowBytes, o = y * width * 3
                for _ in 0 ..< width {
                    d[o] = source[s]; d[o + 1] = source[s + 1]; d[o + 2] = source[s + 2]
                    s += 4; o += 3
                }
            }
        }
        return RGBImage(width: width, height: height, pixels: out, iccProfile: iccProfile)
    }
}
