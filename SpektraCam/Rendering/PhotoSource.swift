import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

#if os(iOS)
    import os
#endif

/// File identity is independent of a recipe's white balance or creative look.
nonisolated enum PhotoSource {
    private static let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private static let previewContext = CIContext(options: [
        .workingColorSpace: linear, .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false,
    ])
    static func clearCaches() {
        previewContext.clearCaches()
    }
    static func checkDevelopmentMemory(width: Int, height: Int) throws {
        guard width > 0, height > 0, width <= 65536, height <= 65536,
            let device = MTLCreateSystemDefaultDevice(),
            UInt64(width) * UInt64(height) <= UInt64(device.maxBufferLength / 16)
        else { throw ImageMemoryAllowance.Failure() }
        try ImageMemoryAllowance.check(
            estimate: UInt64(width) * UInt64(height) * 64 + 96 * 1024 * 1024)
    }
    struct Description: Sendable {
        let type: String
        let isRAW: Bool
        let width: Int
        let height: Int
        let temperature: Double?
        let bitDepth: Int

        init(
            type: String, isRAW: Bool, width: Int, height: Int,
            temperature: Double?, bitDepth: Int? = nil
        ) {
            self.type = type
            self.isRAW = isRAW
            self.width = width
            self.height = height
            self.temperature = temperature
            self.bitDepth = bitDepth ?? (isRAW ? 16 : 8)
        }

        /// True for linear sensor RAWs and deep (>10-bit, e.g. 12/14/16-bit PNG or TIFF) sources.
        /// Compressed 8/10-bit JPEGs, HEICs and 8-bit PNGs fit losslessly in IEEE 754 binary16.
        var prefersDeepPipeline: Bool {
            isRAW || bitDepth > 10
        }
    }
    /// Every size used by Crop/finishing describes the upright decoded image, not sensor storage.
    static func uprightSize(width: Int, height: Int, orientation: CGImagePropertyOrientation) -> CGSize {
        switch orientation {
        case .leftMirrored, .right, .rightMirrored, .left: CGSize(width: height, height: width)
        default: CGSize(width: width, height: height)
        }
    }

    static func typeHint(for url: URL) -> String? {
        UTType(filenameExtension: url.pathExtension)?.identifier
    }

    /// Lightweight header-only bit-depth probe for memory admission without decoding pixels.
    static func prefersDeepPipeline(at url: URL) -> Bool {
        let hint = typeHint(for: url)
        if let hint, UTType(hint)?.conforms(to: .rawImage) == true { return true }
        var options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        if let hint { options[kCGImageSourceTypeIdentifierHint] = hint }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary) else {
            return true
        }
        if let detected = CGImageSourceGetType(source) as String?,
            UTType(detected)?.conforms(to: .rawImage) == true
        {
            return true
        }
        guard CGImageSourceGetCount(source) > 0,
            let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return false }
        let depth = max(1, (p[kCGImagePropertyDepth] as? NSNumber)?.intValue ?? 8)
        return depth > 10
    }

    static func imageSource(_ data: Data, typeHint: String? = nil) -> CGImageSource? {
        var options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        if let typeHint { options[kCGImageSourceTypeIdentifierHint] = typeHint }
        return CGImageSourceCreateWithData(data as CFData, options as CFDictionary)
    }

    static func describe(_ data: Data, typeHint: String? = nil) -> Description? {
        guard let source = imageSource(data, typeHint: typeHint),
            let detected = CGImageSourceGetType(source) as String?
        else { return nil }
        let type =
            typeHint.flatMap { UTType($0)?.conforms(to: .rawImage) == true ? $0 : nil }
            ?? detected
        let isRAW = UTType(type)?.conforms(to: .rawImage) == true
        if isRAW {
            guard let raw = CIRAWFilter(imageData: data, identifierHint: type),
                raw.nativeSize.width.isFinite, raw.nativeSize.height.isFinite,
                (1...65536).contains(raw.nativeSize.width),
                (1...65536).contains(raw.nativeSize.height),
                raw.neutralTemperature.isFinite, (1000...50000).contains(raw.neutralTemperature)
            else { return nil }
            let size = uprightSize(width: Int(raw.nativeSize.width), height: Int(raw.nativeSize.height), orientation: raw.orientation)
            return .init(
                type: type, isRAW: true, width: Int(size.width),
                height: Int(size.height), temperature: Double(raw.neutralTemperature), bitDepth: 16)
        }
        guard CGImageSourceGetCount(source) > 0,
            let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = p[kCGImagePropertyPixelWidth] as? Int,
            let height = p[kCGImagePropertyPixelHeight] as? Int,
            (1...65536).contains(width), (1...65536).contains(height)
        else { return nil }
        let orientation = CGImagePropertyOrientation(rawValue: (p[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1) ?? .up
        let depth = max(1, (p[kCGImagePropertyDepth] as? NSNumber)?.intValue ?? 8)
        let size = uprightSize(width: width, height: height, orientation: orientation)
        return .init(
            type: detected, isRAW: false, width: Int(size.width), height: Int(size.height),
            temperature: nil, bitDepth: depth)
    }

    /// Neutral development for viewing, photo LUTs and the film Mix zero endpoint.
    /// Gain-map SDR baselines are used directly; ISO HDR is deliberately tone-mapped.
    static func developedImage(_ data: Data, description: Description, maximum: Int) -> CIImage? {
        let image: CIImage
        if description.isRAW {
            guard let raw = CIRAWFilter(imageData: data, identifierHint: description.type) else {
                return nil
            }
            raw.scaleFactor = Float(
                min(1, Double(maximum) / Double(max(description.width, description.height))))
            guard let output = raw.outputImage else { return nil }
            image = output
        } else {
            guard
                let output = CIImage(
                    data: data,
                    options: [
                        .applyOrientationProperty: true,
                        .expandToHDR: false,
                        .toneMapHDRtoSDR: {
                            if #available(iOS 18.0, macOS 15.0, *) { return false }
                            return true
                        }(),
                    ])
            else { return nil }
            image = output
        }
        return resized(toSDR(image), maximum: maximum)
    }

    /// Materialize the tone-mapping operation before exporting pixels to a floating-point
    /// working buffer. A destination-dependent decode flag alone may leave HDR values intact.
    static func toSDR(_ image: CIImage) -> CIImage {
        if #available(iOS 18.0, macOS 15.0, *) {
            let headroom = image.contentHeadroom
            guard headroom > 1 else { return image }
            let mapped = image.applyingFilter(
                "CIToneMapHeadroom",
                parameters: [
                    "inputSourceHeadroom": headroom, "inputTargetHeadroom": 1.0,
                ]
            )
            if #available(iOS 26.0, macOS 26.0, *) {
                return mapped.settingContentHeadroom(1)
            }
            return mapped
        }
        return image
    }

    static func resized(_ image: CIImage, maximum: Int) -> CIImage {
        let scale = min(1, Double(maximum) / max(image.extent.width, image.extent.height))
        guard scale < 1 else { return image }
        return image.clampedToExtent().applyingFilter(
            "CILanczosScaleTransform",
            parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1]
        )
        .cropped(
            to: CGRect(
                x: image.extent.minX * scale, y: image.extent.minY * scale,
                width: max(1, floor(image.extent.width * scale)),
                height: max(1, floor(image.extent.height * scale))))
    }

    /// Decode an embedded RAW thumbnail on the CPU when it matches the sensor's aspect ratio
    /// and meets `maximum`, avoiding a GPU CIRAWFilter demosaic while the camera is active.
    static func embeddedThumbnail(
        _ source: CGImageSource, description: Description, maximum: Int
    ) -> CGImage? {
        guard description.isRAW,
            let thumb = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: maximum,
                ] as CFDictionary)
        else { return nil }
        let minRequired = min(maximum, max(description.width, description.height))
        guard max(thumb.width, thumb.height) >= minRequired else { return nil }
        let thumbAspect = Double(thumb.width) / Double(max(thumb.height, 1))
        let fullAspect = Double(description.width) / Double(max(description.height, 1))
        guard abs(thumbAspect - fullAspect) / max(fullAspect, 1e-4) < 0.025 else { return nil }
        return thumb
    }

    static func preview(_ data: Data, description: Description, maximum: Int) -> CGImage? {
        guard let image = developedImage(data, description: description, maximum: maximum) else {
            return nil
        }
        return previewContext.createCGImage(
            image, from: image.extent, format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }

    static func preview(_ image: CGImage, maximum: Int) -> CGImage? {
        guard max(image.width, image.height) > maximum else { return image }
        let resized = resized(CIImage(cgImage: image), maximum: maximum)
        return previewContext.createCGImage(
            resized, from: resized.extent, format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }

    static func captureProperties(_ source: CGImageSource, data: Data) -> [CFString: Any] {
        var properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        // ImageIO omits these EXIF 2.31 tags from some genuine ProRAW DNGs.
        // Read only the three bounded ASCII fields; leave pixel decoding to Apple.
        for (key, value) in tiffTimeOffsets(data) where exif[key] == nil { exif[key] = value }
        if !exif.isEmpty { properties[kCGImagePropertyExifDictionary] = exif }
        return properties
    }

    static func tiffTimeOffsets(_ data: Data) -> [CFString: String] {
        data.withUnsafeBytes { bytes in
            guard bytes.count >= 8 else { return [:] }
            let little = bytes[0] == 0x49 && bytes[1] == 0x49
            guard little || (bytes[0] == 0x4d && bytes[1] == 0x4d) else { return [:] }
            func number(_ offset: Int, _ length: Int) -> Int? {
                guard offset >= 0, offset <= bytes.count - length else { return nil }
                return (0..<length).reduce(0) { value, index in
                    let shift = (little ? index : length - 1 - index) * 8
                    return value | (Int(bytes[offset + index]) << shift)
                }
            }
            func entries(_ offset: Int) -> [Int] {
                guard offset >= 8, let count = number(offset, 2),
                    count <= (bytes.count - offset - 2) / 12
                else { return [] }
                return (0..<count).map { offset + 2 + $0 * 12 }
            }
            guard number(2, 2) == 42, let first = number(4, 4),
                let pointer = entries(first).first(where: {
                    number($0, 2) == 34665 && number($0 + 2, 2) == 4
                        && number($0 + 4, 4) == 1
                }), let exif = number(pointer + 8, 4)
            else { return [:] }
            let keys: [Int: CFString] = [
                36880: kCGImagePropertyExifOffsetTime,
                36881: kCGImagePropertyExifOffsetTimeOriginal,
                36882: kCGImagePropertyExifOffsetTimeDigitized,
            ]
            var result: [CFString: String] = [:]
            for entry in entries(exif) {
                guard let tag = number(entry, 2), let key = keys[tag],
                    number(entry + 2, 2) == 2, number(entry + 4, 4) == 7,
                    let offset = number(entry + 8, 4), offset <= bytes.count - 7,
                    bytes[offset + 6] == 0,
                    let value = String(bytes: bytes[offset..<(offset + 6)], encoding: .ascii),
                    value.range(of: #"^[+-](0[0-9]|1[0-4]):[0-5][0-9]$"#,
                                options: .regularExpression) != nil
                else { continue }
                result[key] = value
            }
            return result
        }
    }

    /// Copy capture facts only. Pixel-dependent RAW, HDR and thumbnail tags cannot describe a new SDR render.
    static func exportProperties(_ data: Data, typeHint: String?) -> [CFString: Any] {
        guard let source = imageSource(data, typeHint: typeHint) else { return [:] }
        let p = captureProperties(source, data: data)
        var result: [CFString: Any] = [:]
        if let gps = p[kCGImagePropertyGPSDictionary] as? [CFString: Any],
            let lat = gps[kCGImagePropertyGPSLatitude] as? Double,
            let lon = gps[kCGImagePropertyGPSLongitude] as? Double,
            lat.isFinite, lon.isFinite, (0...90).contains(lat), (0...180).contains(lon),
            ["N", "S"].contains(gps[kCGImagePropertyGPSLatitudeRef] as? String ?? ""),
            ["E", "W"].contains(gps[kCGImagePropertyGPSLongitudeRef] as? String ?? "")
        {
            result[kCGImagePropertyGPSDictionary] = gps
        }
        if let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            let keys = [
                kCGImagePropertyExifDateTimeOriginal, kCGImagePropertyExifDateTimeDigitized,
                kCGImagePropertyExifOffsetTime,
                kCGImagePropertyExifOffsetTimeOriginal, kCGImagePropertyExifOffsetTimeDigitized,
                kCGImagePropertyExifSubsecTimeOriginal, kCGImagePropertyExifExposureTime,
                kCGImagePropertyExifFNumber, kCGImagePropertyExifISOSpeedRatings,
                kCGImagePropertyExifFocalLength, kCGImagePropertyExifLensModel,
                kCGImagePropertyExifLensMake,
            ]
            var capture = exif.filter { keys.contains($0.key) }
            capture[kCGImagePropertyExifColorSpace] = 1
            result[kCGImagePropertyExifDictionary] = capture
        }
        if let tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            let keys = [
                kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel,
                kCGImagePropertyTIFFDateTime, kCGImagePropertyTIFFArtist,
                kCGImagePropertyTIFFCopyright,
            ]
            result[kCGImagePropertyTIFFDictionary] = tiff.filter { keys.contains($0.key) }
        }
        return result
    }
}

/// Advisory admission control, shared by edited and untouched image exports.
nonisolated enum ImageMemoryAllowance {
    struct Failure: LocalizedError {
        var estimated: UInt64? = nil
        var available: UInt64? = nil
        var errorDescription: String? {
            String(
                localized: "export.memory_limit",
                defaultValue:
                    "This image needs more memory than is currently available. Choose a smaller export size and try again."
            )
        }
    }
    static var available: UInt64 {
        #if os(iOS) && !targetEnvironment(simulator)
            return UInt64(os_proc_available_memory()) * 4 / 5
        #else
            return min(ProcessInfo.processInfo.physicalMemory / 3, 8 * 1024 * 1024 * 1024)
        #endif
    }
    static func check(estimate: UInt64, allowance: UInt64? = nil) throws {
        let available = allowance ?? self.available
        guard estimate < available else { throw Failure(estimated: estimate, available: available) }
    }
}
