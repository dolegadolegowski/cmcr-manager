import CoreGraphics
import Foundation
import ImageIO

/// Size and display arithmetic of a capture.
public enum ImageMath {
    /// The size to capture a `width`×`height` display at so that its longer side is at most `maxSide`, keeping the
    /// aspect ratio. Never larger than the display itself (no upscaling).
    public static func fit(width: Int, height: Int, maxSide: Int) -> (width: Int, height: Int) {
        guard width > 0, height > 0, maxSide > 0 else { return (max(width, 0), max(height, 0)) }
        let longer = max(width, height)
        guard longer > maxSide else { return (width, height) }
        // Integer rounding to the nearest pixel, the longer side exactly maxSide.
        if width >= height {
            return (maxSide, max(1, (height * maxSide + width / 2) / width))
        }
        return (max(1, (width * maxSide + height / 2) / height), maxSide)
    }

    /// Display IDs in `screencapture -D` order: the main display first, then the others in the order of
    /// `CGGetActiveDisplayList`. A main display that is not active (no list entry) is left out.
    public static func orderedDisplays(main: UInt32, active: [UInt32]) -> [UInt32] {
        var seen = Set<UInt32>()
        let unique = active.filter { seen.insert($0).inserted }
        guard unique.contains(main) else { return unique }
        return [main] + unique.filter { $0 != main }
    }
}

/// JPEG encoding through ImageIO (no AppKit, no window server).
public enum JPEGCodec {
    /// `image` as a JPEG of the given quality (10–100), `nil` when ImageIO fails.
    public static func encode(_ image: CGImage, quality: Int) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, "public.jpeg" as CFString, 1, nil) else {
            return nil
        }
        let q = Double(min(max(quality, 1), 100)) / 100
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: q] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// Whether `data` starts like a JPEG file (SOI marker).
    public static func looksLikeJPEG(_ data: Data) -> Bool {
        data.count >= 3 && data[data.startIndex] == 0xFF && data[data.startIndex + 1] == 0xD8
            && data[data.startIndex + 2] == 0xFF
    }

    /// Pixel size of encoded image data, read from its header.
    public static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else {
            return nil
        }
        return (w, h)
    }

    /// `image` reduced so that its longer side is at most `maxSide` (the same image when it already fits).
    public static func downscaled(_ image: CGImage, maxSide: Int) -> CGImage? {
        let size = ImageMath.fit(width: image.width, height: image.height, maxSide: maxSide)
        if size.width == image.width && size.height == image.height { return image }
        guard let ctx = CGContext(data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
            return nil
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        return ctx.makeImage()
    }
}

/// The picture the DEBUG test mode returns instead of a screenshot: a solid background with a few rectangles. Its
/// colours depend on `variant` and the display number, so a changed screen gives a different file.
public enum TestPattern {
    public static func make(width: Int, height: Int, display: Int, variant: Bool) -> CGImage? {
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
            return nil
        }
        let shift = CGFloat(display - 1) * 0.15
        let base: (CGFloat, CGFloat, CGFloat) = variant ? (0.80, 0.35 + shift / 2, 0.20) : (0.15, 0.35 + shift / 2, 0.75)
        ctx.setFillColor(red: base.0, green: base.1, blue: base.2, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let w = CGFloat(width), h = CGFloat(height)
        let boxes: [(CGRect, (CGFloat, CGFloat, CGFloat))] = [
            (CGRect(x: w * 0.05, y: h * 0.70, width: w * 0.40, height: h * 0.20), (1, 1, 1)),
            (CGRect(x: w * 0.55, y: h * 0.10, width: w * 0.35, height: h * 0.45), (0.1, 0.1, 0.1)),
            (CGRect(x: w * 0.10, y: h * 0.15, width: w * 0.30, height: h * 0.35), variant ? (0.2, 0.8, 0.3) : (0.95, 0.8, 0.1)),
        ]
        for (rect, c) in boxes {
            ctx.setFillColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
            ctx.fill(rect)
        }
        return ctx.makeImage()
    }
}
