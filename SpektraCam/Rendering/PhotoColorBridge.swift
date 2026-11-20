import CoreGraphics
import CoreImage
import Foundation

/// Working floating-point depth for Core Image, cached intermediates, grading textures and
/// tiled stores. Going below 16-bit float (e.g. 8-bit integer) clips scene-linear highlights
/// above 1.0 and bands shadows; IEEE 754 binary16 preserves ~16 stops of headroom at half memory.
nonisolated enum RenderPrecision: String, CaseIterable, Identifiable, Sendable {
    case automatic = "auto"
    case float32 = "float32"
    case float16 = "float16"

    static let storageKey = "render.precision"
    var id: String { rawValue }

    /// Devices under ~5.5 GB physical RAM (2–4 GB iPhones and iPads) default to 16-bit float.
    static var devicePrefersHalfFloat: Bool {
        #if os(iOS) && !targetEnvironment(simulator)
            return ProcessInfo.processInfo.physicalMemory < 5_500_000_000
        #else
            return false
        #endif
    }

    static var selected: Self {
        Self(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .automatic
    }

    static var resolved: Self {
        switch selected {
        case .automatic: devicePrefersHalfFloat ? .float16 : .float32
        case .float16: .float16
        case .float32: .float32
        }
    }

    var usesHalfFloat: Bool {
        (self == .automatic ? Self.resolved : self) == .float16
    }

    var ciFormat: CIFormat { usesHalfFloat ? .RGBAh : .RGBAf }
    var bytesPerPixel: Int { usesHalfFloat ? 8 : 16 }
}

/// Color-managed boundary: tagged photo → linear extended sRGB → encoded SDR sRGB.
/// No transfer curve is applied twice; the film graph consumes linear RGB and returns encoded RGB.
nonisolated enum PhotoColorBridge {
    enum Failure: Error { case invalidImage, bitmap }
    private static let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private static let display = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let context32 = CIContext(options: [
        .workingColorSpace: linear, .workingFormat: CIFormat.RGBAf,
        .cacheIntermediates: false,
    ])
    private static let context16 = CIContext(options: [
        .workingColorSpace: linear, .workingFormat: CIFormat.RGBAh,
        .cacheIntermediates: false,
    ])
    private static var context: CIContext {
        RenderPrecision.resolved.usesHalfFloat ? context16 : context32
    }

    static func decode(_ source: CGImage) throws -> [SIMD4<Float>] {
        let count = source.width * source.height
        guard count > 0 else { throw Failure.invalidImage }
        var pixels = Array(repeating: SIMD4<Float>.zero, count: count)
        pixels.withUnsafeMutableBytes { bytes in
            context.render(
                CIImage(cgImage: source), toBitmap: bytes.baseAddress!,
                rowBytes: source.width * 16,
                bounds: CGRect(x: 0, y: 0, width: source.width, height: source.height),
                format: .RGBAf, colorSpace: linear)
        }
        // Photograph editing uses an opaque black background, matching the preview/export contract.
        for i in pixels.indices { pixels[i].w = 1 }
        guard pixels.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else {
            throw Failure.invalidImage
        }
        return pixels
    }

    /// Preserve extended-range film output until all creative grading has finished.
    static func workingImage(_ data: Data, width: Int, height: Int, encoded: Bool = true) throws -> CGImage {
        let inputFormat: CIFormat
        let rowBytes: Int
        if data.count == width * height * 16 {
            inputFormat = .RGBAf
            rowBytes = width * 16
        } else if data.count == width * height * 8 {
            inputFormat = .RGBAh
            rowBytes = width * 8
        } else {
            throw Failure.invalidImage
        }
        let input = CIImage(
            bitmapData: data, bytesPerRow: rowBytes,
            size: CGSize(width: width, height: height), format: inputFormat,
            colorSpace: encoded ? CGColorSpace(name: CGColorSpace.extendedSRGB)! : linear)
        guard
            let image = context.createCGImage(
                input, from: input.extent, format: RenderPrecision.resolved.ciFormat,
                colorSpace: linear, deferred: false)
        else { throw Failure.bitmap }
        return image
    }
    static func encode(_ encoded: [SIMD4<Float>], width: Int, height: Int) throws -> CGImage {
        guard width > 0, height > 0, encoded.count == width * height else { throw Failure.invalidImage }
        let data = encoded.withUnsafeBytes { Data($0) }
        return try encode(data, width: width, height: height)
    }
    static func encode(_ data: Data, width: Int, height: Int) throws -> CGImage {
        guard data.count == width * height * 16 else { throw Failure.invalidImage }
        let input = CIImage(
            bitmapData: data, bytesPerRow: width * 16,
            size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: display)
        guard
            let image = context.createCGImage(
                input, from: input.extent,
                format: .RGBA8, colorSpace: display, deferred: false)
        else { throw Failure.bitmap }
        return image
    }
}
