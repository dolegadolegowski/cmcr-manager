import CoreGraphics
import Foundation
import ImageIO

/// Layout arithmetic of the screen wall.
public enum ScreenLayout {
    /// Column count that shows all `count` tiles in a `width`×`height` area with the largest tile, when every
    /// row fits; `chrome` is the extra height of a tile below its image, `aspect` the image width/height.
    public static func fitColumns(count: Int, width: Double, height: Double, spacing: Double,
                                  aspect: Double = 16.0 / 10.0, chrome: Double = 0, maxColumns: Int = 8) -> Int {
        guard count > 1, width > 0, height > 0, aspect > 0 else { return 1 }
        var best = 1
        var bestWidth = -Double.infinity
        for c in 1...max(1, min(count, maxColumns)) {
            let rows = Double((count + c - 1) / c)
            let byWidth = (width - spacing * Double(c - 1)) / Double(c)
            let byHeight = ((height - spacing * (rows - 1)) / rows - chrome) * aspect
            let w = min(byWidth, byHeight)
            if w > bestWidth + 0.5 {
                best = c
                bestWidth = w
            }
        }
        return best
    }

    /// Columns for tiles of at least `minTileWidth` points.
    public static func adaptiveColumns(width: Double, minTileWidth: Double, spacing: Double, maxColumns: Int = 12) -> Int {
        guard width > 0, minTileWidth > 0 else { return 1 }
        let c = Int((width + spacing) / (minTileWidth + spacing))
        return min(maxColumns, max(1, c))
    }

    public static func tileWidth(columns: Int, width: Double, spacing: Double) -> Double {
        let c = Double(max(1, columns))
        return max(0, (width - spacing * (c - 1)) / c)
    }

    /// Pixel width to request for a tile `points` wide: rounded up to `step` so resizing a window does not
    /// change the request on every pixel, at least `minimum` and at most `cap`.
    public static func captureSize(points: Double, scale: Double, cap: Int, step: Int = 160, minimum: Int = 320) -> Int {
        let px = max(0, points) * max(1, scale)
        let stepped = Int((px / Double(step)).rounded(.up)) * step
        return min(max(minimum, cap), max(minimum, stepped))
    }
}

/// How current a preview is.
public enum ScreenFreshness: Equatable, Sendable {
    case fresh, stale, old

    public static func of(age: TimeInterval, interval: Int) -> ScreenFreshness {
        let i = Double(max(1, interval))
        if age <= 2 * i + 5 { return .fresh }
        if age <= 6 * i + 30 { return .stale }
        return .old
    }
}

/// Timing rules of the capture sessions.
public enum ScreenSchedule {
    /// Wait before the next connection attempt after `failures` failed ones: 0, 10, 20, 40, 80, then 120 s.
    public static func backoff(failures: Int, base: TimeInterval = 10, cap: TimeInterval = 120) -> TimeInterval {
        guard failures > 0 else { return 0 }
        return min(cap, base * pow(2, Double(min(failures - 1, 16))))
    }

    /// Random start delay that spreads ssh handshakes (and sudo) of many hosts.
    public static func jitter(maximum: TimeInterval, random: Double = Double.random(in: 0..<1)) -> TimeInterval {
        max(0, maximum) * min(1, max(0, random))
    }

    /// A live session that sent nothing for this long is considered hung and restarted.
    public static func watchdogLimit(interval: Int) -> TimeInterval {
        max(45, 3 * Double(max(1, interval)) + 20)
    }

    /// Shortest interval and largest size requested by the observers of one host.
    public static func merge(_ requests: [(pixels: Int, interval: Int)], fallbackInterval: Int) -> (pixels: Int, interval: Int)? {
        guard !requests.isEmpty else { return nil }
        let px = requests.map(\.pixels).max() ?? 0
        let iv = requests.map(\.interval).filter { $0 > 0 }.min() ?? fallbackInterval
        return (px, ScreenCaptureOptions.clampedInterval(iv))
    }
}

/// Remembers which console user was told about the observation, per Mac, for one observation session.
///
/// A session lasts while the Mac is observed somewhere in the app; after `grace` seconds without any
/// observer it ends, and the next preview notifies the user again. A different console user is always
/// notified (the capture script compares the user with `notifiedUser`).
public struct ObservationLedger: Sendable {
    public var grace: TimeInterval
    private var notified: [UUID: String] = [:]
    private var logged: [UUID: String] = [:]
    private var unobservedSince: [UUID: Date] = [:]

    public init(grace: TimeInterval = 120) { self.grace = grace }

    public func notifiedUser(_ host: UUID) -> String? { notified[host] }

    public mutating func recordNotified(_ host: UUID, user: String) { notified[host] = user }

    /// True the first time `user` is seen on `host` in this session (for the audit log).
    public mutating func shouldLog(_ host: UUID, user: String) -> Bool {
        if logged[host] == user { return false }
        logged[host] = user
        return true
    }

    public mutating func observed(_ host: UUID, at now: Date) {
        if let since = unobservedSince[host], now.timeIntervalSince(since) >= grace { end(host) }
        unobservedSince[host] = nil
    }

    public mutating func unobserved(_ host: UUID, at now: Date) {
        if unobservedSince[host] == nil { unobservedSince[host] = now }
    }

    /// Ends the sessions of hosts unobserved for at least `grace`; returns them.
    @discardableResult
    public mutating func expire(at now: Date) -> [UUID] {
        let ended = unobservedSince.filter { now.timeIntervalSince($0.value) >= grace }.map(\.key)
        for h in ended {
            end(h)
            unobservedSince[h] = nil
        }
        return ended
    }

    public mutating func endAll() {
        notified = [:]
        logged = [:]
        unobservedSince = [:]
    }

    private mutating func end(_ host: UUID) {
        notified[host] = nil
        logged[host] = nil
    }
}

/// Decoding and composing preview images (thread-safe, meant for background queues).
public enum ScreenImage {
    /// Decodes JPEG data into a bitmap no larger than `maxPixel`, fully decoded so drawing it costs nothing.
    public static func decode(_ data: Data, maxPixel: Int) -> CGImage? {
        guard !data.isEmpty, let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(16, maxPixel),
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
    }

    /// Places several displays side by side (scaled to a common height).
    public static func sideBySide(_ images: [CGImage], gap: Int = 8) -> CGImage? {
        guard let first = images.first else { return nil }
        if images.count == 1 { return first }
        let height = images.map(\.height).max() ?? first.height
        let widths = images.map { Int((Double($0.width) * Double(height) / Double(max(1, $0.height))).rounded()) }
        let total = widths.reduce(0, +) + gap * (images.count - 1)
        guard total > 0, height > 0,
              let ctx = CGContext(data: nil, width: total, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: total, height: height))
        ctx.interpolationQuality = .high
        var x = 0
        for (img, w) in zip(images, widths) {
            ctx.draw(img, in: CGRect(x: x, y: 0, width: w, height: height))
            x += w + gap
        }
        return ctx.makeImage()
    }

    /// JPEG (or PNG) file data of an image, e.g. for "Zapisz zrzut".
    public static func encode(_ image: CGImage, type: String = "public.jpeg", quality: Double = 0.9) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, type as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}
