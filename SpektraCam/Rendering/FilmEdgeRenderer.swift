import Accelerate
import CoreGraphics
import CoreImage
import Foundation
import simd

/// Shared by editor previews and every export caller. The paper/table never enter this stage.
nonisolated enum FilmEdgeRenderer {
    private static let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private static let contextLock = NSLock()
    private nonisolated(unsafe) static var _context32: CIContext?
    private nonisolated(unsafe) static var _context16: CIContext?
    private static var context: CIContext {
        let halfFloat = RenderPrecision.resolved.usesHalfFloat
        contextLock.lock()
        defer { contextLock.unlock() }
        if halfFloat {
            if let existing = _context16 { return existing }
            let created = CIContext(options: [
                .workingColorSpace: linear, .workingFormat: CIFormat.RGBAf,
                .cacheIntermediates: false,
            ])
            _context16 = created
            return created
        } else {
            if let existing = _context32 { return existing }
            let created = CIContext(options: [
                .workingColorSpace: linear, .workingFormat: CIFormat.RGBAf,
                .cacheIntermediates: false,
            ])
            _context32 = created
            return created
        }
    }
    static var initializedContextCountForTesting: Int {
        contextLock.lock()
        defer { contextLock.unlock() }
        return (_context16 != nil ? 1 : 0) + (_context32 != nil ? 1 : 0)
    }
    static func clearCaches() {
        contextLock.lock()
        let c16 = _context16
        let c32 = _context32
        contextLock.unlock()
        c16?.clearCaches()
        c32?.clearCaches()
    }

    @inline(__always) private static func halfToFloat(_ h: UInt16) -> Float {
        let sign = UInt32(h & 0x8000) << 16
        let exp = UInt32((h >> 10) & 0x1F)
        let mant = UInt32(h & 0x03FF)
        if exp == 0 {
            if mant == 0 { return Float(bitPattern: sign) }
            let v = Float(mant) * 0x1p-24
            return sign == 0 ? v : -v
        }
        if exp == 31 {
            return Float(bitPattern: sign | 0x7F80_0000 | (mant << 13))
        }
        return Float(bitPattern: sign | ((exp + 112) << 23) | (mant << 13))
    }

    @inline(__always) private static func halfPixel(_ p: SIMD4<UInt16>) -> SIMD4<Float> {
        SIMD4(halfToFloat(p.x), halfToFloat(p.y), halfToFloat(p.z), halfToFloat(p.w))
    }

    /// Covered paper is the output reference white, independent of scanner glare, LUTs and
    /// grading. Keep the exposure-space blade simulation; anchor its covered side after tone
    /// through the very same seeded penumbra, rather than painting a rectangular white frame.
    /// Only the perimeter is evaluated, and the RGBA8 output uses bounded file-backed storage.
    static func restoringPaper(_ image: CGImage, geometry: FilmEdgeGeometry,
                               origin: (x: Int, y: Int) = (0, 0)) throws -> CGImage {
        guard geometry.distress.enlargerPrint else { return image }
        let w = image.width, h = image.height
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let store = try PixelStore.render(PixelStore.ciImage(image), width: w, height: h,
                                         context: context, colorSpace: space, format: .byte)
        let out = store.base.assumingMemoryBound(to: UInt8.self)
        let mm = geometry.millimetersPerPixel
        let half = geometry.carrierHalf
        let hx = geometry.portrait ? half.across : half.along
        let hy = geometry.portrait ? half.along : half.across
        let pad = max(geometry.distress.carrierBlur, geometry.pixelRadius)
            + 1.6 * geometry.distress.carrierRoughness + geometry.distress.carrierCorner
        let left = Int(ceil(Double(geometry.width) / 2 + (geometry.easelOffset.x - hx + pad) / mm)) - origin.x
        let right = Int(floor(Double(geometry.width) / 2 + (geometry.easelOffset.x + hx - pad) / mm)) - origin.x
        let top = Int(ceil(Double(geometry.height) / 2 + (geometry.easelOffset.y - hy + pad) / mm)) - origin.y
        let bottom = Int(floor(Double(geometry.height) / 2 + (geometry.easelOffset.y + hy - pad) / mm)) - origin.y
        let firstEnd = min(max(left, 0), w)
        let secondStart = min(max(right, firstEnd), w)
        func shade(_ x: Int, _ y: Int) {
            let coverage = geometry.carrierCoverage(x: origin.x + x, y: origin.y + y)
            guard coverage < 1 else { return }
            let i = (y * w + x) * 4
            for channel in 0..<3 {
                out[i + channel] = UInt8((255 - (255 - Double(out[i + channel])) * coverage).rounded())
            }
            out[i + 3] = 255
        }
        for y in 0..<h {
            if y % 64 == 0 { try Task.checkCancellation() }
            if y < top || y >= bottom {
                for x in 0..<w { shade(x, y) }
            } else {
                for x in 0..<firstEnd { shade(x, y) }
                for x in secondStart..<w { shade(x, y) }
            }
        }
        return try store.image(colorSpace: space)
    }

    /// Manual families use compatible material defaults only for the edge. Develop is preserved.
    static func materialRecipe(_ original: EditRecipe) -> EditRecipe {
        var recipe = original
        recipe.tone.monochrome = false
        recipe.look.enabled = true
        recipe.look.mode = .spektrafilm
        recipe.mix = 1
        let positive = FilmStock.films.first { $0.id == recipe.filmID }?.isPositive == true
        let cinema = FilmStock.prints.first { $0.id == recipe.printID }?.support == "film"
        switch original.resolvedFilmEdgeType {
        // An inverted scan makes the same positive as a print; only the frame around it differs.
        case .negativePrint, .invertedScan:
            if positive { recipe.filmID = "fujifilm_c200" }
            if cinema { recipe.printID = "fujifilm_crystal_archive_typeii" }
            recipe.scanFilm = false
        case .negativeScan:
            if positive { recipe.filmID = "fujifilm_c200" }
            recipe.scanFilm = true
        case .reversalScan:
            if !positive { recipe.filmID = "fujifilm_provia_100f" }
            recipe.scanFilm = true
        case .cinemaPrint:
            if positive { recipe.filmID = "fujifilm_c200" }
            if !cinema { recipe.printID = "kodak_2383" }
            recipe.scanFilm = false
        }
        return recipe
    }

    /// Extend the scene at the boundary for lens convolution, then gate it in exposure space.
    /// It does not claim to recover the original scene outside an imported photograph.
    /// The scene is sampled in film coordinates, so a tilted strip carries its picture with it.
    /// A full-size canvas is written to file-backed storage and rendered in tiles.
    /// `region` limits the result to a rectangle of the canvas (for the loupe), always in a store.
    static func padded(
        _ input: SourceImageRenderer.Input, geometry: FilmEdgeGeometry,
        region: (x: Int, y: Int, w: Int, h: Int)? = nil
    ) throws -> SourceImageRenderer.Input {
        let width = region?.w ?? geometry.width, height = region?.h ?? geometry.height
        let left = Double(region?.x ?? 0), top = Double(region?.y ?? 0)
        let store = region != nil || PixelStore.isLarge(width: width, height: height)
            ? try PixelStore(width: width, height: height, format: .working) : nil
        var pixels = Array(repeating: SIMD4<Float>.zero, count: store == nil ? width * height : 0)
        let bands = max(1, min(height / 32, ProcessInfo.processInfo.activeProcessorCount * 4))
        let inStore = input.store
        let halfSource = inStore?.format == .half
        let supX = geometry.supportHalf.x
        let supY = geometry.supportHalf.y
        nonisolated(unsafe) let rawSource = inStore?.base
        return try input.pixels.withUnsafeBufferPointer { arrayBuffer in
            nonisolated(unsafe) let arrayPtr = arrayBuffer.baseAddress
            @inline(__always) func sample(_ index: Int) -> SIMD4<Float> {
                if let rawSource {
                    if halfSource {
                        return halfPixel(rawSource.assumingMemoryBound(to: SIMD4<UInt16>.self)[index])
                    }
                    return rawSource.assumingMemoryBound(to: SIMD4<Float>.self)[index]
                }
                return arrayPtr![index]
            }
            @inline(__always) func computeRow(_ y: Int, into rowPtr: UnsafeMutablePointer<SIMD4<Float>>) {
                for x in 0..<width {
                    let (fx, fy) = geometry.film(left + Double(x) + 0.5, top + Double(y) + 0.5)
                    let sx = min(max((fx + supX) / (2 * supX) * Double(input.width) - 0.5, 0), Double(input.width - 1))
                    let sy = min(max((fy + supY) / (2 * supY) * Double(input.height) - 0.5, 0), Double(input.height - 1))
                    let x0 = Int(sx), x1 = min(x0 + 1, input.width - 1), fx0 = Float(sx - Double(x0))
                    let y0 = Int(sy), y1 = min(y0 + 1, input.height - 1), fy0 = Float(sy - Double(y0))
                    let a = sample(y0 * input.width + x0) * (1 - fx0) + sample(y0 * input.width + x1) * fx0
                    let b = sample(y1 * input.width + x0) * (1 - fx0) + sample(y1 * input.width + x1) * fx0
                    rowPtr[x] = a * (1 - fy0) + b * fy0
                }
            }
            if let store {
                DispatchQueue.concurrentPerform(iterations: bands) { band in
                    var row = [SIMD4<Float>](repeating: .zero, count: width)
                    row.withUnsafeMutableBufferPointer { buf in
                        for y in (band * height / bands)..<((band + 1) * height / bands) {
                            computeRow(y, into: buf.baseAddress!)
                            store.write(x: 0, y: y, width: width, height: 1, from: buf.baseAddress!, sourceRowBytes: width * 16)
                        }
                    }
                }
            } else {
                pixels.withUnsafeMutableBufferPointer { target in
                    nonisolated(unsafe) let out = target.baseAddress!
                    DispatchQueue.concurrentPerform(iterations: bands) { band in
                        for y in (band * height / bands)..<((band + 1) * height / bands) {
                            computeRow(y, into: out.advanced(by: y * width))
                        }
                    }
                }
            }
            try Task.checkCancellation()
            return .init(pixels: pixels, width: width, height: height, store: store)
        }
    }

    /// Creative cross-family / LUT / partial-Mix choices keep the developed center untouched.
    /// Matched Auto uses the single full-support graph and does not need this composition.
    /// The centre follows the strip's tilt and is blended through the same soft, worn gate.
    /// Dust and crossing scratches are then laid over the centre with the polarity of the chosen
    /// route; rebate-only scratches stay in the material render. Leaks and fog are exposure, so
    /// they enter the centre before its look (`exposeCenter`).
    static func replacingCenter(_ edge: CGImage, with center: CGImage, geometry: FilmEdgeGeometry,
                                paperPrint: Bool = true,
                                coverage: (values: [Float], mask: CIImage)? = nil,
                                finished: Bool = false) throws -> CGImage {
        let supW = 2 * geometry.supportHalf.x / geometry.millimetersPerPixel
        let supH = 2 * geometry.supportHalf.y / geometry.millimetersPerPixel
        let mid = CGPoint(x: Double(geometry.width) / 2, y: Double(geometry.height) / 2)
        let supRect = CGRect(x: mid.x - supW / 2, y: mid.y - supH / 2, width: supW, height: supH)
        let resolvedCoverage: (values: [Float], mask: CIImage)
        if let coverage {
            resolvedCoverage = coverage
        } else {
            let values = try gateCoverageMap(geometry)
            resolvedCoverage = (values, try gateMask(values, geometry))
        }
        return try compositeCenter(
            edge: edge, center: center, centerRectInCanvas: supRect,
            centerPivotInCanvas: mid, mask: resolvedCoverage,
            geometry: geometry, paperPrint: paperPrint,
            origin: (0, 0), size: (geometry.width, geometry.height),
            finished: finished)
    }

    static func replacingCenterPatch(
        _ edgePatch: CGImage, with centerPatch: CGImage,
        filmBounds: (minX: Double, maxX: Double, minY: Double, maxY: Double),
        origin: (x: Int, y: Int), size: (w: Int, h: Int),
        geometry: FilmEdgeGeometry, paperPrint: Bool,
        finished: Bool = false
    ) throws -> CGImage {
        let mm = geometry.millimetersPerPixel
        let mid = CGPoint(x: Double(geometry.width) / 2, y: Double(geometry.height) / 2)
        let patchOffsetX = Double(origin.x)
        let patchOffsetY = Double(geometry.height - (origin.y + size.h))
        let subRect = CGRect(
            x: mid.x + filmBounds.minX / mm - patchOffsetX,
            y: mid.y - filmBounds.maxY / mm - patchOffsetY,
            width: (filmBounds.maxX - filmBounds.minX) / mm,
            height: (filmBounds.maxY - filmBounds.minY) / mm)
        let pivot = CGPoint(x: mid.x - patchOffsetX, y: mid.y - patchOffsetY)
        var maskValues = [Float](repeating: 0, count: size.w * size.h)
        for dy in 0..<size.h {
            let cy = origin.y + dy
            for dx in 0..<size.w {
                maskValues[dy * size.w + dx] = Float(geometry.gateCoverage(x: origin.x + dx, y: cy))
            }
        }
        let maskImage = try gateMask(maskValues, width: size.w, height: size.h)
        return try compositeCenter(
            edge: edgePatch, center: centerPatch, centerRectInCanvas: subRect,
            centerPivotInCanvas: pivot, mask: (maskValues, maskImage),
            geometry: geometry, paperPrint: paperPrint,
            origin: origin, size: size, finished: finished)
    }

    private static func compositeCenter(
        edge: CGImage, center: CGImage,
        centerRectInCanvas rect: CGRect, centerPivotInCanvas pivot: CGPoint,
        mask: (values: [Float], mask: CIImage),
        geometry: FilmEdgeGeometry, paperPrint: Bool,
        origin: (x: Int, y: Int), size: (w: Int, h: Int),
        finished: Bool = false
    ) throws -> CGImage {
        let w = size.w, h = size.h
        let outSpace = finished ? CGColorSpace(name: CGColorSpace.sRGB)! : linear
        let outFormat: PixelStore.Format = finished ? .byte : .working
        let outCIFormat: CIFormat = finished ? .RGBA8 : RenderPrecision.resolved.ciFormat
        let angle = geometry.distress.tilt * .pi / 180
        let photograph = PixelStore.ciImage(center).clampedToExtent()
            .transformed(by: CGAffineTransform(
                scaleX: rect.width / Double(center.width),
                y: rect.height / Double(center.height)))
            .transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
            .transformed(by: CGAffineTransform(translationX: -pivot.x, y: -pivot.y)
                .concatenating(CGAffineTransform(rotationAngle: -angle))
                .concatenating(CGAffineTransform(translationX: pivot.x, y: pivot.y)))
        let canvas = CGRect(x: 0, y: 0, width: w, height: h)
        let result = photograph.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: PixelStore.ciImage(edge), kCIInputMaskImageKey: mask.mask])
            .cropped(to: canvas)
        let needsPass = needsCenterPass(geometry)
        if origin == (0, 0) && PixelStore.isLarge(width: w, height: h) {
            if !needsPass {
                let store = try PixelStore.render(
                    result, width: w, height: h, context: context, colorSpace: outSpace,
                    format: outFormat)
                return try store.image(colorSpace: outSpace)
            }
            let store = try PixelStore(width: w, height: h, format: outFormat)
            let band = max(256, 4_194_304 / max(w, 1))
            var bandBuffer = [SIMD4<Float>](repeating: .zero, count: w * band)
            var y = 0
            while y < h {
                try Task.checkCancellation()
                let rows = min(band, h - y)
                try bandBuffer.withUnsafeMutableBufferPointer { fullBuf in
                    var slice = UnsafeMutableBufferPointer(rebasing: fullBuf[0..<(w * rows)])
                    try autoreleasepool {
                        context.render(
                            result, toBitmap: slice.baseAddress!, rowBytes: w * 16,
                            bounds: CGRect(x: 0, y: h - y - rows, width: w, height: rows),
                            format: .RGBAf, colorSpace: linear)
                        try applyCenterDamage(
                            &slice, mask: mask.values, geometry: geometry, paperPrint: paperPrint,
                            origin: (0, y), size: (w, rows))
                        if finished {
                            let rowData = Data(
                                bytesNoCopy: slice.baseAddress!, count: w * rows * 16,
                                deallocator: .none)
                            let bandImg = CIImage(
                                bitmapData: rowData, bytesPerRow: w * 16,
                                size: CGSize(width: w, height: rows), format: .RGBAf,
                                colorSpace: linear)
                            context.render(
                                bandImg, toBitmap: store.base.advanced(by: y * store.rowBytes),
                                rowBytes: store.rowBytes,
                                bounds: CGRect(x: 0, y: 0, width: w, height: rows),
                                format: .RGBA8, colorSpace: outSpace)
                        } else {
                            store.write(
                                x: 0, y: y, width: w, height: rows,
                                from: slice.baseAddress!, sourceRowBytes: w * 16)
                        }
                    }
                }
                y += rows
            }
            return try store.image(colorSpace: outSpace)
        }
        guard needsPass else {
            guard let image = context.createCGImage(result, from: canvas, format: outCIFormat, colorSpace: outSpace, deferred: false)
            else { throw PhotoExporter.Failure.render }
            return image
        }
        var pixels = [SIMD4<Float>](repeating: .zero, count: w * h)
        pixels.withUnsafeMutableBytes {
            context.render(result, toBitmap: $0.baseAddress!, rowBytes: w * 16, bounds: canvas, format: .RGBAf, colorSpace: linear)
        }
        try pixels.withUnsafeMutableBufferPointer {
            try applyCenterDamage(&$0, mask: mask.values, geometry: geometry, paperPrint: paperPrint,
                                  origin: origin, size: (w, h))
        }
        let data = pixels.withUnsafeBytes { Data($0) }
        let damaged = CIImage(bitmapData: data, bytesPerRow: w * 16, size: CGSize(width: w, height: h), format: .RGBAf, colorSpace: linear)
        guard let image = context.createCGImage(damaged, from: canvas, format: outCIFormat, colorSpace: outSpace, deferred: false)
        else { throw PhotoExporter.Failure.render }
        return image
    }

    static func needsCenterPass(_ geometry: FilmEdgeGeometry) -> Bool {
        let d = geometry.distress
        return d.dust > 0 || (d.scratches > 0 && d.scratchesInImage)
    }

    /// Unwanted light is exposure, so a creative centre receives it before its LUT or tone: the
    /// same front/back leak and fog fields the film graph uses, in its mid-grey units, added to
    /// the framed source (spanning `[-supportHalf, +supportHalf]` or `filmBounds` in mm).
    /// Roll-start burn is applied post-grade through `MaterialBurnResponse` so every route matches
    /// its material edge response seamlessly across the gate.
    final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }
        var isCancelled: Bool {
            lock.lock()
            let value = cancelled
            lock.unlock()
            return value
        }
    }

    static func exposeCenter(
        _ input: SourceImageRenderer.Input, geometry: FilmEdgeGeometry,
        intent: SourceImageRenderer.Intent = .developedPhoto,
        sceneExposureScale: Double = 1.0,
        filmBounds: (minX: Double, maxX: Double, minY: Double, maxY: Double)? = nil,
        isCancelled: (@Sendable () -> Bool)? = nil
    ) throws -> SourceImageRenderer.Input {
        let d = geometry.distress
        let hasLeakOrFog = (d.leak > 0 && d.leakShape != .burn) || d.edgeFog > 0
        guard hasLeakOrFog else { return input }
        let w = input.width, h = input.height
        let one = SIMD3<Double>(repeating: 1)
        let lt = geometry.leakLight(neutral: one), ft = geometry.fogLight(neutral: one)
        let ct = geometry.coreLight(neutral: one)
        let leakTint = SIMD3<Float>(Float(lt.x), Float(lt.y), Float(lt.z))
        let fogTint = SIMD3<Float>(Float(ft.x), Float(ft.y), Float(ft.z))
        let coreTint = SIMD3<Float>(Float(ct.x), Float(ct.y), Float(ct.z))
        let linearScene = intent == .sceneLinear
        let exposureUnit = Float(0.184 / (linearScene ? max(sceneExposureScale, 1e-6) : 1.0))
        let knee: Float = 0.45, room = 1 - knee
        func linearized(_ v: Float) -> Float { v < knee ? v : knee - room * log((1 - v) / room) }
        func shouldered(_ y: Float) -> Float { y < knee ? y : 1 - room * exp(-(y - knee) / room) }
        let bounds = filmBounds ?? (
            minX: -geometry.supportHalf.x, maxX: geometry.supportHalf.x,
            minY: -geometry.supportHalf.y, maxY: geometry.supportHalf.y)
        let spanX = bounds.maxX - bounds.minX
        let spanY = bounds.maxY - bounds.minY
        let fogOnlyRectilinear = d.tilt == 0 && d.bulge == 0
            && (d.leak == 0 || d.leakShape == .burn)
            && (d.holeVariation == 0 || geometry.isCleanPrint || geometry.format != .film35)
        if fogOnlyRectilinear {
            let fxArr = (0..<w).map { bounds.minX + (Double($0) + 0.5) / Double(w) * spanX }
            let fyArr = (0..<h).map { bounds.minY + (Double($0) + 0.5) / Double(h) * spanY }
            let hasEdgeFog = d.edgeFog > 0
            let fogScale = 6.0 * d.edgeFog * d.edgeFog
            let fogLimit = 9.2 * d.fogDepth
            let s3 = FilmEdgeGeometry.streamSeed(d.seed, 3)
            let stockHalf = geometry.stockHalf
            let checkPerf = d.perforationLeak > 0 && geometry.format == .film35
            let perfCutoff = geometry.holeCenterOffset - 4.7
            let unitFog = fogTint * exposureUnit
            let unitFogX = unitFog.x, unitFogY = unitFog.y, unitFogZ = unitFog.z
            let portrait = geometry.portrait
            let alongCount = portrait ? h : w
            let acrossCount = portrait ? w : h
            var modPos = [Float](repeating: 0, count: alongCount)
            var modNeg = [Float](repeating: 0, count: alongCount)
            var scalePos = [Float](repeating: 0, count: acrossCount)
            var scaleNeg = [Float](repeating: 0, count: acrossCount)
            var hasPerfAcross = [Bool](repeating: false, count: acrossCount)
            if portrait {
                if hasEdgeFog {
                    for i in 0..<h {
                        let a = fyArr[i]
                        modPos[i] = Float(0.6 + 0.4 * FilmEdgeNoise.value(a / 6, 3.5, s3))
                        modNeg[i] = Float(0.6 + 0.4 * FilmEdgeNoise.value(a / 6, -3.5, s3))
                    }
                    for j in 0..<w {
                        let t = -fxArr[j]
                        let dPos = max(0, stockHalf - t)
                        let dNeg = max(0, stockHalf + t)
                        scalePos[j] = dPos < fogLimit ? Float(fogScale * exp(-dPos / d.fogDepth)) : 0
                        scaleNeg[j] = dNeg < fogLimit ? Float(fogScale * exp(-dNeg / d.fogDepth)) : 0
                    }
                }
                if checkPerf {
                    for j in 0..<w { hasPerfAcross[j] = abs(-fxArr[j]) >= perfCutoff }
                }
            } else {
                if hasEdgeFog {
                    for i in 0..<w {
                        let a = fxArr[i]
                        modPos[i] = Float(0.6 + 0.4 * FilmEdgeNoise.value(a / 6, 3.5, s3))
                        modNeg[i] = Float(0.6 + 0.4 * FilmEdgeNoise.value(a / 6, -3.5, s3))
                    }
                    for j in 0..<h {
                        let t = fyArr[j]
                        let dPos = max(0, stockHalf - t)
                        let dNeg = max(0, stockHalf + t)
                        scalePos[j] = dPos < fogLimit ? Float(fogScale * exp(-dPos / d.fogDepth)) : 0
                        scaleNeg[j] = dNeg < fogLimit ? Float(fogScale * exp(-dNeg / d.fogDepth)) : 0
                    }
                }
                if checkPerf {
                    for j in 0..<h { hasPerfAcross[j] = abs(fyArr[j]) >= perfCutoff }
                }
            }
            @inline(__always) func addFog(_ p: SIMD4<Float>, fog: Float) -> SIMD4<Float> {
                let lx = unitFogX * fog, ly = unitFogY * fog, lz = unitFogZ * fog
                if linearScene {
                    return SIMD4(p.x + lx, p.y + ly, p.z + lz, p.w)
                }
                let cx = min(max(p.x, 0), 0.999)
                let cy = min(max(p.y, 0), 0.999)
                let cz = min(max(p.z, 0), 0.999)
                let ax = cx < knee ? cx : knee - room * log((1 - cx) / room)
                let ay = cy < knee ? cy : knee - room * log((1 - cy) / room)
                let az = cz < knee ? cz : knee - room * log((1 - cz) / room)
                let ux = ax + lx, uy = ay + ly, uz = az + lz
                let sx = ux < knee ? ux : 1 - room * exp(-(ux - knee) / room)
                let sy = uy < knee ? uy : 1 - room * exp(-(uy - knee) / room)
                let sz = uz < knee ? uz : 1 - room * exp(-(uz - knee) / room)
                return SIMD4(p.x + sx - cx, p.y + sy - cy, p.z + sz - cz, p.w)
            }
            let bands = max(1, min(h, ProcessInfo.processInfo.activeProcessorCount * 4))
            @inline(__always) func processRow(
                y: Int, rowPtr: UnsafeMutablePointer<SIMD4<Float>>,
                fxP: UnsafePointer<Double>, fyVal: Double,
                modPosP: UnsafePointer<Float>, modNegP: UnsafePointer<Float>,
                scalePosP: UnsafePointer<Float>, scaleNegP: UnsafePointer<Float>,
                perfP: UnsafePointer<Bool>
            ) {
                if !portrait {
                    let sp = scalePosP[y], sn = scaleNegP[y], hp = perfP[y]
                    if sp == 0 && sn == 0 && !hp { return }
                    for x in 0..<w {
                        var fog = sp * modPosP[x] + sn * modNegP[x]
                        if hp { fog += Float(geometry.perforationFogAt(along: fxP[x], across: fyVal)) }
                        if fog == 0 { continue }
                        rowPtr[x] = addFog(rowPtr[x], fog: fog)
                    }
                } else {
                    let mp = modPosP[y], mn = modNegP[y]
                    for x in 0..<w {
                        let sp = scalePosP[x], sn = scaleNegP[x], hp = perfP[x]
                        var fog = sp * mp + sn * mn
                        if hp { fog += Float(geometry.perforationFogAt(along: fyVal, across: -fxP[x])) }
                        if fog == 0 { continue }
                        rowPtr[x] = addFog(rowPtr[x], fog: fog)
                    }
                }
            }
            if let store = input.store {
                let copy = try PixelStore(width: w, height: h, format: store.format)
                fxArr.withUnsafeBufferPointer { fxB in
                    fyArr.withUnsafeBufferPointer { fyB in
                        modPos.withUnsafeBufferPointer { mpB in
                            modNeg.withUnsafeBufferPointer { mnB in
                                scalePos.withUnsafeBufferPointer { spB in
                                    scaleNeg.withUnsafeBufferPointer { snB in
                                        hasPerfAcross.withUnsafeBufferPointer { hpB in
                                            nonisolated(unsafe) let fxP = fxB.baseAddress!
                                            nonisolated(unsafe) let fyP = fyB.baseAddress!
                                            nonisolated(unsafe) let mpP = mpB.baseAddress!
                                            nonisolated(unsafe) let mnP = mnB.baseAddress!
                                            nonisolated(unsafe) let spP = spB.baseAddress!
                                            nonisolated(unsafe) let snP = snB.baseAddress!
                                            nonisolated(unsafe) let hpP = hpB.baseAddress!
                                            DispatchQueue.concurrentPerform(iterations: bands) { band in
                                                var row = [SIMD4<Float>](repeating: .zero, count: w)
                                                row.withUnsafeMutableBufferPointer { buf in
                                                    let rp = buf.baseAddress!
                                                    for y in (band * h / bands)..<((band + 1) * h / bands) {
                                                        if (y & 15) == 0, isCancelled?() == true { return }
                                                        store.read(x: 0, y: y, width: w, height: 1, into: rp)
                                                        processRow(
                                                            y: y, rowPtr: rp, fxP: fxP, fyVal: fyP[y],
                                                            modPosP: mpP, modNegP: mnP, scalePosP: spP, scaleNegP: snP, perfP: hpP)
                                                        copy.write(x: 0, y: y, width: w, height: 1, from: rp, sourceRowBytes: w * 16)
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                if isCancelled?() == true { throw CancellationError() }
                try Task.checkCancellation()
                return .init(pixels: [], width: w, height: h, store: copy)
            }
            var pixels = input.pixels
            pixels.withUnsafeMutableBufferPointer { pBuf in
                fxArr.withUnsafeBufferPointer { fxB in
                    fyArr.withUnsafeBufferPointer { fyB in
                        modPos.withUnsafeBufferPointer { mpB in
                            modNeg.withUnsafeBufferPointer { mnB in
                                scalePos.withUnsafeBufferPointer { spB in
                                    scaleNeg.withUnsafeBufferPointer { snB in
                                        hasPerfAcross.withUnsafeBufferPointer { hpB in
                                            nonisolated(unsafe) let out = pBuf.baseAddress!
                                            nonisolated(unsafe) let fxP = fxB.baseAddress!
                                            nonisolated(unsafe) let fyP = fyB.baseAddress!
                                            nonisolated(unsafe) let mpP = mpB.baseAddress!
                                            nonisolated(unsafe) let mnP = mnB.baseAddress!
                                            nonisolated(unsafe) let spP = spB.baseAddress!
                                            nonisolated(unsafe) let snP = snB.baseAddress!
                                            nonisolated(unsafe) let hpP = hpB.baseAddress!
                                            DispatchQueue.concurrentPerform(iterations: bands) { band in
                                                for y in (band * h / bands)..<((band + 1) * h / bands) {
                                                    if (y & 15) == 0, isCancelled?() == true { return }
                                                    processRow(
                                                        y: y, rowPtr: out + y * w, fxP: fxP, fyVal: fyP[y],
                                                        modPosP: mpP, modNegP: mnP, scalePosP: spP, scaleNegP: snP, perfP: hpP)
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            if isCancelled?() == true { throw CancellationError() }
            try Task.checkCancellation()
            return .init(pixels: pixels, width: w, height: h)
        }
        @inline(__always) func applyPixel(_ p: SIMD4<Float>, filmX: Double, filmY: Double) -> SIMD4<Float>? {
            let e = geometry.exposureFields(filmX: filmX, filmY: filmY, includeBurn: false)
            let light = leakTint * Float(e.front + e.back) + fogTint * Float(e.fog) + coreTint * Float(e.core)
            if light == .zero { return nil }
            let v = SIMD3(p.x, p.y, p.z)
            if linearScene {
                let lit = v + exposureUnit * light
                return SIMD4(lit.x, lit.y, lit.z, p.w)
            }
            let c = simd_clamp(v, .zero, SIMD3(repeating: 0.999))
            let lifted = SIMD3(linearized(c.x), linearized(c.y), linearized(c.z)) + exposureUnit * light
            let lit = v + SIMD3(shouldered(lifted.x), shouldered(lifted.y), shouldered(lifted.z)) - c
            return SIMD4(lit.x, lit.y, lit.z, p.w)
        }
        func expose(_ out: UnsafeMutablePointer<SIMD4<Float>>) throws {
            let bands = max(1, min(h, ProcessInfo.processInfo.activeProcessorCount * 4))
            nonisolated(unsafe) let out = out
            DispatchQueue.concurrentPerform(iterations: bands) { band in
                for y in (band * h / bands)..<((band + 1) * h / bands) {
                    if (y & 15) == 0, isCancelled?() == true { return }
                    let fy = bounds.minY + (Double(y) + 0.5) / Double(h) * spanY
                    for x in 0..<w {
                        let fx = bounds.minX + (Double(x) + 0.5) / Double(w) * spanX
                        if let lit = applyPixel(out[y * w + x], filmX: fx, filmY: fy) {
                            out[y * w + x] = lit
                        }
                    }
                }
            }
            if isCancelled?() == true { throw CancellationError() }
            try Task.checkCancellation()
        }
        if let store = input.store {
            // The framed source is kept between frames; never expose it in place.
            let copy = try PixelStore(width: w, height: h, format: store.format)
            let bands = max(1, min(h, ProcessInfo.processInfo.activeProcessorCount * 4))
            DispatchQueue.concurrentPerform(iterations: bands) { band in
                var row = [SIMD4<Float>](repeating: .zero, count: w)
                row.withUnsafeMutableBufferPointer { buf in
                    for y in (band * h / bands)..<((band + 1) * h / bands) {
                        if (y & 15) == 0, isCancelled?() == true { return }
                        store.read(x: 0, y: y, width: w, height: 1, into: buf.baseAddress!)
                        let fy = bounds.minY + (Double(y) + 0.5) / Double(h) * spanY
                        for x in 0..<w {
                            let fx = bounds.minX + (Double(x) + 0.5) / Double(w) * spanX
                            if let lit = applyPixel(buf[x], filmX: fx, filmY: fy) {
                                buf[x] = lit
                            }
                        }
                        copy.write(x: 0, y: y, width: w, height: 1, from: buf.baseAddress!, sourceRowBytes: w * 16)
                    }
                }
            }
            if isCancelled?() == true { throw CancellationError() }
            try Task.checkCancellation()
            return .init(pixels: [], width: w, height: h, store: copy)
        }
        var pixels = input.pixels
        try pixels.withUnsafeMutableBufferPointer { try expose($0.baseAddress!) }
        return .init(pixels: pixels, width: w, height: h)
    }

    static func applyCenterDamage(_ store: PixelStore, mask: [Float],
                                  geometry: FilmEdgeGeometry, paperPrint: Bool) throws {
        let w = geometry.width, h = geometry.height
        let paperWhite = SIMD3<Float>(repeating: 0.8), scanLight = SIMD3<Float>(repeating: 0.77)
        let sw = FilmEdgeGeometry.scatterWeights, weights = SIMD3<Float>(Float(sw.x), Float(sw.y), Float(sw.z))
        let hasDust = geometry.distress.dust > 0
        let crossing = geometry.distress.scratchesInImage && geometry.distress.scratches > 0
        guard hasDust || crossing else { return }
        let bands = max(1, min(h, ProcessInfo.processInfo.activeProcessorCount * 4))
        DispatchQueue.concurrentPerform(iterations: bands) { band in
            var row = [SIMD4<Float>](repeating: .zero, count: w)
            row.withUnsafeMutableBufferPointer { buf in
                for y in (band * h / bands)..<((band + 1) * h / bands) {
                    store.read(x: 0, y: y, width: w, height: 1, into: buf.baseAddress!)
                    var changed = false
                    for x in 0..<w {
                        let g = mask[y * w + x]
                        if g <= 0 { continue }
                        let p = buf[x]
                        var v = SIMD3(p.x, p.y, p.z)
                        let scratch = crossing ? geometry.scratchFields(x: x, y: y) : FilmEdgeGeometry.ScratchFields()
                        let dust = hasDust ? Float(geometry.dustOcclusion(x: x, y: y)) * g : 0
                        let scatter = Float(scratch.scatter) * g * weights
                        let cut = SIMD3<Float>(Float(scratch.removal.x), Float(scratch.removal.y), Float(scratch.removal.z)) * g
                        if paperPrint {
                            v = v * (1 - dust) + paperWhite * dust
                            v = v + (paperWhite - v) * scatter
                            v = v * (1 - cut)
                        } else {
                            v = v * (1 - dust) * (1 - scatter)
                            v = v + (scanLight - v) * cut
                        }
                        if v == SIMD3(p.x, p.y, p.z) { continue }
                        buf[x] = SIMD4(v.x, v.y, v.z, 1)
                        changed = true
                    }
                    if changed {
                        store.write(x: 0, y: y, width: w, height: 1, from: buf.baseAddress!, sourceRowBytes: w * 16)
                    }
                }
            }
        }
        try Task.checkCancellation()
    }

    /// A creative centre has no developed density to modulate, so apply the visible result of the
    /// same particles. Paper from a negative: opaque dust and scatter print light (scatter bluish),
    /// cut dye prints its complement (a shallow yellow-layer cut prints yellow, deeper red, then
    /// black). Transmission scan: dust and scatter darken; cut dye lets its complementary light
    /// through (shallow blue, deeper cyan, then the scanner's white).
    static func applyCenterDamage(
        _ pixels: inout UnsafeMutableBufferPointer<SIMD4<Float>>, mask: [Float]? = nil,
        geometry: FilmEdgeGeometry, paperPrint: Bool,
        origin: (x: Int, y: Int) = (0, 0), size: (w: Int, h: Int)? = nil
    ) throws {
        let w = size?.w ?? geometry.width, h = size?.h ?? geometry.height
        let paperWhite = SIMD3<Float>(repeating: 0.8), scanLight = SIMD3<Float>(repeating: 0.77)
        let sw = FilmEdgeGeometry.scatterWeights, weights = SIMD3<Float>(Float(sw.x), Float(sw.y), Float(sw.z))
        let hasDust = geometry.distress.dust > 0
        let crossing = geometry.distress.scratchesInImage && geometry.distress.scratches > 0
        guard hasDust || crossing else { return }
        let bands = max(1, min(h, ProcessInfo.processInfo.activeProcessorCount * 4))
        do {
            nonisolated(unsafe) let out = pixels.baseAddress!
            DispatchQueue.concurrentPerform(iterations: bands) { band in
                for y in (band * h / bands)..<((band + 1) * h / bands) {
                    let cy = origin.y + y
                    for x in 0..<w {
                        let g = mask.map { $0[y * w + x] } ?? 1
                        if g <= 0 { continue }
                        let cx = origin.x + x
                        let p = out[y * w + x]
                        var v = SIMD3(p.x, p.y, p.z)
                        let scratch = crossing ? geometry.scratchFields(x: cx, y: cy) : FilmEdgeGeometry.ScratchFields()
                        let dust = hasDust ? Float(geometry.dustOcclusion(x: cx, y: cy)) * g : 0
                        let scatter = Float(scratch.scatter) * g * weights
                        let cut = SIMD3<Float>(Float(scratch.removal.x), Float(scratch.removal.y), Float(scratch.removal.z)) * g
                        if paperPrint {
                            v = v * (1 - dust) + paperWhite * dust
                            v = v + (paperWhite - v) * scatter
                            v = v * (1 - cut)
                        } else {
                            v = v * (1 - dust) * (1 - scatter)
                            v = v + (scanLight - v) * cut
                        }
                        if v == SIMD3(p.x, p.y, p.z) { continue }
                        out[y * w + x] = SIMD4(v.x, v.y, v.z, 1)
                    }
                }
            }
            try Task.checkCancellation()
        }
    }

    static func applyCleanPrintDamage(
        _ image: CGImage, geometry: FilmEdgeGeometry, paperPrint: Bool,
        origin: (x: Int, y: Int) = (0, 0), finished: Bool = false
    ) throws -> CGImage {
        let w = image.width, h = image.height
        let outSpace = finished ? CGColorSpace(name: CGColorSpace.sRGB)! : linear
        let outFormat: PixelStore.Format = finished ? .byte : .working
        let outCIFormat: CIFormat = finished ? .RGBA8 : RenderPrecision.resolved.ciFormat
        let canvas = CGRect(x: 0, y: 0, width: w, height: h)
        let source = PixelStore.ciImage(image)
        let needsPass = needsCenterPass(geometry)
        if origin == (0, 0) && PixelStore.isLarge(width: w, height: h) {
            if !needsPass {
                guard finished else { return image }
                let store = try PixelStore.render(
                    source, width: w, height: h, context: context, colorSpace: outSpace, format: outFormat)
                return try store.image(colorSpace: outSpace)
            }
            let store = try PixelStore(width: w, height: h, format: outFormat)
            let band = max(256, 4_194_304 / max(w, 1))
            var bandBuffer = [SIMD4<Float>](repeating: .zero, count: w * band)
            var y = 0
            while y < h {
                try Task.checkCancellation()
                let rows = min(band, h - y)
                try bandBuffer.withUnsafeMutableBufferPointer { fullBuf in
                    var slice = UnsafeMutableBufferPointer(rebasing: fullBuf[0..<(w * rows)])
                    try autoreleasepool {
                        context.render(
                            source, toBitmap: slice.baseAddress!, rowBytes: w * 16,
                            bounds: CGRect(x: 0, y: h - y - rows, width: w, height: rows),
                            format: .RGBAf, colorSpace: linear)
                        try applyCenterDamage(
                            &slice, mask: nil, geometry: geometry, paperPrint: paperPrint,
                            origin: (0, y), size: (w, rows))
                        if finished {
                            let rowData = Data(
                                bytesNoCopy: slice.baseAddress!, count: w * rows * 16,
                                deallocator: .none)
                            let bandImg = CIImage(
                                bitmapData: rowData, bytesPerRow: w * 16,
                                size: CGSize(width: w, height: rows), format: .RGBAf,
                                colorSpace: linear)
                            context.render(
                                bandImg, toBitmap: store.base.advanced(by: y * store.rowBytes),
                                rowBytes: store.rowBytes,
                                bounds: CGRect(x: 0, y: 0, width: w, height: rows),
                                format: .RGBA8, colorSpace: outSpace)
                        } else {
                            store.write(
                                x: 0, y: y, width: w, height: rows,
                                from: slice.baseAddress!, sourceRowBytes: w * 16)
                        }
                    }
                }
                y += rows
            }
            return try store.image(colorSpace: outSpace)
        }
        guard needsPass else {
            guard finished else { return image }
            guard let rendered = context.createCGImage(source, from: canvas, format: outCIFormat, colorSpace: outSpace, deferred: false)
            else { throw PhotoExporter.Failure.render }
            return rendered
        }
        var pixels = [SIMD4<Float>](repeating: .zero, count: w * h)
        pixels.withUnsafeMutableBytes {
            context.render(source, toBitmap: $0.baseAddress!, rowBytes: w * 16, bounds: canvas, format: .RGBAf, colorSpace: linear)
        }
        try pixels.withUnsafeMutableBufferPointer {
            try applyCenterDamage(&$0, mask: nil, geometry: geometry, paperPrint: paperPrint, origin: origin, size: (w, h))
        }
        let data = pixels.withUnsafeBytes { Data($0) }
        let damaged = CIImage(bitmapData: data, bytesPerRow: w * 16, size: CGSize(width: w, height: h), format: .RGBAf, colorSpace: linear)
        guard let output = context.createCGImage(damaged, from: canvas, format: outCIFormat, colorSpace: outSpace, deferred: false)
        else { throw PhotoExporter.Failure.render }
        return output
    }

    /// Gate coverage per pixel; exact rotated strip-space excursion bounds skip pure interior
    /// and exterior pixels while guaranteeing 0 error on every boundary pixel at any resolution.
    static func gateCoverageMap(_ geometry: FilmEdgeGeometry) throws -> [Float] {
        let w = geometry.width, h = geometry.height
        var values = [Float](repeating: 0, count: w * h)
        let mm = geometry.millimetersPerPixel
        let ha0 = (geometry.portrait ? geometry.gate.height : geometry.gate.width) * mm / 2
        let ht0 = (geometry.portrait ? geometry.gate.width : geometry.gate.height) * mm / 2
        let exc = geometry.apertureExcursionMm()
        let inAlong = ha0 - exc.inAlong, inAcross = ht0 - exc.inAcross
        let outAlong = ha0 + exc.outAlong, outAcross = ht0 + exc.outAcross
        let outX = geometry.portrait ? outAcross : outAlong
        let outY = geometry.portrait ? outAlong : outAcross
        let rad = geometry.distress.tilt * .pi / 180
        let c = abs(cos(rad)), s = abs(sin(rad))
        let halfCanvasX = (c * outX + s * outY) / mm + 2
        let halfCanvasY = (s * outX + c * outY) / mm + 2
        let xStart = max(0, Int(floor(Double(w) / 2 - halfCanvasX)))
        let xEnd = min(w, Int(ceil(Double(w) / 2 + halfCanvasX)))
        let yStart = max(0, Int(floor(Double(h) / 2 - halfCanvasY)))
        let yEnd = min(h, Int(ceil(Double(h) / 2 + halfCanvasY)))
        guard xStart < xEnd, yStart < yEnd else { return values }
        let spanY = yEnd - yStart
        let bands = max(1, min(spanY / 16, ProcessInfo.processInfo.activeProcessorCount * 4))
        values.withUnsafeMutableBufferPointer { buffer in
            nonisolated(unsafe) let out = buffer.baseAddress!
            DispatchQueue.concurrentPerform(iterations: bands) { band in
                for y in (yStart + band * spanY / bands)..<(yStart + (band + 1) * spanY / bands) {
                    for x in xStart..<xEnd {
                        let (fx, fy) = geometry.film(Double(x) + 0.5, Double(y) + 0.5)
                        let (a, t) = geometry.portrait ? (fy, -fx) : (fx, fy)
                        if abs(a) > outAlong || abs(t) > outAcross { continue }
                        if inAlong > 0, inAcross > 0, abs(a) <= inAlong, abs(t) <= inAcross {
                            out[y * w + x] = 1
                        } else {
                            out[y * w + x] = Float(geometry.gateCoverage(x: x, y: y))
                        }
                    }
                }
            }
        }
        try Task.checkCancellation()
        return values
    }
    static func gateMask(_ values: [Float], _ geometry: FilmEdgeGeometry) throws -> CIImage {
        try gateMask(values, width: geometry.width, height: geometry.height)
    }
    static func gateMask(_ values: [Float], width: Int, height: Int) throws -> CIImage {
        let bytes = values.map { UInt8((min(max($0, 0), 1) * 255).rounded()) }
        // Like CIImage(cgImage:), the first bitmap row is the top of the canvas.
        return CIImage(bitmapData: Data(bytes), bytesPerRow: width,
                       size: CGSize(width: width, height: height), format: .L8, colorSpace: nil)
    }

    /// Pre-baked LUT model of the material pipeline's continuous burn response across the gate so
    /// Original, 3D LUT, partial-Mix, and cross-family centers match the material edge's exact
    /// transition lip and saturated rebate density/color in real time on CPU.
    struct MaterialBurnResponse: Sendable {
        let basis0: SIMD3<Float>
        let basis1: SIMD3<Float>
        let basis2: SIMD3<Float>
        let exposureTableSize: Int
        let exposureTable: [SIMD3<Float>]
        let sceneScale: Float
        let neutralScaled: SIMD3<Float>

        let filmLogMin: Float
        let filmLogInvSpan: Float
        let filmCurveLUT: [SIMD3<Float>]
        let hasCouplers: Bool
        let couplerPositive: Bool
        let couplerMax: SIMD3<Float>
        let couplerRow0: SIMD3<Float>
        let couplerRow1: SIMD3<Float>
        let couplerRow2: SIMD3<Float>
        let couplerLogMin: Float
        let couplerLogInvSpan: Float
        let couplerCurveLUT: [SIMD3<Float>]

        let lutGrid: Int
        let dMin: SIMD3<Float>
        let dInvSpan: SIMD3<Float>
        let densityLUT: [SIMD3<Float>]

        let rebateUnburned: SIMD3<Float>
        let rebateSaturated: SIMD3<Float>

        init(pipeline: FilmPipeline, autoExposureEV: Double) {
            let color = pipeline.color
            let reference = pipeline.reference
            let autoScale = pow(2, autoExposureEV)
            let manualScale = pow(2, pipeline.recipe.number("camera.exposure_compensation_ev"))
            let n = color.exposure.raw(SIMD3<Double>(repeating: 0.184))
            self.sceneScale = Float(autoScale * manualScale * reference.filmingScale)
            self.neutralScaled = SIMD3<Float>(
                Float(n.x * reference.filmingScale),
                Float(n.y * reference.filmingScale),
                Float(n.z * reference.filmingScale))
            let b = color.exposure.rgbBasisXYZ
            self.basis0 = SIMD3<Float>(Float(b[0].x), Float(b[0].y), Float(b[0].z))
            self.basis1 = SIMD3<Float>(Float(b[1].x), Float(b[1].y), Float(b[1].z))
            self.basis2 = SIMD3<Float>(Float(b[2].x), Float(b[2].y), Float(b[2].z))
            self.exposureTableSize = color.exposure.table.size
            self.exposureTable = color.exposure.table.samples.map {
                SIMD3<Float>(Float($0.x), Float($0.y), Float($0.z))
            }

            let curveSamples = 512
            let coupled = color.coupledDevelopment
            let baseCurve = coupled?.original ?? color.filmCurve
            let fMin = baseCurve.axis.first ?? -4.0
            let fMax = baseCurve.axis.last ?? 4.0
            let fSpan = max(fMax - fMin, 1e-6)
            self.filmLogMin = Float(fMin)
            self.filmLogInvSpan = Float(Double(curveSamples - 1) / fSpan)
            var filmSamples = [SIMD3<Float>](repeating: .zero, count: curveSamples)
            var lo = SIMD3<Double>(repeating: .infinity)
            var hi = SIMD3<Double>(repeating: -.infinity)
            for i in 0..<curveSamples {
                let d = baseCurve.density(at: SIMD3<Double>(repeating: fMin + fSpan * Double(i) / Double(curveSamples - 1)))
                lo = simd_min(lo, d)
                hi = simd_max(hi, d)
                filmSamples[i] = SIMD3<Float>(Float(d.x), Float(d.y), Float(d.z))
            }
            self.filmCurveLUT = filmSamples

            if let coupled {
                let bc = coupled.beforeCouplers
                let cMin = bc.axis.first ?? -4.0
                let cMax = bc.axis.last ?? 4.0
                let cSpan = max(cMax - cMin, 1e-6)
                self.couplerLogMin = Float(cMin)
                self.couplerLogInvSpan = Float(Double(curveSamples - 1) / cSpan)
                var cSamples = [SIMD3<Float>](repeating: .zero, count: curveSamples)
                for i in 0..<curveSamples {
                    let d = bc.density(at: SIMD3<Double>(repeating: cMin + cSpan * Double(i) / Double(curveSamples - 1)))
                    lo = simd_min(lo, d)
                    hi = simd_max(hi, d)
                    cSamples[i] = SIMD3<Float>(Float(d.x), Float(d.y), Float(d.z))
                }
                self.couplerCurveLUT = cSamples
                self.couplerPositive = coupled.positive
                self.couplerMax = SIMD3<Float>(Float(coupled.maximum.x), Float(coupled.maximum.y), Float(coupled.maximum.z))
                let mr = coupled.matrix.rows
                self.couplerRow0 = SIMD3<Float>(Float(mr[0].x), Float(mr[0].y), Float(mr[0].z))
                self.couplerRow1 = SIMD3<Float>(Float(mr[1].x), Float(mr[1].y), Float(mr[1].z))
                self.couplerRow2 = SIMD3<Float>(Float(mr[2].x), Float(mr[2].y), Float(mr[2].z))
                self.hasCouplers = true
            } else {
                self.couplerLogMin = 0
                self.couplerLogInvSpan = 0
                self.couplerCurveLUT = []
                self.couplerPositive = false
                self.couplerMax = .zero
                self.couplerRow0 = .zero
                self.couplerRow1 = .zero
                self.couplerRow2 = .zero
                self.hasCouplers = false
            }

            let spanD = simd_max(hi - lo, SIMD3<Double>(repeating: 1e-3))
            let G = 25
            self.lutGrid = G
            self.dMin = SIMD3<Float>(Float(lo.x), Float(lo.y), Float(lo.z))
            self.dInvSpan = SIMD3<Float>(
                Float(Double(G - 1) / spanD.x),
                Float(Double(G - 1) / spanD.y),
                Float(Double(G - 1) / spanD.z))

            let scan = color.scanBasis
            let validScan = scan.channels.indices.filter { w in
                scan.base[w].isFinite && scan.illuminant[w].isFinite
                    && scan.channels[w].x.isFinite && scan.channels[w].y.isFinite && scan.channels[w].z.isFinite
                    && scan.cmfs[w].x.isFinite && scan.cmfs[w].y.isFinite && scan.cmfs[w].z.isFinite
            }
            let nScan = validScan.count
            let scanCh = validScan.map { scan.channels[$0] }
            let scanBase = validScan.map { w in
                scan.cmfs[w] * (pow(10.0, -scan.base[w]) * scan.illuminant[w] / scan.normalization)
            }

            var table = [SIMD3<Float>](repeating: .zero, count: G * G * G)
            if let enlarger = color.enlarger, let printCurve = color.printCurve {
                var pLo = SIMD3<Double>(repeating: .infinity)
                var pHi = SIMD3<Double>(repeating: -.infinity)
                for v in printCurve.values {
                    pLo = simd_min(pLo, v)
                    pHi = simd_max(pHi, v)
                }
                let pSpan = simd_max(pHi - pLo, SIMD3<Double>(repeating: 1e-3))
                let S = 25
                var scanTx = [Double](repeating: 1, count: S * nScan)
                var scanTy = [Double](repeating: 1, count: S * nScan)
                var scanTz = [Double](repeating: 1, count: S * nScan)
                for k in 0..<S {
                    let q = Double(k) / Double(S - 1)
                    let px = pLo.x + pSpan.x * q
                    let py = pLo.y + pSpan.y * q
                    let pz = pLo.z + pSpan.z * q
                    let base = k * nScan
                    for w in 0..<nScan {
                        let ch = scanCh[w]
                        scanTx[base + w] = pow(10.0, -px * ch.x)
                        scanTy[base + w] = pow(10.0, -py * ch.y)
                        scanTz[base + w] = pow(10.0, -pz * ch.z)
                    }
                }
                let scanXYZFlat = Self.spectralGrid(
                    grid: S, nW: nScan, tx: scanTx, ty: scanTy, tz: scanTz, weights: scanBase)
                let scanXYZ = (0..<(S * S * S)).map { idx in
                    let o = idx * 3
                    return SIMD3<Double>(scanXYZFlat[o], scanXYZFlat[o + 1], scanXYZFlat[o + 2])
                }

                let pcMin = printCurve.axis.first ?? -4.0
                let pcMax = printCurve.axis.last ?? 4.0
                let pcSpan = max(pcMax - pcMin, 1e-6)
                let pcInvSpan = Double(curveSamples - 1) / pcSpan
                let printLUT = (0..<curveSamples).map { i in
                    printCurve.density(at: SIMD3<Double>(repeating: pcMin + pcSpan * Double(i) / Double(curveSamples - 1)))
                }

                let validEnl = enlarger.channels.indices.filter { w in
                    enlarger.base[w].isFinite && enlarger.printLight[w].isFinite
                        && enlarger.channels[w].x.isFinite && enlarger.channels[w].y.isFinite && enlarger.channels[w].z.isFinite
                        && enlarger.sensitivity[w].x.isFinite && enlarger.sensitivity[w].y.isFinite && enlarger.sensitivity[w].z.isFinite
                }
                let nEnl = validEnl.count
                let enlCh = validEnl.map { enlarger.channels[$0] }
                let enlSens = validEnl.map { w in
                    enlarger.sensitivity[w] * (pow(10.0, -enlarger.base[w]) * enlarger.printLight[w])
                }
                var enlTx = [Double](repeating: 1, count: G * nEnl)
                var enlTy = [Double](repeating: 1, count: G * nEnl)
                var enlTz = [Double](repeating: 1, count: G * nEnl)
                for k in 0..<G {
                    let q = Double(k) / Double(G - 1)
                    let dx = lo.x + spanD.x * q
                    let dy = lo.y + spanD.y * q
                    let dz = lo.z + spanD.z * q
                    let base = k * nEnl
                    for w in 0..<nEnl {
                        let ch = enlCh[w]
                        enlTx[base + w] = pow(10.0, -dx * ch.x)
                        enlTy[base + w] = pow(10.0, -dy * ch.y)
                        enlTz[base + w] = pow(10.0, -dz * ch.z)
                    }
                }
                let enlRawFlat = Self.spectralGrid(
                    grid: G, nW: nEnl, tx: enlTx, ty: enlTy, tz: enlTz, weights: enlSens)
                let pInvSpan = SIMD3<Double>(
                    Double(S - 1) / pSpan.x,
                    Double(S - 1) / pSpan.y,
                    Double(S - 1) / pSpan.z)
                let printGain = enlarger.printExposure * reference.printingScale
                let preflash = enlarger.preflash
                let factor = enlarger.factor
                let compression = color.compression
                let scanMatrix = color.scanMatrix
                let encodingMatrix = color.encodingMatrix
                @inline(__always) func interpPrint(_ lp: Double, _ pick: (SIMD3<Double>) -> Double) -> Double {
                    let u = min(max((lp - pcMin) * pcInvSpan, 0), Double(curveSamples - 1))
                    let i0 = min(Int(u), curveSamples - 2)
                    let a = pick(printLUT[i0]), b = pick(printLUT[i0 + 1])
                    return a + (b - a) * (u - Double(i0))
                }
                table.withUnsafeMutableBufferPointer { outBuf in
                    nonisolated(unsafe) let outPtr = outBuf.baseAddress!
                    enlRawFlat.withUnsafeBufferPointer { rawBuf in
                        nonisolated(unsafe) let rawPtr = rawBuf.baseAddress!
                        scanXYZ.withUnsafeBufferPointer { sXYZBuf in
                            nonisolated(unsafe) let sXYZPtr = sXYZBuf.baseAddress!
                            DispatchQueue.concurrentPerform(iterations: G) { iz in
                                for iy in 0..<G {
                                    let rowOff = (iz * G + iy) * G
                                    for ix in 0..<G {
                                        let rOff = (rowOff + ix) * 3
                                        let raw = SIMD3<Double>(rawPtr[rOff], rawPtr[rOff + 1], rawPtr[rOff + 2])
                                        let baseExp = raw * factor + preflash
                                        let printRaw = (simd_max(baseExp, .zero) + 1e-10) * printGain
                                        let pDens = SIMD3<Double>(
                                            interpPrint(log10(max(printRaw.x, 0) + 1e-10)) { $0.x },
                                            interpPrint(log10(max(printRaw.y, 0) + 1e-10)) { $0.y },
                                            interpPrint(log10(max(printRaw.z, 0) + 1e-10)) { $0.z })
                                        let gx = min(max((pDens.x - pLo.x) * pInvSpan.x, 0), Double(S - 1))
                                        let gy = min(max((pDens.y - pLo.y) * pInvSpan.y, 0), Double(S - 1))
                                        let gz = min(max((pDens.z - pLo.z) * pInvSpan.z, 0), Double(S - 1))
                                        let sx0 = min(Int(gx), S - 2), sy0 = min(Int(gy), S - 2), sz0 = min(Int(gz), S - 2)
                                        let fx = gx - Double(sx0), fy = gy - Double(sy0), fz = gz - Double(sz0)
                                        let i00 = sz0 * S * S + sy0 * S + sx0
                                        let i10 = i00 + S
                                        let i01 = i00 + S * S
                                        let i11 = i01 + S
                                        let c00 = sXYZPtr[i00] * (1 - fx) + sXYZPtr[i00 + 1] * fx
                                        let c10 = sXYZPtr[i10] * (1 - fx) + sXYZPtr[i10 + 1] * fx
                                        let c01 = sXYZPtr[i01] * (1 - fx) + sXYZPtr[i01 + 1] * fx
                                        let c11 = sXYZPtr[i11] * (1 - fx) + sXYZPtr[i11 + 1] * fx
                                        let v = (c00 * (1 - fy) + c10 * fy) * (1 - fz) + (c01 * (1 - fy) + c11 * fy) * fz
                                        let xyz = reference.correct(SIMD3<Double>(max(v.x, 1e-10), max(v.y, 1e-10), max(v.z, 1e-10)))
                                        let compressed = compression.compress(ColorPipeline.apply(scanMatrix, xyz))
                                        let linear = ColorPipeline.apply(encodingMatrix, compressed)
                                        outPtr[rowOff + ix] = SIMD3<Float>(
                                            linear.x.isFinite ? Float(linear.x) : 0,
                                            linear.y.isFinite ? Float(linear.y) : 0,
                                            linear.z.isFinite ? Float(linear.z) : 0)
                                    }
                                }
                            }
                        }
                    }
                }
            } else {
                var scanTx = [Double](repeating: 1, count: G * nScan)
                var scanTy = [Double](repeating: 1, count: G * nScan)
                var scanTz = [Double](repeating: 1, count: G * nScan)
                for k in 0..<G {
                    let q = Double(k) / Double(G - 1)
                    let dx = lo.x + spanD.x * q
                    let dy = lo.y + spanD.y * q
                    let dz = lo.z + spanD.z * q
                    let base = k * nScan
                    for w in 0..<nScan {
                        let ch = scanCh[w]
                        scanTx[base + w] = pow(10.0, -dx * ch.x)
                        scanTy[base + w] = pow(10.0, -dy * ch.y)
                        scanTz[base + w] = pow(10.0, -dz * ch.z)
                    }
                }
                let scanXYZFlat = Self.spectralGrid(
                    grid: G, nW: nScan, tx: scanTx, ty: scanTy, tz: scanTz, weights: scanBase)
                let compression = color.compression
                let scanMatrix = color.scanMatrix
                let encodingMatrix = color.encodingMatrix
                table.withUnsafeMutableBufferPointer { outBuf in
                    nonisolated(unsafe) let outPtr = outBuf.baseAddress!
                    scanXYZFlat.withUnsafeBufferPointer { xyzBuf in
                        nonisolated(unsafe) let xyzPtr = xyzBuf.baseAddress!
                        DispatchQueue.concurrentPerform(iterations: G) { iz in
                            for iy in 0..<G {
                                let rowOff = (iz * G + iy) * G
                                for ix in 0..<G {
                                    let o = (rowOff + ix) * 3
                                    let v = SIMD3<Double>(xyzPtr[o], xyzPtr[o + 1], xyzPtr[o + 2])
                                    let xyz = reference.correct(SIMD3<Double>(max(v.x, 1e-10), max(v.y, 1e-10), max(v.z, 1e-10)))
                                    let compressed = compression.compress(ColorPipeline.apply(scanMatrix, xyz))
                                    let linear = ColorPipeline.apply(encodingMatrix, compressed)
                                    outPtr[rowOff + ix] = SIMD3<Float>(
                                        linear.x.isFinite ? Float(linear.x) : 0,
                                        linear.y.isFinite ? Float(linear.y) : 0,
                                        linear.z.isFinite ? Float(linear.z) : 0)
                                }
                            }
                        }
                    }
                }
            }
            self.densityLUT = table
            self.rebateUnburned = Self.evaluateLinearSRGB(
                scaledRaw: .zero, color: color, reference: reference)
            self.rebateSaturated = Self.evaluateLinearSRGB(
                scaledRaw: n * 200.0 * reference.filmingScale,
                color: color, reference: reference)
        }

        private static func spectralGrid(
            grid Q: Int, nW K: Int,
            tx: [Double], ty: [Double], tz: [Double],
            weights: [SIMD3<Double>]
        ) -> [Double] {
            let total = Q * Q * Q * 3
            guard K > 0 else { return [Double](repeating: 0, count: total) }
            let M = Q * Q
            let N = Q * 3
            var matA = [Double](repeating: 0, count: M * K)
            matA.withUnsafeMutableBufferPointer { bufA in
                let pA = bufA.baseAddress!
                for iz in 0..<Q {
                    let zOff = iz * K
                    for iy in 0..<Q {
                        let yOff = iy * K
                        let row = (iz * Q + iy) * K
                        for w in 0..<K {
                            pA[row + w] = ty[yOff + w] * tz[zOff + w]
                        }
                    }
                }
            }
            var matB = [Double](repeating: 0, count: K * N)
            matB.withUnsafeMutableBufferPointer { bufB in
                let pB = bufB.baseAddress!
                for w in 0..<K {
                    let wt = weights[w]
                    let row = w * N
                    for ix in 0..<Q {
                        let t = tx[ix * K + w]
                        let col = row + ix * 3
                        pB[col] = t * wt.x
                        pB[col + 1] = t * wt.y
                        pB[col + 2] = t * wt.z
                    }
                }
            }
            var out = [Double](repeating: 0, count: total)
            matA.withUnsafeBufferPointer { bA in
                matB.withUnsafeBufferPointer { bB in
                    out.withUnsafeMutableBufferPointer { bC in
                        vDSP_mmulD(
                            bA.baseAddress!, 1, bB.baseAddress!, 1, bC.baseAddress!, 1,
                            vDSP_Length(M), vDSP_Length(N), vDSP_Length(K))
                    }
                }
            }
            return out
        }

        private static func evaluateLinearSRGB(
            scaledRaw: SIMD3<Double>, color: ColorPipeline, reference: ReferenceCorrectionCore
        ) -> SIMD3<Float> {
            let logRaw = SIMD3<Double>(
                log10(max(scaledRaw.x, 0) + 1e-10),
                log10(max(scaledRaw.y, 0) + 1e-10),
                log10(max(scaledRaw.z, 0) + 1e-10))
            let filmDensity = color.coupledDevelopment?.density(at: logRaw) ?? color.filmCurve.density(at: logRaw)
            let density: SIMD3<Double>
            if let enlarger = color.enlarger, let printCurve = color.printCurve {
                let printRaw = enlarger.rawExposure(filmDensity) * reference.printingScale
                let logPrint = SIMD3<Double>(
                    log10(max(printRaw.x, 0) + 1e-10),
                    log10(max(printRaw.y, 0) + 1e-10),
                    log10(max(printRaw.z, 0) + 1e-10))
                density = printCurve.density(at: logPrint)
            } else {
                density = filmDensity
            }
            let v = color.scanBasis.xyz(density)
            let xyz = reference.correct(SIMD3<Double>(max(v.x, 1e-10), max(v.y, 1e-10), max(v.z, 1e-10)))
            let compressed = color.compression.compress(ColorPipeline.apply(color.scanMatrix, xyz))
            let linear = ColorPipeline.apply(color.encodingMatrix, compressed)
            return SIMD3<Float>(Float(linear.x), Float(linear.y), Float(linear.z))
        }

        struct Sampler: @unchecked Sendable {
            let basis0: SIMD3<Float>
            let basis1: SIMD3<Float>
            let basis2: SIMD3<Float>
            let exposureTableSize: Int
            nonisolated(unsafe) let expPtr: UnsafePointer<SIMD3<Float>>
            let sceneScale: Float
            let neutralScaled: SIMD3<Float>
            let filmLast: Int
            let filmLogMin: Float
            let filmLogInvSpan: Float
            nonisolated(unsafe) let filmPtr: UnsafePointer<SIMD3<Float>>
            let hasCouplers: Bool
            let couplerPositive: Bool
            let couplerMax: SIMD3<Float>
            let couplerRow0: SIMD3<Float>
            let couplerRow1: SIMD3<Float>
            let couplerRow2: SIMD3<Float>
            let couplerLast: Int
            let couplerLogMin: Float
            let couplerLogInvSpan: Float
            nonisolated(unsafe) let couplerPtr: UnsafePointer<SIMD3<Float>>
            let lutGrid: Int
            let dMin: SIMD3<Float>
            let dInvSpan: SIMD3<Float>
            nonisolated(unsafe) let densPtr: UnsafePointer<SIMD3<Float>>
            let rebateUnburned: SIMD3<Float>
            let rebateSaturated: SIMD3<Float>
            let span: SIMD3<Float>
            let invSpan: SIMD3<Float>

            @inline(__always)
            func cameraRaw(_ linearRGB: SIMD3<Float>) -> SIMD3<Float> {
                let xyz = basis0 * linearRGB.x + basis1 * linearRGB.y + basis2 * linearRGB.z
                let brightness = xyz.x + xyz.y + xyz.z
                if !brightness.isFinite || brightness <= 0 { return .zero }
                let invB = 1.0 / max(brightness, 1e-10)
                let xyX = xyz.x * invB
                let xyY = xyz.y * invB
                let inverseX = 1.0 - xyX
                let cx = min(max(inverseX * inverseX, 0), 1)
                let cy = min(max(xyY / max(inverseX, 1e-10), 0), 1)
                let n = exposureTableSize
                let scale = Float(n - 1)
                let sx = cx * scale, sy = cy * scale
                let x0 = min(Int(sx), n - 2), y0 = min(Int(sy), n - 2)
                let fx = sx - Float(x0), fy = sy - Float(y0)
                let row0 = x0 * n + y0
                let row1 = row0 + n
                let a = expPtr[row0] + (expPtr[row0 + 1] - expPtr[row0]) * fy
                let b = expPtr[row1] + (expPtr[row1 + 1] - expPtr[row1]) * fy
                return (a + (b - a) * fx) * brightness
            }

            @inline(__always)
            private static func sample1D(_ ptr: UnsafePointer<SIMD3<Float>>, last: Int, logMin: Float, invSpan: Float, v: SIMD3<Float>) -> SIMD3<Float> {
                let lastF = Float(last)
                let ux = min(max((v.x - logMin) * invSpan, 0), lastF)
                let uy = min(max((v.y - logMin) * invSpan, 0), lastF)
                let uz = min(max((v.z - logMin) * invSpan, 0), lastF)
                let ix = min(Int(ux), last - 1), fx = ux - Float(ix)
                let iy = min(Int(uy), last - 1), fy = uy - Float(iy)
                let iz = min(Int(uz), last - 1), fz = uz - Float(iz)
                return SIMD3<Float>(
                    ptr[ix].x + (ptr[ix + 1].x - ptr[ix].x) * fx,
                    ptr[iy].y + (ptr[iy + 1].y - ptr[iy].y) * fy,
                    ptr[iz].z + (ptr[iz + 1].z - ptr[iz].z) * fz)
            }

            @inline(__always)
            func evaluateFast(scaledRaw: SIMD3<Float>) -> SIMD3<Float> {
                let logRaw = SIMD3<Float>(
                    log10f(max(scaledRaw.x, 0) + 1e-10),
                    log10f(max(scaledRaw.y, 0) + 1e-10),
                    log10f(max(scaledRaw.z, 0) + 1e-10))
                var density = Self.sample1D(filmPtr, last: filmLast, logMin: filmLogMin, invSpan: filmLogInvSpan, v: logRaw)
                if hasCouplers {
                    let silver = couplerPositive ? couplerMax - density : density
                    let inhib = couplerRow0 * silver.x + couplerRow1 * silver.y + couplerRow2 * silver.z
                    density = Self.sample1D(couplerPtr, last: couplerLast, logMin: couplerLogMin, invSpan: couplerLogInvSpan, v: logRaw - inhib)
                }
                let G = lutGrid
                let maxG = Float(G - 1)
                let ux = min(max((density.x - dMin.x) * dInvSpan.x, 0), maxG)
                let uy = min(max((density.y - dMin.y) * dInvSpan.y, 0), maxG)
                let uz = min(max((density.z - dMin.z) * dInvSpan.z, 0), maxG)
                let ix = min(Int(ux), G - 2), iy = min(Int(uy), G - 2), iz = min(Int(uz), G - 2)
                let fx = ux - Float(ix), fy = uy - Float(iy), fz = uz - Float(iz)
                let i00 = (iz * G + iy) * G + ix
                let i10 = i00 + G
                let i01 = i00 + G * G
                let i11 = i01 + G
                let c00 = densPtr[i00] + (densPtr[i00 + 1] - densPtr[i00]) * fx
                let c10 = densPtr[i10] + (densPtr[i10 + 1] - densPtr[i10]) * fx
                let c01 = densPtr[i01] + (densPtr[i01 + 1] - densPtr[i01]) * fx
                let c11 = densPtr[i11] + (densPtr[i11 + 1] - densPtr[i11]) * fx
                let c0 = c00 + (c10 - c00) * fy
                let c1 = c01 + (c11 - c01) * fy
                return c0 + (c1 - c0) * fz
            }

            @inline(__always)
            func burnTransfer(burn B: SIMD3<Double>) -> SIMD3<Float> {
                let burnRaw = neutralScaled * SIMD3<Float>(Float(B.x), Float(B.y), Float(B.z))
                let RB = evaluateFast(scaledRaw: burnRaw)
                return SIMD3<Float>(
                    abs(span.x) > 1e-5 ? min(max((RB.x - rebateUnburned.x) * invSpan.x, 0), 1) : 0,
                    abs(span.y) > 1e-5 ? min(max((RB.y - rebateUnburned.y) * invSpan.y, 0), 1) : 0,
                    abs(span.z) > 1e-5 ? min(max((RB.z - rebateUnburned.z) * invSpan.z, 0), 1) : 0)
            }

            @inline(__always)
            func apply(center C: SIMD3<Float>, scene S: SIMD3<Float>, burn B: SIMD3<Double>) -> SIMD3<Float> {
                let burnVec = SIMD3<Float>(Float(B.x), Float(B.y), Float(B.z))
                let burnRaw = neutralScaled * burnVec
                let RB = evaluateFast(scaledRaw: burnRaw)
                let sceneRaw = cameraRaw(S) * sceneScale
                let MB = evaluateFast(scaledRaw: sceneRaw + burnRaw)
                let M0 = evaluateFast(scaledRaw: sceneRaw)
                let t = SIMD3<Float>(
                    abs(span.x) > 1e-5 ? min(max((RB.x - rebateUnburned.x) * invSpan.x, 0), 1) : 0,
                    abs(span.y) > 1e-5 ? min(max((RB.y - rebateUnburned.y) * invSpan.y, 0), 1) : 0,
                    abs(span.z) > 1e-5 ? min(max((RB.z - rebateUnburned.z) * invSpan.z, 0), 1) : 0)
                let raw = MB + (C - M0) * (SIMD3<Float>(repeating: 1) - t)
                let lo = simd_min(C, simd_min(MB, rebateSaturated))
                let hi = simd_max(C, simd_max(MB, rebateSaturated))
                return simd_clamp(raw, lo, hi)
            }

            @inline(__always)
            func applyBody(center C: SIMD3<Float>, scene S: SIMD3<Float>, burn B: SIMD3<Float>, bodyT t: SIMD3<Float>) -> SIMD3<Float> {
                let sceneRaw = cameraRaw(S) * sceneScale
                let MB = evaluateFast(scaledRaw: sceneRaw + neutralScaled * B)
                if t.x >= 0.99999 && t.y >= 0.99999 && t.z >= 0.99999 {
                    let lo = simd_min(C, simd_min(MB, rebateSaturated))
                    let hi = simd_max(C, simd_max(MB, rebateSaturated))
                    return simd_clamp(MB, lo, hi)
                }
                let M0 = evaluateFast(scaledRaw: sceneRaw)
                let raw = MB + (C - M0) * (SIMD3<Float>(repeating: 1) - t)
                let lo = simd_min(C, simd_min(MB, rebateSaturated))
                let hi = simd_max(C, simd_max(MB, rebateSaturated))
                return simd_clamp(raw, lo, hi)
            }
        }

        func withSampler<T>(_ body: (Sampler) throws -> T) rethrows -> T {
            let span = rebateSaturated - rebateUnburned
            let invSpan = SIMD3<Float>(
                abs(span.x) > 1e-5 ? 1.0 / span.x : 0,
                abs(span.y) > 1e-5 ? 1.0 / span.y : 0,
                abs(span.z) > 1e-5 ? 1.0 / span.z : 0)
            return try exposureTable.withUnsafeBufferPointer { expBuf in
                try filmCurveLUT.withUnsafeBufferPointer { filmBuf in
                    try densityLUT.withUnsafeBufferPointer { densBuf in
                        try couplerCurveLUT.withUnsafeBufferPointer { coupBuf in
                            let filmPtr = filmBuf.baseAddress!
                            let sampler = Sampler(
                                basis0: basis0, basis1: basis1, basis2: basis2,
                                exposureTableSize: exposureTableSize, expPtr: expBuf.baseAddress!,
                                sceneScale: sceneScale, neutralScaled: neutralScaled,
                                filmLast: filmCurveLUT.count - 1, filmLogMin: filmLogMin, filmLogInvSpan: filmLogInvSpan,
                                filmPtr: filmPtr,
                                hasCouplers: hasCouplers, couplerPositive: couplerPositive, couplerMax: couplerMax,
                                couplerRow0: couplerRow0, couplerRow1: couplerRow1, couplerRow2: couplerRow2,
                                couplerLast: max(couplerCurveLUT.count - 1, 1),
                                couplerLogMin: couplerLogMin, couplerLogInvSpan: couplerLogInvSpan,
                                couplerPtr: coupBuf.baseAddress ?? filmPtr,
                                lutGrid: lutGrid, dMin: dMin, dInvSpan: dInvSpan, densPtr: densBuf.baseAddress!,
                                rebateUnburned: rebateUnburned, rebateSaturated: rebateSaturated,
                                span: span, invSpan: invSpan)
                            return try body(sampler)
                        }
                    }
                }
            }
        }
    }

    static func applyMaterialBurn(
        _ center: CGImage, scene: SourceImageRenderer.Input,
        geometry: FilmEdgeGeometry, response: MaterialBurnResponse,
        filmBounds: (minX: Double, maxX: Double, minY: Double, maxY: Double)? = nil,
        isCancelled: (@Sendable () -> Bool)? = nil
    ) throws -> CGImage {
        let d = geometry.distress
        guard d.leakShape == .burn, d.leak > 0, geometry.burnFrontDepth > -50 else { return center }
        let w = center.width, h = center.height
        let bounds = filmBounds ?? (
            minX: -geometry.supportHalf.x, maxX: geometry.supportHalf.x,
            minY: -geometry.supportHalf.y, maxY: geometry.supportHalf.y)
        let spanX = bounds.maxX - bounds.minX
        let spanY = bounds.maxY - bounds.minY
        let inStore = scene.store
        let halfScene = inStore?.format == .half
        nonisolated(unsafe) let rawScene = inStore?.base
        let sceneW = scene.width, sceneH = scene.height
        let workingFormat = RenderPrecision.resolved.ciFormat
        let bands = max(1, min(h, ProcessInfo.processInfo.activeProcessorCount * 4))
        let leak = geometry.leakFrame
        let frontSize = geometry.burnFrontDepth
        let burnCutoff = frontSize + 3.4
        let burnBodyCutoff = frontSize - 3.6
        let fxStep = spanX / Double(w)
        let fx0 = bounds.minX + 0.5 * fxStep
        let dStepX = fxStep * leak.normal.0
        let peakD = geometry.burnPeak
        let peakF = SIMD3<Float>(repeating: Float(peakD))

        return try response.withSampler { sampler in
            let bodyT = sampler.burnTransfer(burn: SIMD3<Double>(repeating: peakD))
            return try scene.pixels.withUnsafeBufferPointer { arrayBuffer in
                nonisolated(unsafe) let arrayPtr = arrayBuffer.baseAddress
                @inline(__always) func sampleSceneIndex(_ index: Int) -> SIMD3<Float> {
                    let p: SIMD4<Float>
                    if let rawScene {
                        p = halfScene
                            ? halfPixel(rawScene.assumingMemoryBound(to: SIMD4<UInt16>.self)[index])
                            : rawScene.assumingMemoryBound(to: SIMD4<Float>.self)[index]
                    } else {
                        p = arrayPtr![index]
                    }
                    return SIMD3(p.x, p.y, p.z)
                }
                @inline(__always) func sampleScene(x: Int, y: Int) -> SIMD3<Float> {
                    if sceneW == w && sceneH == h {
                        return sampleSceneIndex(y * w + x)
                    }
                    let sx = min(max((Double(x) + 0.5) / Double(w) * Double(sceneW) - 0.5, 0), Double(sceneW - 1))
                    let sy = min(max((Double(y) + 0.5) / Double(h) * Double(sceneH) - 0.5, 0), Double(sceneH - 1))
                    let x0 = Int(sx), x1 = min(x0 + 1, sceneW - 1), fx = Float(sx - Double(x0))
                    let y0 = Int(sy), y1 = min(y0 + 1, sceneH - 1), fy = Float(sy - Double(y0))
                    let a = sampleSceneIndex(y0 * sceneW + x0) * (1 - fx) + sampleSceneIndex(y0 * sceneW + x1) * fx
                    let b = sampleSceneIndex(y1 * sceneW + x0) * (1 - fx) + sampleSceneIndex(y1 * sceneW + x1) * fx
                    return a * (1 - fy) + b * fy
                }

                if PixelStore.isLarge(width: w, height: h) {
                    let store = try PixelStore.render(
                        PixelStore.ciImage(center), width: w, height: h,
                        context: context, colorSpace: linear, format: .working)
                    DispatchQueue.concurrentPerform(iterations: bands) { band in
                        var row = [SIMD4<Float>](repeating: .zero, count: w)
                        row.withUnsafeMutableBufferPointer { buf in
                            let rowPtr = buf.baseAddress!
                            for y in (band * h / bands)..<((band + 1) * h / bands) {
                                if (y & 15) == 0, isCancelled?() == true { return }
                                let fy = bounds.minY + (Double(y) + 0.5) / Double(h) * spanY
                                let dFirst = (fx0 - leak.point.0) * leak.normal.0 + (fy - leak.point.1) * leak.normal.1
                                let dLast = dFirst + Double(w - 1) * dStepX
                                if min(dFirst, dLast) >= burnCutoff { continue }
                                store.read(x: 0, y: y, width: w, height: 1, into: rowPtr)
                                var changed = false
                                for x in 0..<w {
                                    let depth = dFirst + Double(x) * dStepX
                                    if depth >= burnCutoff { continue }
                                    let c = rowPtr[x]
                                    let lit: SIMD3<Float>
                                    if depth <= burnBodyCutoff {
                                        lit = sampler.applyBody(center: SIMD3(c.x, c.y, c.z), scene: sampleScene(x: x, y: y), burn: peakF, bodyT: bodyT)
                                    } else {
                                        let burn = geometry.burnLightAt(filmX: fx0 + Double(x) * fxStep, filmY: fy)
                                        if burn == .zero { continue }
                                        lit = sampler.apply(center: SIMD3(c.x, c.y, c.z), scene: sampleScene(x: x, y: y), burn: burn)
                                    }
                                    rowPtr[x] = SIMD4(lit.x, lit.y, lit.z, c.w)
                                    changed = true
                                }
                                if changed {
                                    store.write(x: 0, y: y, width: w, height: 1, from: rowPtr, sourceRowBytes: w * 16)
                                }
                            }
                        }
                    }
                    if isCancelled?() == true { throw CancellationError() }
                    try Task.checkCancellation()
                    return try store.image(colorSpace: linear)
                }

                var pixels = [SIMD4<Float>](repeating: .zero, count: w * h)
                pixels.withUnsafeMutableBytes {
                    context.render(
                        PixelStore.ciImage(center), toBitmap: $0.baseAddress!, rowBytes: w * 16,
                        bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBAf, colorSpace: linear)
                }
                pixels.withUnsafeMutableBufferPointer { buf in
                    nonisolated(unsafe) let out = buf.baseAddress!
                    DispatchQueue.concurrentPerform(iterations: bands) { band in
                        for y in (band * h / bands)..<((band + 1) * h / bands) {
                            if (y & 15) == 0, isCancelled?() == true { return }
                            let fy = bounds.minY + (Double(y) + 0.5) / Double(h) * spanY
                            let dFirst = (fx0 - leak.point.0) * leak.normal.0 + (fy - leak.point.1) * leak.normal.1
                            let dLast = dFirst + Double(w - 1) * dStepX
                            if min(dFirst, dLast) >= burnCutoff { continue }
                            let rowOff = y * w
                            for x in 0..<w {
                                let depth = dFirst + Double(x) * dStepX
                                if depth >= burnCutoff { continue }
                                let c = out[rowOff + x]
                                let lit: SIMD3<Float>
                                if depth <= burnBodyCutoff {
                                    lit = sampler.applyBody(center: SIMD3(c.x, c.y, c.z), scene: sampleScene(x: x, y: y), burn: peakF, bodyT: bodyT)
                                } else {
                                    let burn = geometry.burnLightAt(filmX: fx0 + Double(x) * fxStep, filmY: fy)
                                    if burn == .zero { continue }
                                    lit = sampler.apply(center: SIMD3(c.x, c.y, c.z), scene: sampleScene(x: x, y: y), burn: burn)
                                }
                                out[rowOff + x] = SIMD4(lit.x, lit.y, lit.z, c.w)
                            }
                        }
                    }
                }
                if isCancelled?() == true { throw CancellationError() }
                try Task.checkCancellation()
                let data = pixels.withUnsafeBytes { Data($0) }
                let bitmap = CIImage(
                    bitmapData: data, bytesPerRow: w * 16, size: CGSize(width: w, height: h),
                    format: .RGBAf, colorSpace: linear)
                guard let image = context.createCGImage(
                    bitmap, from: CGRect(x: 0, y: 0, width: w, height: h),
                    format: workingFormat, colorSpace: linear, deferred: false)
                else { throw PhotoExporter.Failure.render }
                return image
            }
        }
    }
}
