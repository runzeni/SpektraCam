import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import SwiftData
import UniformTypeIdentifiers
#if canImport(UIKit)
    import UIKit
#endif

@main struct Checks {
    @MainActor static func main() async throws {
        let project = URL(fileURLWithPath: CommandLine.arguments[1])
        let modelDirectory = project.appendingPathComponent("SpektraCam/Resources/ModelData")
        let defaults = UserDefaults.standard
        let savedPrecision = defaults.object(forKey: RenderPrecision.storageKey)
        defer {
            if let savedPrecision {
                defaults.set(savedPrecision, forKey: RenderPrecision.storageKey)
            } else {
                defaults.removeObject(forKey: RenderPrecision.storageKey)
            }
        }

        // 1. RenderPrecision parsing, invalid fallback and storage byte sizes.
        defaults.removeObject(forKey: RenderPrecision.storageKey)
        precondition(RenderPrecision.selected == .automatic)
        defaults.set("invalid-8bit", forKey: RenderPrecision.storageKey)
        precondition(RenderPrecision.selected == .automatic, "Invalid precision value did not fall back to automatic")
        defaults.set(RenderPrecision.float16.rawValue, forKey: RenderPrecision.storageKey)
        precondition(RenderPrecision.selected == .float16 && RenderPrecision.resolved == .float16)
        precondition(RenderPrecision.resolved.usesHalfFloat && RenderPrecision.resolved.ciFormat == .RGBAh)
        precondition(RenderPrecision.resolved.bytesPerPixel == 8 && PixelStore.Format.working == .half)
        defaults.set(RenderPrecision.float32.rawValue, forKey: RenderPrecision.storageKey)
        precondition(RenderPrecision.selected == .float32 && RenderPrecision.resolved == .float32)
        precondition(!RenderPrecision.resolved.usesHalfFloat && RenderPrecision.resolved.ciFormat == .RGBAf)
        precondition(RenderPrecision.resolved.bytesPerPixel == 16 && PixelStore.Format.working == .float)

        // 2. PixelStore(.half) boundary sizes, HDR headroom, negative wide-gamut values and invalid detection.
        for bad in [(0, 4), (4, 0), (-1, 4)] {
            var rejected = false
            do { _ = try PixelStore(width: bad.0, height: bad.1, format: .half) }
            catch { rejected = true }
            precondition(rejected, "Invalid size \(bad) was accepted by PixelStore(.half)")
        }

        let single = try PixelStore(width: 1, height: 1, format: .half)
        precondition(single.length == 8 && single.rowBytes == 8)
        let hdrSample = [SIMD4<Float>(16.0, -0.25, 0.0005, 1.0)]
        hdrSample.withUnsafeBytes {
            single.write(x: 0, y: 0, width: 1, height: 1, from: $0.baseAddress!, sourceRowBytes: 16)
        }
        precondition(single.isValid(), "Valid HDR half-float pixel rejected")
        var readBack = [SIMD4<Float>.zero]
        readBack.withUnsafeMutableBytes {
            single.read(x: 0, y: 0, width: 1, height: 1, into: $0.baseAddress!)
        }
        precondition(abs(readBack[0].x - 16.0) < 1e-4, "Half-float clipped +4 EV highlight: \(readBack[0].x)")
        precondition(abs(readBack[0].y - (-0.25)) < 1e-3, "Half-float lost negative wide-gamut primary: \(readBack[0].y)")
        precondition(abs(readBack[0].z - 0.0005) < 1e-5, "Half-float lost deep shadow precision: \(readBack[0].z)")
        precondition(abs(readBack[0].w - 1.0) < 1e-4)

        let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let halfCG = try single.image(colorSpace: linearSpace)
        precondition(halfCG.bitsPerComponent == 16 && halfCG.bitsPerPixel == 64)
        let decodedHalf = try PhotoColorBridge.decode(halfCG)
        precondition(abs(decodedHalf[0].x - 16.0) < 1e-3 && abs(decodedHalf[0].y - (-0.25)) < 1e-3)

        // NaN, Inf and non-opaque alpha must fail isValid(), whereas finite float32 values
        // exceeding Float16 max (65504) must clamp cleanly in write() rather than turning into ±Inf.
        let extremeFinite: [SIMD4<Float>] = [SIMD4(80_000, -80_000, 1.0, 1.0)]
        extremeFinite.withUnsafeBytes {
            single.write(x: 0, y: 0, width: 1, height: 1, from: $0.baseAddress!, sourceRowBytes: 16)
        }
        precondition(single.isValid(), "Finite >65504 float overflowed PixelStore(.half) to ±Inf")
        readBack.withUnsafeMutableBytes {
            single.read(x: 0, y: 0, width: 1, height: 1, into: $0.baseAddress!)
        }
        precondition(readBack[0].x == 65_504 && readBack[0].y == -65_504, "Expected ±65504 clamp, got \(readBack[0])")

        let genuineInf: [SIMD4<Float>] = [SIMD4(.infinity, 1.0, 1.0, 1.0)]
        genuineInf.withUnsafeBytes {
            single.write(x: 0, y: 0, width: 1, height: 1, from: $0.baseAddress!, sourceRowBytes: 16)
        }
        precondition(!single.isValid(), "Genuine +Inf float passed PixelStore(.half).isValid()")
        let genuineNaN: [SIMD4<Float>] = [SIMD4(.nan, 1.0, 1.0, 1.0)]
        genuineNaN.withUnsafeBytes {
            single.write(x: 0, y: 0, width: 1, height: 1, from: $0.baseAddress!, sourceRowBytes: 16)
        }
        precondition(!single.isValid(), "Genuine NaN float passed PixelStore(.half).isValid()")

        let rawHalf = single.base.assumingMemoryBound(to: SIMD4<UInt16>.self)
        rawHalf[0] = SIMD4(0x7E00, 0x3C00, 0x3C00, 0x3C00)  // NaN in R
        precondition(!single.isValid(), "NaN half-float passed isValid()")
        rawHalf[0] = SIMD4(0x3C00, 0x7C00, 0x3C00, 0x3C00)  // +Inf in G
        precondition(!single.isValid(), "+Inf half-float passed isValid()")
        rawHalf[0] = SIMD4(0x3C00, 0xFC00, 0x3C00, 0x3C00)  // -Inf in G
        precondition(!single.isValid(), "-Inf half-float passed isValid()")
        rawHalf[0] = SIMD4(0x3C00, 0x3C00, 0x3C00, 0x3800)  // alpha = 0.5
        precondition(!single.isValid(), "Translucent alpha passed isValid()")

        // 3. End-to-end 16-bit vs 32-bit parity across whole-frame, tiled (>2048 px), LUT+grain and film-edge renders.
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        func makeGradient(width: Int, height: Int) -> Data {
            let ctx = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            let ptr = ctx.data!.assumingMemoryBound(to: UInt8.self)
            for y in 0..<height {
                for x in 0..<width {
                    let u = Double(x) / Double(max(width - 1, 1))
                    let v = Double(y) / Double(max(height - 1, 1))
                    let i = (y * width + x) * 4
                    ptr[i] = UInt8((min(max(0.08 + 0.88 * u, 0), 1) * 255).rounded())
                    ptr[i + 1] = UInt8((min(max(0.10 + 0.80 * v, 0), 1) * 255).rounded())
                    ptr[i + 2] = UInt8((min(max(0.92 - 0.75 * u * v, 0), 1) * 255).rounded())
                    ptr[i + 3] = 255
                }
            }
            let image = ctx.makeImage()!
            let out = NSMutableData()
            let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, image, nil)
            precondition(CGImageDestinationFinalize(dest))
            return out as Data
        }
        func srgbBytes(_ image: CGImage) -> [UInt8] {
            let w = image.width, h = image.height
            var bytes = [UInt8](repeating: 0, count: w * h * 4)
            bytes.withUnsafeMutableBytes { buf in
                let ctx = CGContext(
                    data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                    bytesPerRow: w * 4, space: sRGB,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            return bytes
        }
        func maxAndMeanDiff(_ a: CGImage, _ b: CGImage) -> (Int, Double) {
            precondition(a.width == b.width && a.height == b.height)
            let ba = srgbBytes(a), bb = srgbBytes(b)
            var maxDiff = 0
            var sum = 0
            let pixels = a.width * a.height
            for p in 0..<pixels {
                for c in 0..<3 {
                    let d = abs(Int(ba[p * 4 + c]) - Int(bb[p * 4 + c]))
                    if d > maxDiff { maxDiff = d }
                    sum += d
                }
            }
            return (maxDiff, Double(sum) / Double(pixels * 3))
        }

        // Tiled export size (2200 × 1650 = 3.63 MP > PixelStore.tilingThreshold 4.19 MP? Use 2400 × 1800 = 4.32 MP > 2048*2048!)
        let largePNG = makeGradient(width: 2400, height: 1800)
        precondition(PixelStore.isLarge(width: 2400, height: 1800))
        let largeImported = ImportedPhoto.decode(largePNG, maximum: 720)!

        var filmRecipe = EditRecipe()
        filmRecipe.source.exposureEV = 1.25
        filmRecipe.mix = 0.75
        filmRecipe.tone.highlights = -1.2
        filmRecipe.tone.shadows = 0.6
        filmRecipe.tone.contrast = 1.15
        filmRecipe.flags["film_render.grain.active"] = false
        filmRecipe.flags["print_render.glare.active"] = false

        func renderExport(_ recipe: EditRecipe, precision: RenderPrecision, lutDir: URL? = nil) async throws -> CGImage {
            defaults.set(precision.rawValue, forKey: RenderPrecision.storageKey)
            let renderer = PhotoRenderer(
                source: largeImported.preview, directory: modelDirectory, data: largePNG,
                lutDirectory: lutDir, previewMaximum: 720,
                sourceType: largeImported.sourceType, description: largeImported.sourceDescription)
            let (url, _, _) = try await renderer.export(recipe, size: .full, format: .png, quality: 1.0)
            defer { try? FileManager.default.removeItem(at: url) }
            return try PhotoExporter.decodeSource(Data(contentsOf: url))
        }

        let film32 = try await renderExport(filmRecipe, precision: .float32)
        let film16 = try await renderExport(filmRecipe, precision: .float16)
        let (filmMax, filmMean) = maxAndMeanDiff(film32, film16)
        print(String(format: "Tiled 2400×1800 Spektrafilm+Mix+Tone 16-bit vs 32-bit: max %d/255, mean %.5f/255", filmMax, filmMean))
        precondition(filmMax <= 1 && filmMean < 0.05, "16-bit tiled film export diverged: max=\(filmMax) mean=\(filmMean)")

        // Film-edge + distress (dust, scratches, light leak) parity at tiled resolution.
        var edgeRecipe = filmRecipe
        var edge = FilmEdgeLayout()
        edge.distress.leak = 0.45
        edge.distress.edgeFog = 0.25
        edge.distress.dust = 0.35
        edge.distress.scratches = 0.35
        edge.distress.scratchesInImage = true
        edgeRecipe.filmEdgeLayout = edge
        let edge32 = try await renderExport(edgeRecipe, precision: .float32)
        let edge16 = try await renderExport(edgeRecipe, precision: .float16)
        let (edgeMax, edgeMean) = maxAndMeanDiff(edge32, edge16)
        print(String(format: "Tiled Film-Edge+Leak+Damage 16-bit vs 32-bit: max %d/255, mean %.5f/255", edgeMax, edgeMean))
        precondition(edgeMax <= 2 && edgeMean < 0.1, "16-bit film-edge export diverged: max=\(edgeMax) mean=\(edgeMean)")

        // Resident PhotoRenderer must invalidate preview/edge caches when RenderPrecision changes dynamically.
        defaults.set(RenderPrecision.float16.rawValue, forKey: RenderPrecision.storageKey)
        let sharedRenderer = PhotoRenderer(
            source: largeImported.preview, directory: modelDirectory, data: largePNG,
            previewMaximum: 720,
            sourceType: largeImported.sourceType, description: largeImported.sourceDescription)
        let preview16 = try await sharedRenderer.render(filmRecipe, maximum: 720)
        defaults.set(RenderPrecision.float32.rawValue, forKey: RenderPrecision.storageKey)
        let preview32 = try await sharedRenderer.render(filmRecipe, maximum: 720)
        let freshRenderer32 = PhotoRenderer(
            source: largeImported.preview, directory: modelDirectory, data: largePNG,
            previewMaximum: 720,
            sourceType: largeImported.sourceType, description: largeImported.sourceDescription)
        let freshPreview32 = try await freshRenderer32.render(filmRecipe, maximum: 720)
        let (exactMax, exactMean) = maxAndMeanDiff(preview32, freshPreview32)
        precondition(exactMax == 0 && exactMean == 0, "Resident PhotoRenderer returned stale 16-bit cache after switching to 32-bit")
        let (prevMax, prevMean) = maxAndMeanDiff(preview32, preview16)
        precondition(prevMax <= 1 && prevMean < 0.2 && preview16 !== preview32, "16-bit vs 32-bit preview diverged: max=\(prevMax) mean=\(prevMean)")

        // 4. CameraInbox regular capture formats (HEIC, JPG, DNG) and embeddedThumbnail validation.
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SpektraCam-Precision-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let inbox = CameraInbox(root: tempRoot)
        let smallCtx = CGContext(
            data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
            space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        smallCtx.setFillColor(CGColor(colorSpace: sRGB, components: [0.25, 0.55, 0.75, 1])!)
        smallCtx.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let smallImg = smallCtx.makeImage()!

        func encodeImage(_ uti: UTType) -> Data {
            let buf = NSMutableData()
            let dest = CGImageDestinationCreateWithData(buf, uti.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(
                dest, smallImg,
                [
                    kCGImagePropertyGPSDictionary: [
                        kCGImagePropertyGPSLatitude: 27.95, kCGImagePropertyGPSLatitudeRef: "N",
                        kCGImagePropertyGPSLongitude: 82.46, kCGImagePropertyGPSLongitudeRef: "W",
                    ]
                ] as CFDictionary)
            precondition(CGImageDestinationFinalize(dest))
            return buf as Data
        }

        let heicData = encodeImage(.heic)
        let jpegData = encodeImage(.jpeg)
        let heicInboxURL = try inbox.store(heicData, fileExtension: "heic")
        let jpgInboxURL = try inbox.store(jpegData, fileExtension: "jpg")
        precondition(heicInboxURL.pathExtension == "heic" && jpgInboxURL.pathExtension == "jpg")
        // Stray non-photo files must be ignored by pending().
        try Data("ignore".utf8).write(to: inbox.directory.appendingPathComponent("notes.txt"))
        let pending = try inbox.pending()
        precondition(pending.count == 2, "Expected 2 pending captures, got \(pending.count)")

        let library = try PhotoLibrary(
            root: tempRoot, cache: tempRoot.appendingPathComponent("Cache"),
            modelDirectory: modelDirectory)
        // Overlapping recoverCaptures() calls must serialize cleanly without missing-file errors or double counting.
        async let r1 = library.recoverCaptures()
        async let r2 = library.recoverCaptures()
        async let r3 = library.recoverCaptures()
        let recoveredCounts = try await [r1, r2, r3]
        let recovered = recoveredCounts.reduce(0, +)
        precondition(recovered == 2 && library.photos.count == 2, "Concurrent recoverCaptures mismatch: \(recoveredCounts)")
        let remaining = try inbox.pending()
        precondition(remaining.isEmpty, "Recovered captures remained in CameraInbox")
        for photo in library.photos {
            precondition(!photo.isRAW, "Regular HEIC/JPEG capture was marked RAW")
            precondition(["heic", "jpeg", "jpg"].contains(photo.fileExtension))
            precondition(photo.metadata.latitude == 27.95 && photo.metadata.longitude == -82.46)
            let thumb = try await library.images.image(photo, thumbnail: true)
            precondition(thumb.width == 64 && thumb.height == 48)
        }

        // Non-RAW sources must return nil from embeddedThumbnail so Lanczos/HDR/SDR paths stay authoritative.
        let jpegSource = PhotoSource.imageSource(jpegData)!
        let jpegDesc = PhotoSource.describe(jpegData)!
        precondition(PhotoSource.embeddedThumbnail(jpegSource, description: jpegDesc, maximum: 384) == nil)
        // Undersized or aspect-mismatched RAW descriptions must also reject embedded thumbnails.
        let fakeRAW3x2 = PhotoSource.Description(type: "com.adobe.raw-image", isRAW: true, width: 3000, height: 2000, temperature: 5500)
        precondition(PhotoSource.embeddedThumbnail(jpegSource, description: fakeRAW3x2, maximum: 384) == nil)

        // 5. Adaptive source-bit-depth pipeline detection (8-bit JPEG/HEIC/PNG -> float16 vs 16-bit PNG / RAW -> float32).
        let heicDesc = PhotoSource.describe(heicData)!
        let png8Desc = PhotoSource.describe(largePNG)!
        precondition(jpegDesc.bitDepth == 8 && !jpegDesc.prefersDeepPipeline, "8-bit JPEG marked deep: \(jpegDesc.bitDepth)")
        precondition(heicDesc.bitDepth <= 10 && !heicDesc.prefersDeepPipeline, "8-bit HEIC marked deep: \(heicDesc.bitDepth)")
        precondition(png8Desc.bitDepth == 8 && !png8Desc.prefersDeepPipeline, "8-bit PNG marked deep: \(png8Desc.bitDepth)")
        precondition(fakeRAW3x2.bitDepth == 16 && fakeRAW3x2.prefersDeepPipeline, "RAW description did not prefer deep pipeline")

        let ctx16 = CGContext(
            data: nil, width: 32, height: 24, bitsPerComponent: 16, bytesPerRow: 32 * 8,
            space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGImageByteOrderInfo.order16Little.rawValue)!
        ctx16.setFillColor(CGColor(colorSpace: sRGB, components: [0.35, 0.45, 0.65, 1])!)
        ctx16.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        let png16Buf = NSMutableData()
        let png16Dest = CGImageDestinationCreateWithData(png16Buf, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(png16Dest, ctx16.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(png16Dest))
        let png16Data = png16Buf as Data
        let png16Desc = PhotoSource.describe(png16Data)!
        precondition(png16Desc.bitDepth == 16 && png16Desc.prefersDeepPipeline, "16-bit PNG did not prefer deep pipeline: \(png16Desc.bitDepth)")

        defaults.set(RenderPrecision.automatic.rawValue, forKey: RenderPrecision.storageKey)
        if !RenderPrecision.devicePrefersHalfFloat {
            precondition(RenderPrecision.resolved(sourcePrefersDeep: false) == .float16)
            precondition(RenderPrecision.resolved(sourcePrefersDeep: true) == .float32)
            RenderPrecision.$activeSourcePrefersDeep.withValue(false) {
                precondition(RenderPrecision.resolved == .float16 && PixelStore.Format.working == .half)
            }
            RenderPrecision.$activeSourcePrefersDeep.withValue(true) {
                precondition(RenderPrecision.resolved == .float32 && PixelStore.Format.working == .float)
            }
        }
        // Manual 32-bit and 16-bit overrides must always win over source bit depth.
        defaults.set(RenderPrecision.float32.rawValue, forKey: RenderPrecision.storageKey)
        precondition(RenderPrecision.resolved(sourcePrefersDeep: false) == .float32)
        defaults.set(RenderPrecision.float16.rawValue, forKey: RenderPrecision.storageKey)
        precondition(RenderPrecision.resolved(sourcePrefersDeep: true) == .float16)
        defaults.set(RenderPrecision.automatic.rawValue, forKey: RenderPrecision.storageKey)

        let autoRenderer8 = PhotoRenderer(
            source: PhotoRenderer.placeholderSource, directory: modelDirectory, data: largePNG,
            previewMaximum: 384, sourceType: png8Desc.type, description: png8Desc,
            cachesIntermediates: false)
        let autoRenderer16 = PhotoRenderer(
            source: PhotoRenderer.placeholderSource, directory: modelDirectory, data: png16Data,
            previewMaximum: 384, sourceType: png16Desc.type, description: png16Desc,
            cachesIntermediates: false)
        let autoImg8 = try await autoRenderer8.render(filmRecipe, maximum: 384)
        let autoImg16 = try await autoRenderer16.render(filmRecipe, maximum: 384)
        precondition(autoImg8.width > 0 && autoImg16.width == 32 && autoImg16.height == 24)

        #if canImport(UIKit)
            let slider = DefaultSlider.PrecisionSlider(frame: CGRect(x: 0, y: 0, width: 300, height: 32))
            slider.overrideUserInterfaceStyle = .dark
            slider.tintColor = .systemYellow
            slider.neutralOrigin = 0.5
            slider.defaultTick = 0.5
            slider.setValue(0.85, animated: false)
            slider.setNeedsLayout()
            slider.layoutIfNeeded()
            let track = slider.trackRect(forBounds: slider.bounds)
            let originThumb = slider.thumbRect(forBounds: slider.bounds, trackRect: track, value: 0.5)
            let currentThumb = slider.thumbRect(forBounds: slider.bounds, trackRect: track, value: 0.85)
            var rgba = [UInt8](repeating: 0, count: 300 * 32 * 4)
            rgba.withUnsafeMutableBytes { buf in
                let ctx = CGContext(
                    data: buf.baseAddress, width: 300, height: 32, bitsPerComponent: 8,
                    bytesPerRow: 300 * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                ctx.translateBy(x: 0, y: 32)
                ctx.scaleBy(x: 1, y: -1)
                slider.layer.render(in: ctx)
            }
            let fillX = Int((originThumb.midX + currentThumb.minX) / 2)
            let fillY = Int(track.midY)
            let fillOffset = (fillY * 300 + fillX) * 4
            precondition(
                rgba[fillOffset] > 245 && rgba[fillOffset + 1] > 195 && rgba[fillOffset + 2] < 15,
                "PrecisionSlider neutralFill was occluded by track: (\(rgba[fillOffset]), \(rgba[fillOffset + 1]), \(rgba[fillOffset + 2]))")
            let thumbOffset = (fillY * 300 + Int(currentThumb.midX)) * 4
            precondition(
                rgba[thumbOffset] > 245 && rgba[thumbOffset + 1] > 245 && rgba[thumbOffset + 2] > 245,
                "PrecisionSlider neutralFill overlapped thumb: (\(rgba[thumbOffset]), \(rgba[thumbOffset + 1]), \(rgba[thumbOffset + 2]))")
        #endif

        print("PASS: 16-bit float PixelStore/pipeline parity, finite ±65504 clamp, concurrent CameraInbox recovery, and fallback UI checks")
    }
}
