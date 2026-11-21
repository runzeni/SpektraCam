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
                .workingColorSpace: linear, .workingFormat: CIFormat.RGBAh,
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
        let mm = geometry.millimetersPerPixel
        let cx = Double(geometry.width) / 2, cy = Double(geometry.height) / 2
        let bands = max(1, min(height / 32, ProcessInfo.processInfo.activeProcessorCount * 4))
        let inStore = input.store
        let halfSource = inStore?.format == .half
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
                    let px = cx + fx / mm, py = cy + fy / mm
                    let sx = min(max((px - geometry.gate.minX) / geometry.gate.width * Double(input.width) - 0.5, 0), Double(input.width - 1))
                    let sy = min(max((py - geometry.gate.minY) / geometry.gate.height * Double(input.height) - 0.5, 0), Double(input.height - 1))
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
                                paperPrint: Bool = true) throws -> CGImage {
        let rect = geometry.gate
        let gate = CGRect(x: rect.minX, y: Double(geometry.height) - rect.maxY, width: rect.width, height: rect.height)
        let angle = geometry.distress.tilt * .pi / 180
        let mid = CGPoint(x: Double(geometry.width) / 2, y: Double(geometry.height) / 2)
        // Clamp first: the soft, worn or bulged gate may open past the nominal rectangle, and a
        // transparent photo border would blend in as a dark seam.
        let photograph = PixelStore.ciImage(center).clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: gate.width / Double(center.width), y: gate.height / Double(center.height)))
            .transformed(by: CGAffineTransform(translationX: gate.minX, y: gate.minY))
            .transformed(by: CGAffineTransform(translationX: -mid.x, y: -mid.y)
                .concatenating(CGAffineTransform(rotationAngle: -angle))  // y-up: film turns clockwise for +tilt
                .concatenating(CGAffineTransform(translationX: mid.x, y: mid.y)))
        let canvas = CGRect(x: 0, y: 0, width: geometry.width, height: geometry.height)
        let mask = try gateCoverageMap(geometry)
        let result = photograph.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: PixelStore.ciImage(edge), kCIInputMaskImageKey: try gateMask(mask, geometry)])
            .cropped(to: canvas)
        let needsPass = needsCenterPass(geometry)
        if PixelStore.isLarge(width: geometry.width, height: geometry.height) {
            // Composite into file-backed storage and lay the damage over it in place.
            let store = try PixelStore.render(
                result, width: geometry.width, height: geometry.height, context: context,
                colorSpace: linear)
            if needsPass {
                try applyCenterDamage(store, mask: mask, geometry: geometry, paperPrint: paperPrint)
            }
            return try store.image(colorSpace: linear)
        }
        let workingFormat = RenderPrecision.resolved.ciFormat
        guard needsPass else {
            guard let image = context.createCGImage(result, from: canvas, format: workingFormat, colorSpace: linear, deferred: false)
            else { throw PhotoExporter.Failure.render }
            return image
        }
        let w = geometry.width, h = geometry.height
        var pixels = [SIMD4<Float>](repeating: .zero, count: w * h)
        pixels.withUnsafeMutableBytes {
            context.render(result, toBitmap: $0.baseAddress!, rowBytes: w * 16, bounds: canvas, format: .RGBAf, colorSpace: linear)
        }
        try pixels.withUnsafeMutableBufferPointer {
            try applyCenterDamage(&$0, mask: mask, geometry: geometry, paperPrint: paperPrint)
        }
        let data = pixels.withUnsafeBytes { Data($0) }
        let damaged = CIImage(bitmapData: data, bytesPerRow: w * 16, size: CGSize(width: w, height: h), format: .RGBAf, colorSpace: linear)
        guard let image = context.createCGImage(damaged, from: canvas, format: workingFormat, colorSpace: linear, deferred: false)
        else { throw PhotoExporter.Failure.render }
        return image
    }

    static func needsCenterPass(_ geometry: FilmEdgeGeometry) -> Bool {
        let d = geometry.distress
        return d.dust > 0 || (d.scratches > 0 && d.scratchesInImage)
    }

    /// Unwanted light is exposure, so a creative centre receives it before its LUT or tone: the
    /// same front/back leak and fog fields the film graph uses, in its mid-grey units, added to
    /// the framed source (one pixel per gate position, film millimetres from the frame centre).
    /// The source is display-developed: linear (mid grey 0.184 per unit) up to a knee, then an
    /// exponential shoulder, so added light lifts shadows and mid-tones in proportion to exposure
    /// and highlights saturate instead of clipping.
    static func exposeCenter(_ input: SourceImageRenderer.Input, geometry: FilmEdgeGeometry) throws
        -> SourceImageRenderer.Input
    {
        let d = geometry.distress
        guard d.leak > 0 || d.edgeFog > 0 else { return input }
        let w = input.width, h = input.height
        let one = SIMD3<Double>(repeating: 1)
        let lt = geometry.leakLight(neutral: one), ft = geometry.fogLight(neutral: one)
        let ct = geometry.coreLight(neutral: one)
        let leakTint = SIMD3<Float>(Float(lt.x), Float(lt.y), Float(lt.z))
        let fogTint = SIMD3<Float>(Float(ft.x), Float(ft.y), Float(ft.z))
        let coreTint = SIMD3<Float>(Float(ct.x), Float(ct.y), Float(ct.z))
        let knee: Float = 0.5, room = 1 - knee
        func linearized(_ v: Float) -> Float { v < knee ? v : knee - room * log((1 - v) / room) }
        func shouldered(_ y: Float) -> Float { y < knee ? y : 1 - room * exp(-(y - knee) / room) }
        let mm = geometry.millimetersPerPixel, gate = geometry.gate
        let cx = Double(geometry.width) / 2, cy = Double(geometry.height) / 2
        func expose(_ out: UnsafeMutablePointer<SIMD4<Float>>) throws {
            let bands = max(1, min(h, ProcessInfo.processInfo.activeProcessorCount * 4))
            nonisolated(unsafe) let out = out
            DispatchQueue.concurrentPerform(iterations: bands) { band in
                for y in (band * h / bands)..<((band + 1) * h / bands) {
                    let py = gate.minY + (Double(y) + 0.5) / Double(h) * gate.height
                    for x in 0..<w {
                        let px = gate.minX + (Double(x) + 0.5) / Double(w) * gate.width
                        let e = geometry.exposureFields(filmX: (px - cx) * mm, filmY: (py - cy) * mm)
                        let light = leakTint * Float(e.front + e.back) + fogTint * Float(e.fog) + coreTint * Float(e.core)
                        if light == .zero { continue }
                        let p = out[y * w + x], v = SIMD3(p.x, p.y, p.z)
                        let c = simd_clamp(v, .zero, SIMD3(repeating: 0.999))
                        let lifted = SIMD3(linearized(c.x), linearized(c.y), linearized(c.z)) + 0.184 * light
                        let lit = v + SIMD3(shouldered(lifted.x), shouldered(lifted.y), shouldered(lifted.z)) - c
                        out[y * w + x] = SIMD4(lit.x, lit.y, lit.z, p.w)
                    }
                }
            }
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
                        store.read(x: 0, y: y, width: w, height: 1, into: buf.baseAddress!)
                        let py = gate.minY + (Double(y) + 0.5) / Double(h) * gate.height
                        for x in 0..<w {
                            let px = gate.minX + (Double(x) + 0.5) / Double(w) * gate.width
                            let e = geometry.exposureFields(filmX: (px - cx) * mm, filmY: (py - cy) * mm)
                            let light = leakTint * Float(e.front + e.back) + fogTint * Float(e.fog) + coreTint * Float(e.core)
                            if light == .zero { continue }
                            let p = buf[x], v = SIMD3(p.x, p.y, p.z)
                            let c = simd_clamp(v, .zero, SIMD3(repeating: 0.999))
                            let lifted = SIMD3(linearized(c.x), linearized(c.y), linearized(c.z)) + 0.184 * light
                            let lit = v + SIMD3(shouldered(lifted.x), shouldered(lifted.y), shouldered(lifted.z)) - c
                            buf[x] = SIMD4(lit.x, lit.y, lit.z, p.w)
                        }
                        copy.write(x: 0, y: y, width: w, height: 1, from: buf.baseAddress!, sourceRowBytes: w * 16)
                    }
                }
            }
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
        let crossing = geometry.distress.scratchesInImage && geometry.distress.scratches > 0
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
                        let dust = Float(geometry.dustOcclusion(x: x, y: y)) * g
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
    static func applyCenterDamage(_ pixels: inout UnsafeMutableBufferPointer<SIMD4<Float>>, mask: [Float],
                                  geometry: FilmEdgeGeometry, paperPrint: Bool) throws {
        let w = geometry.width, h = geometry.height
        let paperWhite = SIMD3<Float>(repeating: 0.8), scanLight = SIMD3<Float>(repeating: 0.77)
        let sw = FilmEdgeGeometry.scatterWeights, weights = SIMD3<Float>(Float(sw.x), Float(sw.y), Float(sw.z))
        let crossing = geometry.distress.scratchesInImage && geometry.distress.scratches > 0
        let bands = max(1, min(h, ProcessInfo.processInfo.activeProcessorCount * 4))
        do {
            nonisolated(unsafe) let out = pixels.baseAddress!
            DispatchQueue.concurrentPerform(iterations: bands) { band in
                for y in (band * h / bands)..<((band + 1) * h / bands) {
                    for x in 0..<w {
                        let g = mask[y * w + x]
                        if g <= 0 { continue }
                        let p = out[y * w + x]
                        var v = SIMD3(p.x, p.y, p.z)
                        let scratch = crossing ? geometry.scratchFields(x: x, y: y) : FilmEdgeGeometry.ScratchFields()
                        let dust = Float(geometry.dustOcclusion(x: x, y: y)) * g
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

    /// Gate coverage per pixel; only pixels near the aperture boundary evaluate the edge.
    static func gateCoverageMap(_ geometry: FilmEdgeGeometry) throws -> [Float] {
        let w = geometry.width, h = geometry.height
        var values = [Float](repeating: 0, count: w * h)
        let margin = Int(ceil((geometry.distress.gateWear + geometry.distress.gateSoftness) / geometry.millimetersPerPixel)) + 3
        let tilt = Int(ceil(abs(sin(geometry.distress.tilt * .pi / 180)) * Double(max(w, h)))) + margin
        let inner = geometry.gate.insetBy(dx: Double(tilt), dy: Double(tilt))
        let outer = geometry.gate.insetBy(dx: -Double(tilt), dy: -Double(tilt))
        let bands = max(1, min(h / 16, ProcessInfo.processInfo.activeProcessorCount * 4))
        values.withUnsafeMutableBufferPointer { buffer in
            nonisolated(unsafe) let out = buffer.baseAddress!
            DispatchQueue.concurrentPerform(iterations: bands) { band in
                for y in (band * h / bands)..<((band + 1) * h / bands) {
                    for x in 0..<w {
                        let p = CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)
                        out[y * w + x] = inner.contains(p) ? 1 : outer.contains(p) ? Float(geometry.gateCoverage(x: x, y: y)) : 0
                    }
                }
            }
        }
        try Task.checkCancellation()
        return values
    }
    static func gateMask(_ values: [Float], _ geometry: FilmEdgeGeometry) throws -> CIImage {
        let bytes = values.map { UInt8((min(max($0, 0), 1) * 255).rounded()) }
        // Like CIImage(cgImage:), the first bitmap row is the top of the canvas.
        return CIImage(bitmapData: Data(bytes), bytesPerRow: geometry.width,
                       size: CGSize(width: geometry.width, height: geometry.height), format: .L8, colorSpace: nil)
    }
}
