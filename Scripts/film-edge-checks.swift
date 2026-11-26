import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

@main struct FilmEdgeChecks {
    typealias RGB = SIMD3<Double>
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let directory = root.appendingPathComponent("SpektraCam/Resources/ModelData")
        let library = try ModelLibrary(directory: directory)
        let gpu = try MetalFilmPipeline(sources: ["ColorPipeline", "Spatial", "Grain", "Diffusion", "FilmPipeline"].map {
            try String(contentsOf: directory.appendingPathComponent($0 + ".metalSource"), encoding: .utf8)
        })
        var recipe = EditRecipe()
        recipe.filmID = "fujifilm_c200"
        recipe.printID = "fujifilm_crystal_archive_typeii"
        recipe.look.enabled = true
        recipe.flags["camera.auto_exposure"] = false
        recipe.flags["print_render.glare.active"] = false
        recipe.numbers["scanner.lens_blur"] = 0
        recipe.numbers["scanner.unsharp_mask[1]"] = 0
        recipe.filmEdgeLayout = FilmEdgeLayout()
        var selection = FilmEdgeSelection()
        selection.mode = .manual
        // Exact geometry assertions use the Precise gate (no tilt or bulge); gate types are checked separately.
        var exact = FilmEdgeLayout(); exact.gate = FilmEdgeGate(.precise)
        let geometry = FilmEdgeGeometry(imageSize: CGSize(width: 600, height: 400), layout: exact, longEdge: 256)!
        precondition(abs(FilmEdgeGeometry.holeCenter - 14.0805) < 1e-9)
        precondition(abs(FilmEdgeGeometry.holeCenter - FilmEdgeGeometry.holeAcross / 2 - 12 - 0.6835) < 1e-9,
            "The nominal stock-edge gap was mistaken for a hole-center inset")
        let pitch = geometry.pixelPitchMicrometers
        precondition(abs(pitch * geometry.gate.width - 36000) < 1e-9)
        precondition(geometry.width == 256 && geometry.height == 171, "Scan canvas \(geometry.width)×\(geometry.height)")
        var runs = 0, inHole = false
        for x in 0..<geometry.width {
            let hole = geometry.supportCoverage(x: x, y: 0) < 1
            if hole && !inHole { runs += 1 }
            inHole = hole
        }
        // The scan window (frame / scan framing) spans this many KS pitches, plus partial holes at its ends.
        let pitches = Double(geometry.width) * geometry.millimetersPerPixel / FilmEdgeGeometry.Perforation.ks1870.pitch
        precondition(runs >= Int(pitches) && runs <= Int(pitches) + 2, "135 registration: \(runs) holes across \(pitches) pitches")
        let input = (0..<geometry.width * geometry.height).map { i in
            SIMD4<Float>(Float(i % geometry.width) / Float(geometry.width) * 0.5 + 0.02, 0.18, 0.1, 1)
        }
        let rgb = input.map { RGB(Double($0.x), Double($0.y), Double($0.z)) }
        var metered = recipe
        metered.flags["camera.auto_exposure"] = true
        let meteredPipeline = try FilmPipeline(library: library, recipe: metered)
        do {
            _ = try meteredPipeline.process(rgb, width: geometry.width, height: geometry.height, stochastic: false, edge: geometry)
            preconditionFailure("CPU metered the padded support instead of requiring scene metering")
        } catch SpectralCore.Failure.invalidShape {}
        do {
            _ = try await gpu.process(input, width: geometry.width, height: geometry.height, pipeline: meteredPipeline,
                stochastic: false, edge: geometry)
            preconditionFailure("Metal metered the padded support instead of requiring scene metering")
        } catch MetalFilmPipeline.Failure.invalidShape {}
        var maxError = 0.0
        for type in FilmEdgeType.allCases {
            selection.manualType = type
            recipe.filmEdgeSelection = selection
            let material = FilmEdgeRenderer.materialRecipe(recipe)
            let pipeline = try FilmPipeline(library: library, recipe: material)
            let cpu = try pipeline.process(rgb, width: geometry.width, height: geometry.height,
                stochastic: false, edge: geometry, autoExposureEV: 0)
            let metal = try await gpu.process(input, width: geometry.width, height: geometry.height,
                pipeline: pipeline, stochastic: false, autoExposureEV: 0, edge: geometry)
            for i in cpu.indices { for ch in 0..<3 {
                let error = abs(cpu[i][ch] - Double(metal.pixels[i][ch]))
                maxError = max(maxError, error)
                // Defaults now include seeded hole/holder noise; float vs double hashing differs slightly.
                precondition(error < 3e-4, "Edge CPU/Metal disagreement: \(type), \(i), \(ch): \(error)")
            }}
            let holes = cpu.indices.filter { geometry.supportCoverage(x: $0 % geometry.width, y: $0 / geometry.width) == 0
                && geometry.carrierCoverage(x: $0 % geometry.width, y: $0 / geometry.width) == 1 }
            precondition(!holes.isEmpty, "The narrow reveal lost every perforation sliver")
            if type == .negativePrint {
                for i in holes { precondition(cpu[i] == .zero && metal.pixels[i].x == 0 && metal.pixels[i].y == 0 && metal.pixels[i].z == 0,
                    "Negative-print clear openings did not define an exact black reference") }
            }
            if type != .negativePrint {
                let noisyA = try await gpu.process(input, width: geometry.width, height: geometry.height,
                    pipeline: pipeline, seed: 9, autoExposureEV: 0, edge: geometry)
                let noisyB = try await gpu.process(input, width: geometry.width, height: geometry.height,
                    pipeline: pipeline, seed: 71, autoExposureEV: 0, edge: geometry)
                // A hole carries no dye, but scanner glare spreads a little of its grainy surround into it.
                for i in holes {
                    let d = noisyA.pixels[i] - noisyB.pixels[i]
                    precondition(max(abs(d.x), abs(d.y), abs(d.z)) < 0.02, "Dye/grain appeared in an open hole")
                }
            }
            let hole = cpu[holes[holes.count / 2]]
            let rebate = cpu[(Int(geometry.gate.maxY) + 2) * geometry.width + geometry.width / 2]
            print("\(type): hole \(hole), intact rebate \(rebate)")
            if type == .negativePrint { precondition(hole.x + hole.y + hole.z < rebate.x + rebate.y + rebate.z) }
            if type == .reversalScan || type == .cinemaPrint { precondition(hole.x + hole.y + hole.z > rebate.x + rebate.y + rebate.z) }
        }
        var roll = FilmEdgeLayout(); roll.format = .roll120
        for size in [CGSize(width: 600, height: 400), CGSize(width: 400, height: 600), CGSize(width: 600, height: 600), CGSize(width: 1200, height: 200)] {
            for format in [FilmEdgeLayout(), roll] {
                let crop = format.constrainedCrop(CropSelection(), imageSize: size)
                let g = FilmEdgeGeometry(imageSize: crop.pixelRect(in: size).size, layout: format, longEdge: 512)!
                precondition(max(g.width, g.height) == 512)
                let expectedRatio = format.format == .roll120 ? 1 : (size.width >= size.height ? 1.5 : 1 / 1.5)
                precondition(abs(g.gate.width / g.gate.height - expectedRatio) < 1e-9)
                precondition(g.gate.minX > 0 && g.gate.minY > 0)
                if format.format == .roll120 {
                    for y in 0..<g.height { for x in 0..<g.width { precondition(g.supportCoverage(x: x, y: y) == 1) } }
                }
            }
        }
        precondition(FilmEdgeGeometry(imageSize: CGSize(width: 600, height: 600), layout: FilmEdgeLayout(), longEdge: 512) == nil,
            "An arbitrary photo ratio silently changed the physical film gate")
        print("PASS: verified KS placement, eight clipped perforations, fixed gates/portrait/120, CPU/Metal four-family agreement (max \(maxError)), transmission polarity and no dye/grain in holes")
        var optical = recipe
        selection.manualType = .negativeScan; optical.filmEdgeSelection = selection
        optical = FilmEdgeRenderer.materialRecipe(optical)
        optical.flags["film_render.dir_couplers.active"] = false
        optical.flags["camera.diffusion_filter.active"] = false
        optical.numbers["camera.lens_blur_um"] = 0
        optical.numbers["film_render.halation.halation_spatial_scale"] = 12
        optical.numbers["film_render.halation.scatter_spatial_scale"] = 12
        var light = Array(repeating: RGB(repeating: 0.001), count: geometry.width * geometry.height)
        let bx = geometry.width / 2, by = Int(ceil(geometry.gate.minY))
        for y in by..<(by + 3) { for x in (bx - 2)...(bx + 2) { light[y * geometry.width + x] = RGB(repeating: 8) } }
        optical.flags["film_render.halation.active"] = false
        let without = try FilmPipeline(library: library, recipe: optical).process(light, width: geometry.width, height: geometry.height,
            stochastic: false, edge: geometry, autoExposureEV: 0)
        optical.flags["film_render.halation.active"] = true
        let with = try FilmPipeline(library: library, recipe: optical).process(light, width: geometry.width, height: geometry.height,
            stochastic: false, edge: geometry, autoExposureEV: 0)
        let probe = (by - 2) * geometry.width + bx
        precondition(geometry.gateCoverage(x: bx, y: by - 2) == 0)
        precondition(abs(with[probe].x - without[probe].x) > 1e-5, "Halation did not expose intact rebate beyond the camera gate")
        print("PASS: exaggerated bright-edge optical probe exposes rebate only after the gate, without painting a universal halo")
        try await checkDistress(library: library, gpu: gpu, recipe: recipe, input: input)
        try await checkWorkflow(root: root, recipe: recipe)
    }

    static func checkDistress(library: ModelLibrary, gpu: MetalFilmPipeline, recipe base: EditRecipe,
                              input: [SIMD4<Float>]) async throws {
        let size = CGSize(width: 600, height: 400)
        // Precise gate by default (no tilt or bulge), so geometric assertions stay exact.
        func geometry(_ distress: FilmEdgeDistress, longEdge: Int = 256, format: FilmEdgeLayout.Format = .film35,
                      perforation: FilmEdgeGeometry.Perforation = .ks1870,
                      gate: FilmEdgeGate = FilmEdgeGate(.precise), zoom: Double = 0.985,
                      easel: PrintLayout? = nil, scanZoom: Double = 0.9) -> FilmEdgeGeometry {
            var layout = FilmEdgeLayout(); layout.format = format; layout.distress = distress; layout.gate = gate
            layout.printZoom = zoom; layout.scanZoom = scanZoom
            let image = format == .film35 ? size : CGSize(width: 600, height: 600)
            return FilmEdgeGeometry(imageSize: image, layout: layout, longEdge: longEdge, perforation: perforation, easel: easel)!
        }
        var all = FilmEdgeDistress.Preset.worn.values
        all.seed = 0xC0FFEE; all.carrierRoughness = 0.3; all.leak = 0.5; all.dust = 0.8; all.scratches = 0.9
        all.holeVariation = 1; all.edgeFog = 1; all.carrierReflection = 0.8
        all.scanHolder = true  // a negative in its holder unless a route says otherwise
        let rgb = input.map { RGB(Double($0.x), Double($0.y), Double($0.z)) }
        var selection = FilmEdgeSelection(); selection.mode = .manual
        var maxError = 0.0
        // CPU/Metal agreement with every node active, for every material route.
        var released = all; released.scratchesInImage = true; released.leakKind = .front; released.leakShape = .streak
        released.warmth = -0.5
        for (type, distress, perforation) in FilmEdgeType.allCases.map({ ($0, all, FilmEdgeGeometry.Perforation.ks1870) })
            + [(.cinemaPrint, released, .bh1866), (.negativeScan, released, .bh1866), (.negativePrint, released, .ks1870),
               (.reversalScan, { var f = released; f.leakShape = .flare; f.leakKind = .back; return f }(), .ks1870)] {
            selection.manualType = type
            var recipe = base; recipe.filmEdgeSelection = selection
            let pipeline = try FilmPipeline(library: library, recipe: FilmEdgeRenderer.materialRecipe(recipe))
            // The route's holder flags, as `renderedFilmEdgeLayout` sets them.
            var routed = distress
            routed.scanHolder = type == .invertedScan || type == .negativeScan; routed.invertedScan = type == .invertedScan
            let g = geometry(routed, perforation: perforation, gate: { var r = FilmEdgeGate(.loose); r.holderDetail = 1; return r }())
            let cpu = try pipeline.process(rgb, width: g.width, height: g.height, stochastic: false, edge: g, autoExposureEV: 0)
            let metal = try await gpu.process(input, width: g.width, height: g.height, pipeline: pipeline,
                stochastic: false, autoExposureEV: 0, edge: g)
            var bad = 0
            for i in cpu.indices { for ch in 0..<3 {
                let error = abs(cpu[i][ch] - Double(metal.pixels[i][ch]))
                maxError = max(maxError, error)
                if error > 1e-3 { bad += 1 }
            }}
            precondition(bad == 0, "Distress CPU/Metal disagreement on \(type): \(bad) values")
        }
        // Enlarger print on a hand-set easel: offset opening, square blades, rotated projection.
        do {
            var printed = all; printed.enlargerPrint = true
            var easel = PrintLayout(); easel.easelSeed = 9; easel.handSet = true
            selection.manualType = .negativePrint
            var recipe = base; recipe.filmEdgeSelection = selection
            let pipeline = try FilmPipeline(library: library, recipe: FilmEdgeRenderer.materialRecipe(recipe))
            let g = geometry(printed, gate: FilmEdgeGate(.loose), zoom: 0.92, easel: easel)
            precondition(g.easelOffset.x != 0 && g.easelOffset.y != 0, "Hand-set easel had no offset")
            // The opening sets this canvas's size: a smooth synthetic scene of its own.
            let scene = (0..<(g.width * g.height)).map { i -> SIMD4<Float> in
                let u = Float(i % g.width) / Float(g.width), v = Float(i / g.width) / Float(g.height)
                return SIMD4(0.05 + 0.4 * u, 0.1 + 0.3 * v, 0.2 + 0.2 * u * v, 1)
            }
            let cpu = try pipeline.process(scene.map { RGB(Double($0.x), Double($0.y), Double($0.z)) },
                                           width: g.width, height: g.height, stochastic: false, edge: g, autoExposureEV: 0)
            let metal = try await gpu.process(scene, width: g.width, height: g.height, pipeline: pipeline,
                stochastic: false, autoExposureEV: 0, edge: g)
            var bad = 0
            for i in cpu.indices { for ch in 0..<3 {
                let error = abs(cpu[i][ch] - Double(metal.pixels[i][ch]))
                maxError = max(maxError, error)
                if error > 1e-3 { bad += 1 }
            }}
            precondition(bad == 0, "Enlarger print CPU/Metal disagreement: \(bad) values")
        }
        // Negative scan: the print's positive inside the scanner holder. The holder blocks the light
        // and comes out light like paper, the thin rebate dark; no easel and no sheet by default.
        do {
            selection.manualType = .invertedScan
            var recipe = base; recipe.filmEdgeSelection = selection; recipe.filmEdgeLayout = FilmEdgeLayout()
            precondition(recipe.renderedFilmEdgeLayout?.distress.enlargerPrint == false && recipe.printedLayout == nil
                && recipe.printContent(canvas: size) == .scan, "Negative scan used an easel or a sheet")
            let pipeline = try FilmPipeline(library: library, recipe: FilmEdgeRenderer.materialRecipe(recipe))
            precondition(!FilmEdgeRenderer.materialRecipe(recipe).scanFilm, "Negative scan was not inverted")
            var held = FilmEdgeDistress(); held.scanHolder = true; held.invertedScan = true
            let g = geometry(held, longEdge: 1024, gate: FilmEdgeGate(.natural), scanZoom: 0.8)
            let scene = (0..<(g.width * g.height)).map { _ in RGB(0.18, 0.18, 0.18) }
            let out = try pipeline.process(scene, width: g.width, height: g.height, stochastic: false, edge: g, autoExposureEV: 0)
            let mm = g.millimetersPerPixel
            let holderRow = (0..<g.height).first { g.carrierCoverage(x: g.width / 2, y: $0) > 0.02 }! / 2
            let holder = out[holderRow * g.width + g.width / 2]
            let rebate = out[Int(g.gate.minY - 0.5 / mm) * g.width + g.width / 2]
            precondition(holder.sum() > 2.0 && rebate.sum() < 0.6 && holder.sum() > rebate.sum() + 1.5,
                         "Negative scan holder \(holder) not light against the rebate \(rebate)")
        }
        // Registration: the camera leaves the frame a little off centre among its holes, seeded and
        // bounded; the source holes move with it, a cinema print's own holes do not.
        do {
            var one = FilmEdgeDistress(); one.seed = 1
            var other = FilmEdgeDistress(); other.seed = 7
            let a = geometry(one, longEdge: 1024), b = geometry(other, longEdge: 1024)
            precondition(abs(a.registration) <= FilmEdgeGeometry.maxRegistration && abs(b.registration) <= FilmEdgeGeometry.maxRegistration
                && a.registration != b.registration, "Registration not seeded within ±0.3 mm: \(a.registration), \(b.registration)")
            var moved = 0, destinationMoved = 0
            for y in 0..<a.height { for x in stride(from: 0, to: a.width, by: 2) {
                if a.supportCoverage(x: x, y: y) != b.supportCoverage(x: x, y: y) { moved += 1 }
                if a.supportCoverage(x: x, y: y, destination: true) != b.supportCoverage(x: x, y: y, destination: true) { destinationMoved += 1 }
            }}
            precondition(moved > 0 && destinationMoved == 0, "Registration moved \(moved) source and \(destinationMoved) print pixels")
        }
        // Scan framing is the scanner's crop window; positive scans have no holder at all.
        do {
            let tight = geometry(FilmEdgeDistress(), longEdge: 1024, scanZoom: 1), wide = geometry(FilmEdgeDistress(), longEdge: 1024, scanZoom: 0.8)
            precondition(abs(Double(tight.width) * tight.millimetersPerPixel - 36) < 0.1
                && abs(Double(wide.width) * wide.millimetersPerPixel - 45) < 0.1, "Scan framing is not the frame over the zoom")
            for y in stride(from: 0, to: wide.height, by: 3) { for x in stride(from: 0, to: wide.width, by: 3) {
                precondition(wide.carrierCoverage(x: x, y: y) == 1, "A positive scan showed a holder")
            }}
            var held = FilmEdgeDistress(); held.scanHolder = true
            let g = geometry(held, longEdge: 1024, scanZoom: 0.8)
            precondition(g.carrierCoverage(x: g.width / 2, y: 0) < 0.05 && g.carrierCoverage(x: g.width / 2, y: g.height / 2) == 1,
                         "A negative scan lost its holder")
        }
        // Amount 0 is exactly the clean edge; positions do not move with strength.
        var muted = all; muted.amount = 0
        // Gate optics and hole variation are not scaled by Amount.
        var soft = FilmEdgeDistress(); soft.holeVariation = all.holeVariation; soft.seed = all.seed; soft.scanHolder = all.scanHolder
        let clean = geometry(FilmEdgeDistress()), zero = geometry(muted), softClean = geometry(soft)
        for y in 0..<clean.height { for x in 0..<clean.width {
            precondition(softClean.gateCoverage(x: x, y: y) == zero.gateCoverage(x: x, y: y)
                && zero.carrierCoverage(x: x, y: y) == softClean.carrierCoverage(x: x, y: y) && zero.dustOcclusion(x: x, y: y) == 0
                && zero.exposureFields(x: x, y: y).back == 0
                && zero.exposureFields(x: x, y: y).fog == softClean.exposureFields(x: x, y: y).fog
                && zero.carrierReflection(x: x, y: y) == 0
                && zero.supportCoverage(x: x, y: y) == softClean.supportCoverage(x: x, y: y), "Amount 0 was not the clean edge")
        }}
        var half = all; half.amount = 0.5
        let a = geometry(all), b = geometry(half)
        precondition(a.leakFrame.point == b.leakFrame.point && a.scratchCandidates.map(\.across) == b.scratchCandidates.map(\.across),
            "Strength reshuffled seeded features")
        var reseeded = all; reseeded.seed = 7
        precondition(geometry(reseeded).scratchCandidates.map(\.across) != a.scratchCandidates.map(\.across), "Seed had no effect")
        // Physical size, not pixels: dust and carrier area agree between 256 and 1024 pixels.
        func area(_ g: FilmEdgeGeometry, _ value: (FilmEdgeGeometry, Int, Int) -> Double) -> Double {
            var sum = 0.0
            for y in 0..<g.height { for x in 0..<g.width { sum += value(g, x, y) } }
            return sum * g.millimetersPerPixel * g.millimetersPerPixel
        }
        let small = geometry(all, longEdge: 256), large = geometry(all, longEdge: 1024)
        let dustSmall = area(small) { $0.dustOcclusion(x: $1, y: $2) }, dustLarge = area(large) { $0.dustOcclusion(x: $1, y: $2) }
        let carrierSmall = area(small) { 1 - $0.carrierCoverage(x: $1, y: $2) }, carrierLarge = area(large) { 1 - $0.carrierCoverage(x: $1, y: $2) }
        precondition(dustLarge > 0 && abs(dustSmall / dustLarge - 1) < 0.25, "Dust area depends on resolution: \(dustSmall) vs \(dustLarge) mm²")
        precondition(abs(carrierSmall / carrierLarge - 1) < 0.08, "Carrier area depends on resolution: \(carrierSmall) vs \(carrierLarge) mm²")
        // Perforations keep full nominal size: without tilt the clean and distressed holes match.
        var straight = all; straight.tilt = 0; straight.holeVariation = 0
        let s = geometry(straight), nominal = geometry({ var n = FilmEdgeDistress(); n.holeVariation = 0; n.seed = straight.seed; return n }())
        for y in 0..<s.height { for x in 0..<s.width { precondition(s.supportCoverage(x: x, y: y) == nominal.supportCoverage(x: x, y: y)) } }
        // 120 has no sprockets, even when distressed.
        let roll = geometry(all, format: .roll120)
        for y in stride(from: 0, to: roll.height, by: 3) { for x in stride(from: 0, to: roll.width, by: 3) { precondition(roll.supportCoverage(x: x, y: y) == 1) } }
        // Opaque dust polarity follows the route: white specks on paper, dark specks in a slide scan.
        // The first seed that drops a speck inside the picture (dust is placed across the whole canvas).
        var dustIndex: Int?, best = 0.0, d = geometry(FilmEdgeDistress())
        for seed in UInt32(3)...40 where best <= 0.3 {
            var dusty = FilmEdgeDistress(); dusty.dust = 1; dusty.seed = seed
            d = geometry(dusty); best = 0
            for y in Int(d.gate.minY + 4)..<Int(d.gate.maxY - 4) { for x in Int(d.gate.minX + 4)..<Int(d.gate.maxX - 4) {
                let o = d.dustOcclusion(x: x, y: y); if o > best { best = o; dustIndex = y * d.width + x }
            }}
        }
        precondition(best > 0.3, "No visible dust particle in the test frame")
        let flat = Array(repeating: RGB(repeating: 0.12), count: d.width * d.height)
        for (type, brighter) in [(FilmEdgeType.negativePrint, true), (.reversalScan, false)] {
            selection.manualType = type
            var recipe = base; recipe.filmEdgeSelection = selection
            let pipeline = try FilmPipeline(library: library, recipe: FilmEdgeRenderer.materialRecipe(recipe))
            let dirty = try pipeline.process(flat, width: d.width, height: d.height, stochastic: false, edge: d, autoExposureEV: 0)
            let cleanOut = try pipeline.process(flat, width: d.width, height: d.height, stochastic: false, edge: clean, autoExposureEV: 0)
            let i = dustIndex!
            let delta = dirty[i].x + dirty[i].y + dirty[i].z - cleanOut[i].x - cleanOut[i].y - cleanOut[i].z
            precondition(brighter ? delta > 0.01 : delta < -0.01, "Dust polarity wrong for \(type): \(delta)")
        }
        // BH-1866 (cine negative) vs KS-1870: barrel-shaped, shorter along the strip, sharp corners.
        let ks = FilmEdgeGeometry.Perforation.ks1870, bh = FilmEdgeGeometry.Perforation.bh1866
        let c = FilmEdgeGeometry.holeCenter
        func at(_ p: FilmEdgeGeometry.Perforation, _ offset: Double, _ t: Double) -> Bool {
            p.isFilm(along: p.pitch / 2 + offset, across: c + t)
        }
        precondition(!at(ks, 0, 0) && !at(bh, 0, 0), "Perforation centres are not open")
        precondition(!at(ks, 0.95, 0) && at(bh, 0.95, 0), "BH is not 1.854 mm along the strip")
        precondition(!at(bh, 0.9, 1.0) && at(bh, 0.9, 1.25), "BH sides are not the 2.794 mm circle")
        precondition(!at(ks, 0, 1.38) && !at(bh, 0, 1.38) && at(bh, 0, 1.41), "Hole width C changed")
        precondition(abs(bh.pitch - 4.740) < 1e-12 && abs(ks.pitch - 4.750) < 1e-12)
        precondition(FilmEdgeGeometry.Perforation.source(filmID: "kodak_vision3_250d") == .bh1866
            && FilmEdgeGeometry.Perforation.source(filmID: "kodak_portra_400") == .ks1870)
        let bhGeometry = geometry(FilmEdgeDistress(), perforation: .bh1866)
        var bhRuns = 0, open = false
        for x in 0..<bhGeometry.width {
            let hole = bhGeometry.supportCoverage(x: x, y: 0) < 1
            if hole && !open { bhRuns += 1 }; open = hole
        }
        let bhPitches = Double(bhGeometry.width) * bhGeometry.millimetersPerPixel / bh.pitch
        precondition(bhRuns >= Int(bhPitches) && bhRuns <= Int(bhPitches) + 2, "BH strip: \(bhRuns) holes across \(bhPitches) pitches")
        // Scratches stay in the rebate unless released; then they may cross the picture.
        var scratched = FilmEdgeDistress(); scratched.scratches = 1; scratched.seed = 11
        func insideScratch(_ g: FilmEdgeGeometry) -> Double {
            var m = 0.0
            for y in Int(g.gate.minY + 3)..<Int(g.gate.maxY - 3) { for x in Int(g.gate.minX + 3)..<Int(g.gate.maxX - 3) {
                let f = g.scratchFields(x: x, y: y); m = max(m, f.scatter, f.removal.z)
            }}
            return m
        }
        precondition(insideScratch(geometry(scratched)) == 0, "Clamped scratches entered the picture")
        var free = scratched; free.scratchesInImage = true
        precondition(insideScratch(geometry(free, longEdge: 1024)) > 0.05, "Released scratches never crossed the picture")
        var rebateHit = 0.0
        let clamped = geometry(scratched, longEdge: 1024)
        for y in 0..<clamped.height { for x in 0..<clamped.width {
            let f = clamped.scratchFields(x: x, y: y); rebateHit = max(rebateHit, f.scatter, f.removal.z)
        }}
        precondition(rebateHit > 0.12, "Clamped scratches vanished or stayed too faint in the rebate: \(rebateHit)")
        // Scratches are anchored to the physical film strip, never sliding with print or scan zoom,
        // and clamped 135 scratches span both the inner rail land and the sprocket band while
        // open punched holes stay clear in transmission.
        let zoomTight = geometry(scratched, longEdge: 1024, zoom: 0.985, scanZoom: 1.0)
        let zoomWide = geometry(scratched, longEdge: 1024, zoom: 0.90, scanZoom: 0.78)
        precondition(
            zoomTight.scratchCandidates.map(\.across) == zoomWide.scratchCandidates.map(\.across)
                && zoomTight.scratchCandidates.map(\.start) == zoomWide.scratchCandidates.map(\.start),
            "Scratch positions drifted when changing print or scan zoom")
        precondition(
            clamped.scratchCandidates.allSatisfy { abs($0.across) >= 12.04 && abs($0.across) <= 14.65 },
            "Clamped 135 scratches fell outside physical rebate/sprocket band: \(clamped.scratchCandidates.map(\.across))")
        precondition(
            clamped.scratchCandidates.contains { abs($0.across) >= 12.6835 },
            "Expected some 135 scratches to traverse the sprocket zone: \(clamped.scratchCandidates.map(\.across))")
        // Cross-resolution leakFrame invariance at default leakPosition = 0.3 (landscape and portrait).
        for imageSize in [CGSize(width: 600, height: 400), CGSize(width: 400, height: 600)] {
            var baseBurn = FilmEdgeDistress(); baseBurn.leakShape = .burn; baseBurn.leak = 0.85
            var layout = FilmEdgeLayout(); layout.distress = baseBurn
            let ref = FilmEdgeGeometry(imageSize: imageSize, layout: layout, longEdge: 384)!.leakFrame
            for longEdge in [432, 540, 720, 1080, 2048, 2160, 4032, 5712, 8064] {
                let g = FilmEdgeGeometry(imageSize: imageSize, layout: layout, longEdge: longEdge)!.leakFrame
                precondition(g.point == ref.point && g.normal == ref.normal,
                    "leakFrame orientation changed between longEdge 384 and \(longEdge) for \(imageSize): \(ref.normal) vs \(g.normal)")
            }
        }
        // Burn emulation: fast 1D velvet plush lip, burnTexture 0...1 control, three-layer
        // spectral transition (white body -> golden-amber lip -> warm orange-red tail), and CPU/Metal parity.
        do {
            var burnDefault = FilmEdgeDistress(); burnDefault.leakShape = .burn; burnDefault.leak = 0.85
            let defaultData = try JSONEncoder().encode(burnDefault)
            precondition(
                String(data: defaultData, encoding: .utf8)?.contains("burnTexture") == false,
                "Default burnTexture bloated serialized recipe JSON")
            var burnFrayed = burnDefault; burnFrayed.burnTexture = 0.9; burnFrayed.leakPosition = 0.3
            let frayedData = try JSONEncoder().encode(burnFrayed)
            let decodedBurn = try JSONDecoder().decode(FilmEdgeDistress.self, from: frayedData)
            precondition(abs(decodedBurn.burnTexture - 0.9) < 1e-9, "Custom burnTexture did not round-trip")
            var burnSmooth = burnFrayed; burnSmooth.burnTexture = 0.0
            let gSmooth = geometry(burnSmooth, longEdge: 768)
            let gFrayed = geometry(burnFrayed, longEdge: 768)
            var diffSum = 0.0, sawBody = false, sawYellowCore = false, sawWarmTail = false
            for y in 0..<gFrayed.height {
                for x in stride(from: 0, to: gFrayed.width, by: 2) {
                    let es = gSmooth.exposureFields(x: x, y: y)
                    let ef = gFrayed.exposureFields(x: x, y: y)
                    diffSum += abs(es.burn.x - ef.burn.x) + abs(es.burn.y - ef.burn.y) + abs(es.burn.z - ef.burn.z)
                    if ef.burn.z > 40 { sawBody = true }
                    if ef.burn.z < 5 && ef.burn.y > 10 { sawYellowCore = true }
                    if ef.burn.z < 1 && ef.burn.y < 3 && ef.burn.x > 2 { sawWarmTail = true }
                }
            }
            precondition(diffSum > 25, "burnTexture had no measurable effect on the plush boundary: \(diffSum)")
            precondition(
                sawBody && sawYellowCore && sawWarmTail,
                "Burn lacked three-layer white/amber-lip/warm-tail separation: \(sawBody), \(sawYellowCore), \(sawWarmTail)")
            for tex in [0.1, 0.9] {
                for type in [FilmEdgeType.negativePrint, .invertedScan, .negativeScan] {
                    var burnCheck = burnFrayed; burnCheck.burnTexture = tex
                    burnCheck.scanHolder = type == .invertedScan || type == .negativeScan
                    burnCheck.invertedScan = type == .invertedScan
                    selection.manualType = type
                    var recipe = base; recipe.filmEdgeSelection = selection
                    let pipeline = try FilmPipeline(library: library, recipe: FilmEdgeRenderer.materialRecipe(recipe))
                    let gb = geometry(burnCheck, longEdge: 320)
                    let burnScene = Array(repeating: SIMD4<Float>(0.15, 0.18, 0.22, 1), count: gb.width * gb.height)
                    let cpuBurn = try pipeline.process(
                        burnScene.map { RGB(Double($0.x), Double($0.y), Double($0.z)) },
                        width: gb.width, height: gb.height, stochastic: false, edge: gb, autoExposureEV: 0)
                    let metalBurn = try await gpu.process(
                        burnScene, width: gb.width, height: gb.height, pipeline: pipeline,
                        stochastic: false, autoExposureEV: 0, edge: gb)
                    var badBurn = 0
                    for i in cpuBurn.indices {
                        for ch in 0..<3 {
                            let err = abs(cpuBurn[i][ch] - Double(metalBurn.pixels[i][ch]))
                            maxError = max(maxError, err)
                            if err > 1e-3 { badBurn += 1 }
                        }
                    }
                    precondition(badBurn == 0, "Burn CPU/Metal disagreement on \(type) at burnTexture=\(tex): \(badBurn) values")
                }
            }
        }
        // Scratch colour follows layer depth and route: a shallow emulsion cut (yellow layer) prints
        // yellow from a negative but shows blue on a slide; scatter prints light and bluish.
        func scratchSeed(_ wanted: (Double) -> Bool) -> UInt32 {
            for seed in UInt32(1)...4000 {
                var d = FilmEdgeDistress(); d.scratches = 1.0 / 16; d.scratchesInImage = true; d.seed = seed
                let first = geometry(d).scratchCandidates[0]
                if wanted(first.depth) && first.width > 0.011 && first.bias > 0.3 && abs(first.across) < 8 && first.start < -15 && first.end > 15 { return seed }
            }
            preconditionFailure("No suitable scratch seed")
        }
        for (label, wanted) in [("shallow", { (d: Double) in d > 0.08 && d < 0.3 }), ("scatter", { (d: Double) in d < -0.5 })] {
            var d = FilmEdgeDistress(); d.scratches = 1.0 / 16; d.scratchesInImage = true; d.seed = scratchSeed(wanted)
            let g = geometry(d, longEdge: 1024)
            var index = 0, best = 0.0
            for y in Int(g.gate.minY + 8)..<Int(g.gate.maxY - 8) { for x in Int(g.gate.minX + 8)..<Int(g.gate.maxX - 8) {
                let f = g.scratchFields(x: x, y: y); let v = max(f.scatter, f.removal.z)
                if v > best { best = v; index = y * g.width + x }
            }}
            precondition(best > 0.15, "Test scratch not found (\(label))")
            let neutral = Array(repeating: RGB(repeating: 0.12), count: g.width * g.height)
            let plain = geometry(FilmEdgeDistress(), longEdge: 1024)
            for type in [FilmEdgeType.negativePrint, .reversalScan] {
                selection.manualType = type
                var recipe = base; recipe.filmEdgeSelection = selection
                let pipeline = try FilmPipeline(library: library, recipe: FilmEdgeRenderer.materialRecipe(recipe))
                let dirty = try pipeline.process(neutral, width: g.width, height: g.height, stochastic: false, edge: g, autoExposureEV: 0)[index]
                let cleanPixel = try pipeline.process(neutral, width: g.width, height: g.height, stochastic: false, edge: plain, autoExposureEV: 0)[index]
                let delta = dirty - cleanPixel
                print("scratch \(label) \(type): Δ \(delta)")
                switch (label, type) {
                case ("shallow", .negativePrint): precondition(delta.z < delta.x - 0.005, "Shallow cut did not print yellow from a negative")
                case ("shallow", _): precondition(delta.z > delta.x + 0.005, "Shallow cut did not look blue on a slide")
                case (_, .negativePrint): precondition(delta.x + delta.y + delta.z > 0.01 && delta.z > delta.x, "Scatter did not print light and bluish")
                default: precondition(delta.x + delta.y + delta.z < -0.01, "Scatter did not darken a slide scan")
                }
            }
        }
        // Hole variation: each hole differs by a few microns (never resized); light piped through the
        // cut wall leaves a thin fog rim beside the holes only; still eight holes per frame.
        var varied = FilmEdgeDistress(); varied.holeVariation = 1; varied.seed = 5
        var still = FilmEdgeDistress(); still.holeVariation = 0
        let w = geometry(varied, longEdge: 1024), c0 = geometry(still, longEdge: 1024)
        var changed = 0, holeArea = 0.0, cleanArea = 0.0, runs = 0, inside = false, rimNear = 0.0, rimFar = 0.0
        for y in 0..<w.height { for x in 0..<w.width {
            let a = w.supportCoverage(x: x, y: y), b = c0.supportCoverage(x: x, y: y)
            if a != b { changed += 1 }; holeArea += 1 - a; cleanArea += 1 - b
            let rim = w.exposureFields(x: x, y: y).fog
            if abs(Double(y) - Double(w.height) / 2) < Double(w.height) * 0.3 { rimFar = max(rimFar, rim) } else { rimNear = max(rimNear, rim) }
        }}
        for x in 0..<w.width { let hole = w.supportCoverage(x: x, y: 2) < 1; if hole && !inside { runs += 1 }; inside = hole }
        let windowPitches = Double(w.width) * w.millimetersPerPixel / FilmEdgeGeometry.Perforation.ks1870.pitch
        precondition(changed > 20 && abs(holeArea / cleanArea - 1) < 0.03 && runs >= Int(windowPitches) && runs <= Int(windowPitches) + 2,
            "Hole variation: \(changed) px changed, area ratio \(holeArea / cleanArea), \(runs) holes")
        precondition(rimNear > 0.05 && rimFar == 0, "Hole rim misplaced: near \(rimNear), far \(rimFar)")
        // Sprockets stay pure clear/black whatever the leaks and fog do to the film around them.
        var stormy = FilmEdgeDistress.Preset.leaky.values; stormy.leak = 1; stormy.leakKind = .back
        stormy.edgeFog = 1; stormy.holeVariation = 1
        var quietLight = stormy; quietLight.leak = 0; quietLight.edgeFog = 0
        // Isolate the leak question from the holder edge.
        var bare = FilmEdgeGate(.precise); bare.holderBlur = 0; bare.holderDetail = 0
        let gs = geometry(stormy, longEdge: 768, gate: bare), calm = geometry(quietLight, longEdge: 768, gate: bare)
        let flatInput = Array(repeating: RGB(repeating: 0.1), count: gs.width * gs.height)
        for type in [FilmEdgeType.reversalScan, .cinemaPrint, .negativePrint, .negativeScan] {
            selection.manualType = type
            var recipe = base; recipe.filmEdgeSelection = selection
            let pipeline = try FilmPipeline(library: library, recipe: FilmEdgeRenderer.materialRecipe(recipe))
            let leaky = try pipeline.process(flatInput, width: gs.width, height: gs.height, stochastic: false, edge: gs, autoExposureEV: 0)
            let quiet = try pipeline.process(flatInput, width: gs.width, height: gs.height, stochastic: false, edge: calm, autoExposureEV: 0)
            var checked = 0
            let destination = type == .cinemaPrint
            func open(_ x: Int, _ y: Int) -> Bool {
                gs.supportCoverage(x: x, y: y) == 0 && (!destination || gs.supportCoverage(x: x, y: y, destination: true) == 0)
            }
            for y in 3..<(gs.height - 3) { for x in 3..<(gs.width - 3) where open(x, y) && gs.carrierCoverage(x: x, y: y) == 1 {
                // Away from the hole edge, so scanner blur of the surrounding film is excluded
                // (220 µm exponential veiling glare from burned white rebate stays within ~2e-3/ch).
                guard (-3...3).allSatisfy({ d in open(x + d, y) && open(x, y + d) }) else { continue }
                let i = y * gs.width + x
                precondition(abs((leaky[i] - quiet[i]).sum()) < 1e-2, "Leak or fog tinted an open sprocket on \(type): \(leaky[i]) vs \(quiet[i])")
                checked += 1
            }}
            precondition(checked > 10, "No interior sprocket pixels checked for \(type)")
        }
        // Perforation fog is hole-shaped exposure next to the holes, 135 only, never in the middle of the picture.
        var perfFog = FilmEdgeDistress(); perfFog.edgeFog = 1; perfFog.seed = 9  // edge fog drives perforation fog
        let pf = geometry(perfFog)
        var nearHoles = 0.0, middle = 0.0
        for y in 0..<pf.height { for x in 0..<pf.width {
            let v = pf.perforationFogExposure(x: x, y: y)
            if abs(Double(y) - Double(pf.height) / 2) < Double(pf.height) * 0.2 { middle = max(middle, v) } else { nearHoles = max(nearHoles, v) }
        }}
        precondition(nearHoles > 0.05 && middle == 0, "Perforation fog misplaced: edge \(nearHoles), middle \(middle)")
        precondition(geometry(perfFog, format: .roll120).perforationFogExposure(x: 3, y: 3) == 0, "120 grew perforation fog")
        // Front (through-the-lens) light is gated with the scene; a back leak reaches the rebate.
        var frontLeak = FilmEdgeDistress(); frontLeak.leak = 0.8; frontLeak.leakKind = .front; frontLeak.leakPosition = 0.125
        var backLeak = frontLeak; backLeak.leakKind = .back
        selection.manualType = .negativeScan
        var scanRecipe = base; scanRecipe.filmEdgeSelection = selection
        let scanPipeline = try FilmPipeline(library: library, recipe: FilmEdgeRenderer.materialRecipe(scanRecipe))
        let gF = geometry(frontLeak), gB = geometry(backLeak)
        let dark = Array(repeating: RGB(repeating: 0.002), count: gF.width * gF.height)
        let none = try scanPipeline.process(dark, width: gF.width, height: gF.height, stochastic: false, edge: clean, autoExposureEV: 0)
        let front = try scanPipeline.process(dark, width: gF.width, height: gF.height, stochastic: false, edge: gF, autoExposureEV: 0)
        let back = try scanPipeline.process(dark, width: gB.width, height: gB.height, stochastic: false, edge: gB, autoExposureEV: 0)
        let rebate = 2 * gF.width + gF.width / 2, picture = (Int(gF.gate.minY) + 4) * gF.width + gF.width / 2
        // Only scanner glare from the leaked picture reaches the rebate, not the leak itself.
        precondition(abs((front[rebate] - none[rebate]).sum()) < 5e-3, "Front leak exposed the rebate")
        precondition(abs((front[picture] - none[picture]).sum()) > 0.01, "Front leak did not expose the picture")
        precondition(abs((back[rebate] - none[rebate]).sum()) > 0.01, "Back leak did not reach the rebate")
        let cool = FilmEdgeGeometry.light(neutral: RGB(1, 1, 1), warmth: -1), warmLight = FilmEdgeGeometry.light(neutral: RGB(1, 1, 1), warmth: 1)
        precondition(cool.z > cool.x && warmLight.x > warmLight.z, "Front/back light colours swapped")
        // RA-4 holder: a reflective carrier edge darkens a band inside the opening; aged tape lightens and cools the print.
        selection.manualType = .negativePrint
        var printRecipe = base; printRecipe.filmEdgeSelection = selection
        let printPipeline = try FilmPipeline(library: library, recipe: FilmEdgeRenderer.materialRecipe(printRecipe))
        func printed(_ d: FilmEdgeDistress) throws -> (FilmEdgeGeometry, [RGB]) {
            var held = d; held.scanHolder = true
            let g = geometry(held)
            let grey = Array(repeating: RGB(repeating: 0.12), count: g.width * g.height)
            return (g, try printPipeline.process(grey, width: g.width, height: g.height, stochastic: false, edge: g, autoExposureEV: 0))
        }
        let (_, plainPrint) = try printed(FilmEdgeDistress())
        var reflective = FilmEdgeDistress(); reflective.carrierReflection = 1
        let (gr, reflectedPrint) = try printed(reflective)
        // The holder masks across the strip (open along it): the strongest darkening just inside its edge.
        let edgeRow = Int((Double(gr.height) / 2 - gr.carrierHalf.across / gr.millimetersPerPixel).rounded())
        var darkest = 0.0
        for y in max(0, edgeRow)..<min(gr.height, edgeRow + 12) { for x in 0..<gr.width {
            darkest = min(darkest, (reflectedPrint[y * gr.width + x] - plainPrint[y * gr.width + x]).sum())
        }}
        precondition(darkest < -0.002, "Carrier reflection did not darken the print edge: \(darkest)")
        var blurGate = FilmEdgeGate(.precise); blurGate.holderBlur = 0.3; blurGate.holderDetail = 0
        var inHolder = FilmEdgeDistress(); inHolder.scanHolder = true
        let gb = geometry(inHolder, longEdge: 1024, gate: blurGate)
        let column = gb.width / 2
        var previous = 1.0, partial = 0
        for y in 0..<Int(gb.gate.minY) {
            let c = gb.carrierCoverage(x: column, y: y)
            if c > 0.02 && c < 0.98 { partial += 1 }
            if y > 0 { precondition(c >= previous - 1e-9, "Holder blur is not monotonic toward the opening") }
            previous = c
        }
        precondition(partial > 8, "Holder edge is not visibly out of focus: \(partial) px")
        // Crisp core plus a faint tail: a few percent of light 0.3 mm past the opening, never a long ramp.
        var crisp = FilmEdgeGate(.precise); crisp.holderDetail = 0
        let gc = geometry(inHolder, longEdge: 1024, gate: crisp, scanZoom: 0.8)
        let tailRow = Int((Double(gc.height) / 2 - (gc.carrierHalf.across + 0.3) / gc.millimetersPerPixel).rounded())
        let tail = gc.carrierCoverage(x: gc.width / 2, y: tailRow)
        precondition(tail > 0.003 && tail < 0.03, "Holder tail out of range: \(tail)")
        var detailGate = blurGate; detailGate.holderDetail = 1
        let gd = geometry(inHolder, longEdge: 1024, gate: detailGate)
        var specks = 0
        for y in 0..<Int(gd.gate.minY) { for x in 0..<gd.width where gd.carrierCoverage(x: x, y: y) > gb.carrierCoverage(x: x, y: y) + 0.05 { specks += 1 } }
        precondition(specks > 20, "Holder edge detail produced no light specks")
        // Gate types: values as specified; tilt/bulge moved to Distress in v5 while legacy v4 gates retain defaults.
        let natural = FilmEdgeGate(), loose = FilmEdgeGate(.loose), precise = FilmEdgeGate(.precise)
        precondition(natural.kind == .natural && precise.kind == .precise && loose.kind == .loose
            && precise.tilt == 0 && precise.bulge == 0 && natural.tilt == 0 && natural.bulge == 0
            && loose.tilt == 0 && loose.bulge == 0
            && natural.softness == 0.03 && natural.wear == 0.02 && loose.softness == 0.05 && loose.wear == 0.04
            && loose.holderBlur > natural.holderBlur && natural.holderBlur > precise.holderBlur, "Gate type values")
        precondition(!FilmEdgeGate.Kind.allCases.map(\.rawValue).contains("rough"), "Rough gate kind should be removed")
        let legacyRough = try JSONDecoder().decode(
            FilmEdgeGate.self,
            from: Data(#"{"softness":0.05,"wear":0.04,"holderBlur":0.22,"holderDetail":0.65,"tilt":0.8,"bulge":1.0}"#.utf8))
        precondition(legacyRough.kind == nil && legacyRough.tilt == 0.8 && legacyRough.bulge == 1.0,
            "Legacy rough gate JSON did not decode as Custom")
        var legacyLayout = FilmEdgeLayout(); legacyLayout.gate = FilmEdgeGate(.loose)
        legacyLayout.gate.tilt = 0.5; legacyLayout.gate.bulge = 0.6
        legacyLayout.distress = FilmEdgeDistress.Preset.lab.legacyValues
        legacyLayout.distress.amount = 0  // v4 preserved gate tilt/bulge even at Amount 0.
        let legacyZeroResolved = FilmEdgeGeometry.resolve(legacyLayout)
        precondition(abs(abs(legacyZeroResolved.tilt) - 0.5) < 1e-9 && abs(legacyZeroResolved.bulge - 0.6) < 1e-9,
            "Legacy v4 gate tilt/bulge vanished at Amount 0: \(legacyZeroResolved.tilt), \(legacyZeroResolved.bulge)")
        var crooked = FilmEdgeDistress(); crooked.tilt = 1
        var cookedLayout = FilmEdgeLayout(); cookedLayout.gate = FilmEdgeGate(.loose); cookedLayout.distress = crooked
        let resolvedStraight = FilmEdgeGeometry.resolve(cookedLayout)
        precondition(abs(resolvedStraight.tilt - 1.0) < 1e-9 && resolvedStraight.bulge == 0,
            "v5 Loose gate injected unwanted tilt/bulge: \(resolvedStraight.tilt), \(resolvedStraight.bulge)")
        let flatGate = FilmEdgeGate(.precise)
        var bulged = FilmEdgeDistress(); bulged.bulge = 1
        let level = geometry(FilmEdgeDistress(), longEdge: 1024, gate: flatGate), round = geometry(bulged, longEdge: 1024, gate: flatGate)
        let probeX = Double(level.width) / 2 + 0.5, probeY = level.gate.minY - 0.15 / level.millimetersPerPixel
        let (fx0, fy0) = level.film(probeX, probeY), (fx1, fy1) = round.film(probeX, probeY)
        precondition(level.gateDistance(fx0, fy0) > 0.1 && round.gateDistance(fx1, fy1) < 0, "Bulge did not bow the gate outline")
        // Enlarger print: a clean preset (no filing, reflection or halo); the easel's zoom decides
        // the border. Default shows a thin rebate band and no holes; 90 % reaches the holes; above
        // 100 % the blades crop into the picture.
        var hand = FilmEdgeDistress(); hand.enlargerPrint = true  // what a negative print renders
        hand.seed = 3
        precondition(hand.carrierRoughness == 0 && hand.carrierReflection == 0 && hand.edgeFog == 0 && hand.leak == 0,
            "Hand print preset is not clean")
        func holes(_ g: FilmEdgeGeometry) -> Int {
            var count = 0
            for y in 0..<g.height { for x in 0..<g.width where g.supportCoverage(x: x, y: y) < 1 && g.carrierCoverage(x: x, y: y) > 0.5 { count += 1 } }
            return count
        }
        func rebateBand(_ g: FilmEdgeGeometry) -> Int {
            var count = 0
            for y in 0..<g.height { for x in 0..<g.width where g.gateCoverage(x: x, y: y) == 0 && g.carrierCoverage(x: x, y: y) > 0.5 { count += 1 } }
            return count
        }
        let gh = geometry(hand, longEdge: 1024, gate: FilmEdgeGate(.natural))
        precondition(holes(gh) == 0 && rebateBand(gh) > 0 && gh.distress.carrierDetail == 0 && gh.distress.carrierTail == 0
            && gh.distress.carrierBlur < 0.02 && gh.easelOffset == (0, 0),
            "Default enlarger print: \(holes(gh)) hole pixels, no rebate band, a scan holder or a hand-set offset without an easel")
        precondition(holes(geometry(hand, longEdge: 1024, gate: FilmEdgeGate(.precise), zoom: 0.9)) > 0, "90 % zoom did not reach the holes")
        let cropped = geometry(hand, longEdge: 1024, gate: FilmEdgeGate(.precise), zoom: 1.05)
        precondition(rebateBand(cropped) == 0 && holes(cropped) == 0, "Blades above 100 % still showed rebate")
        // The opening is the zoomed frame plus a margin of the same paper; blades are straight.
        let exact = geometry(hand, longEdge: 1024, gate: FilmEdgeGate(.precise), zoom: 0.95)
        precondition(abs(exact.carrierHalf.along - 18 / 0.95) < 1e-9 && abs(exact.carrierHalf.across - 12 / 0.95) < 1e-9,
            "Easel opening does not follow the zoom")
        precondition(abs(Double(exact.width) * exact.millimetersPerPixel - 2 * (18 / 0.95 + 0.9)) < 2 * exact.millimetersPerPixel,
            "Enlarger canvas is not the opening plus its paper margin")
        let row = Int((Double(exact.height) / 2 - exact.carrierHalf.across / exact.millimetersPerPixel).rounded())
        // The blade is straight but worn like the gate: the line wanders by no more than its wear.
        let edgeDistances = stride(from: exact.width / 4, to: exact.width * 3 / 4, by: 7).map { exact.carrierDistance(x: $0, y: row) }
        let wear = Easel.Kind.natural.wear, spread = edgeDistances.max()! - edgeDistances.min()!
        precondition(exact.distress.carrierRoughness == wear && spread > 0.1 * wear && spread <= 2 * wear + 1e-9,
                     "Easel blade wear \(spread) mm for amplitude \(wear)")
        // Hand-set: up to 0.3° extra rotation and 0.18 mm offset, seeded; off is square and centred.
        var easel = PrintLayout(); easel.easelSeed = 5; easel.handSet = true
        let set = geometry(hand, gate: FilmEdgeGate(.precise), easel: easel)
        easel.handSet = false
        let machine = geometry(hand, gate: FilmEdgeGate(.precise), easel: easel)
        precondition(machine.easelOffset == (0, 0) && machine.distress.tilt == 0, "Machine easel was not square and centred")
        precondition(abs(set.distress.tilt) <= 0.3 && set.distress.tilt != 0 && abs(set.easelOffset.x) <= 0.18 && abs(set.easelOffset.y) <= 0.18,
            "Hand-set easel outside its range: \(set.distress.tilt)°, \(set.easelOffset)")
        precondition(geometry(FilmEdgeDistress(), gate: FilmEdgeGate(.precise), easel: PrintLayout()).easelOffset == (0, 0),
            "A scan moved with the easel")
        // Hole rim: the yellow core and strongest halo face the picture and transition smoothly across pixels.
        var rimmed = FilmEdgeDistress(); rimmed.holeVariation = 1; rimmed.seed = 21
        let gRim = geometry(rimmed, longEdge: 2048)
        var inner = 0.0, outer = 0.0, maxRimStep = 0.0
        for y in 0..<gRim.height {
            var prevCore: Double? = nil
            for x in 0..<gRim.width {
                let rim = gRim.holeRimExposure(x: x, y: y)
                if let prev = prevCore { maxRimStep = max(maxRimStep, abs(rim.core - prev)) }
                prevCore = rim.core
                guard rim.core > 0 || rim.warm > 0 else { continue }
                let (_, fy) = gRim.film(Double(x) + 0.5, Double(y) + 0.5)
                if abs(fy) < FilmEdgeGeometry.holeCenter { inner = max(inner, rim.core) } else { outer = max(outer, rim.core) }
            }
        }
        precondition(inner > 1 && outer < inner * 0.1, "Hole rim core not on the picture side: inner \(inner), outer \(outer)")
        precondition(maxRimStep < inner * 0.45, "Hole rim stepped too sharply between adjacent pixels: \(maxRimStep) vs peak \(inner)")
        // Leak light enters as exposure: a negative print darkens nothing it should brighten, and
        // the warm path reaches the red-sensitive layer more than the blue.
        let neutral = RGB(1, 1, 1)
        var warm = FilmEdgeDistress(); warm.warmth = 1
        let light = geometry(warm).leakLight(neutral: neutral)
        precondition(light.x > 5 * light.z, "Base-path light did not favour the red-sensitive layer")

        // Stage 2: strip-space bow & Hasselblad V-notches rotate rigidly between landscape and portrait,
        // and gateCoverageMap at 4096 px matches brute-force gateCoverage with 0 error.
        do {
            var rollLayout = FilmEdgeLayout()
            rollLayout.format = .roll120
            rollLayout.rollFrame = .six45
            rollLayout.rollGate = .hasselblad
            rollLayout.gate = FilmEdgeGate(.loose)
            rollLayout.distress.bulge = 1.0
            rollLayout.scanZoom = 0.85
            var sel = FilmEdgeSelection(); sel.mode = .manual; sel.manualType = .reversalScan
            var rLand = base; rLand.filmEdgeSelection = sel; rLand.filmEdgeLayout = rollLayout
            let pLand = try FilmPipeline(library: library, recipe: FilmEdgeRenderer.materialRecipe(rLand))
            let gLand = FilmEdgeGeometry(
                imageSize: CGSize(width: 560, height: 415), layout: rLand.renderedFilmEdgeLayout!,
                longEdge: 600, perforation: .ks1870, easel: nil)!
            let gPort = FilmEdgeGeometry(
                imageSize: CGSize(width: 415, height: 560), layout: rLand.renderedFilmEdgeLayout!,
                longEdge: 600, perforation: .ks1870, easel: nil)!
            precondition(gLand.portrait && !gPort.portrait, "6x4.5 orientation failed to flip portrait flag")
            // Corresponding strip points (a, t): on landscape (portrait=true), fx=-t, fy=a; on portrait (portrait=false), fx=a, fy=t.
            for (a, t) in [(-20.75, 0.0), (0.0, 28.0), (-20.85, -2.7), (20.75, 2.4)] {
                let dLand = gLand.gateDistance(-t, a)
                let dPort = gPort.gateDistance(a, t)
                precondition(abs(dLand - dPort) < 1e-9, "Strip-space gateDistance drifted under 90° rotation at (\(a),\(t)): \(dLand) vs \(dPort)")
            }
            for g in [gLand, gPort] {
                let scene = Array(repeating: SIMD4<Float>(0.18, 0.18, 0.18, 1), count: g.width * g.height)
                let cpu = try pLand.process(scene.map { RGB(Double($0.x), Double($0.y), Double($0.z)) },
                                            width: g.width, height: g.height, stochastic: false, edge: g, autoExposureEV: 0)
                let metal = try await gpu.process(scene, width: g.width, height: g.height, pipeline: pLand,
                                                  stochastic: false, autoExposureEV: 0, edge: g)
                var bad = 0
                for i in cpu.indices { for ch in 0..<3 {
                    if abs(cpu[i][ch] - Double(metal.pixels[i][ch])) > 1e-3 { bad += 1 }
                }}
                precondition(bad == 0, "120 strip-space CPU/Metal disagreement (portrait=\(g.portrait)): \(bad)")
            }
        }
        do {
            for (label, tilt, bulge, cornerRoll) in [
                ("pos-bulge-tilt", 3.0, 1.0, FilmEdgeLayout.RollGate.hasselblad),
                ("neg-bulge-tilt", -3.0, -1.0, FilmEdgeLayout.RollGate.toy),
            ] {
                var layout = FilmEdgeLayout()
                layout.format = .roll120; layout.rollFrame = .six6; layout.rollGate = cornerRoll
                layout.gate = FilmEdgeGate(.natural); layout.distress.tilt = tilt; layout.distress.bulge = bulge
                layout.scanZoom = 0.85
                var erodes = FilmEdgeGeometry(imageSize: CGSize(width: 560, height: 560), layout: layout, longEdge: 4096)!
                erodes.erodesGate = true
                let map = try FilmEdgeRenderer.gateCoverageMap(erodes)
                var maxMapErr: Float = 0
                for y in stride(from: 0, to: erodes.height, by: 1) {
                    for x in stride(from: 0, to: erodes.width, by: 7) {
                        let ref = Float(erodes.gateCoverage(x: x, y: y))
                        let diff = abs(map[y * erodes.width + x] - ref)
                        if diff > maxMapErr { maxMapErr = diff }
                    }
                }
                precondition(maxMapErr == 0, "4096 px gateCoverageMap \(label) error: \(maxMapErr)")
            }
        }
        var seed12Layout = FilmEdgeLayout(); seed12Layout.gate = FilmEdgeGate(.natural)
        seed12Layout.scanZoom = 0.78; seed12Layout.distress.seed = 12
        seed12Layout.distress.scanHolder = true
        // Verify CPU/Metal parity on seed 12 negativeScan & invertedScan + curved hairs zoom invariance.
        for scanType in [FilmEdgeType.negativeScan, .invertedScan] {
            var sel12 = FilmEdgeSelection(); sel12.mode = .manual; sel12.manualType = scanType
            var r12 = base; r12.filmEdgeSelection = sel12; r12.filmEdgeLayout = seed12Layout
            let pipeline12 = try FilmPipeline(library: library, recipe: FilmEdgeRenderer.materialRecipe(r12))
            let g12 = FilmEdgeGeometry(imageSize: CGSize(width: 600, height: 400), layout: r12.renderedFilmEdgeLayout!, longEdge: 384)!
            let sc12 = Array(repeating: SIMD4<Float>(0.18, 0.18, 0.18, 1), count: g12.width * g12.height)
            let cpu12 = try pipeline12.process(sc12.map { RGB(Double($0.x), Double($0.y), Double($0.z)) },
                width: g12.width, height: g12.height, stochastic: false, edge: g12, autoExposureEV: 0)
            let mtl12 = try await gpu.process(sc12, width: g12.width, height: g12.height, pipeline: pipeline12,
                stochastic: false, autoExposureEV: 0, edge: g12)
            var bad12 = 0
            for i in cpu12.indices { for ch in 0..<3 {
                if abs(cpu12[i][ch] - Double(mtl12.pixels[i][ch])) > 3e-4 { bad12 += 1 }
            }}
            precondition(bad12 == 0, "Seed 12 \(scanType) CPU/Metal mismatch: \(bad12)")
        }
        // Curved fine hairs remain zoom-invariant & match between CPU and Metal.
        var hairSeed: UInt32 = 1
        while hairSeed < 50 {
            var hd = FilmEdgeDistress(); hd.seed = hairSeed; hd.dust = 0.85
            let gh = geometry(hd, longEdge: 512, scanZoom: 0.78)
            if !gh.activeHairs.isEmpty { break }
            hairSeed += 1
        }
        var hd = FilmEdgeDistress(); hd.seed = hairSeed; hd.dust = 0.85
        let ghTight = geometry(hd, longEdge: 512, scanZoom: 1.0)
        let ghWide = geometry(hd, longEdge: 512, scanZoom: 0.78)
        precondition(!ghWide.activeHairs.isEmpty && ghTight.activeHairs.count == ghWide.activeHairs.count
            && ghTight.activeHairs[0].p0 == ghWide.activeHairs[0].p0,
            "Curved fine hair drifted with scan zoom")
        print("PASS: distress CPU/Metal agreement incl. BH/released scratches (max \(maxError)), BH-1866 vs KS-1870 geometry, hole variation and rim, sprockets untouched by leaks, perforation fog, gated front vs back leaks, carrier reflection, holder core/tail/detail, gate types/tilt/bulge, enlarger easel zoom/blades/hand-set placement and parity, picture-side rim core, rebate-clamped scratches, depth/route scratch colour, Amount 0 identity, stable seeded features, physical-size dust/carrier (\(dustSmall)/\(dustLarge) mm²), intact KS holes, 120 without sprockets, route-dependent dust polarity")
    }

    static func checkWorkflow(root: URL, recipe initial: EditRecipe) async throws {
        let folder = URL(fileURLWithPath: "/private/tmp/spektrafilm-build/film-edge-proof")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let context = CGContext(data: nil, width: 900, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.3, green: 0.6, blue: 0.2, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 900, height: 600))
        context.setFillColor(CGColor(red: 0.9, green: 0.2, blue: 0.1, alpha: 1)); context.fill(CGRect(x: 0, y: 300, width: 900, height: 300))
        let source = context.makeImage()!
        let encoded = NSMutableData()
        let destination = CGImageDestinationCreateWithData(encoded, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, source, nil); precondition(CGImageDestinationFinalize(destination))
        let renderer = PhotoRenderer(source: source, directory: root.appendingPathComponent("SpektraCam/Resources/ModelData"), data: encoded as Data)
        var recipe = initial
        recipe.filmEdgeSelection = nil
        recipe.flags["film_render.grain.active"] = false
        let started = ProcessInfo.processInfo.systemUptime
        for type in FilmEdgeType.allCases {
            var selection = FilmEdgeSelection(); selection.mode = .manual; selection.manualType = type
            recipe.filmEdgeSelection = selection
            let preview = try await renderer.renderFilmEdge(recipe, maximum: 720)
            precondition(max(preview.width, preview.height) == 720)
            let url = folder.appendingPathComponent(type.rawValue + ".png")
            let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, preview, nil); precondition(CGImageDestinationFinalize(dest))
        }
        // Visual review: a negative scan's holder edge at full size, framed wide.
        do {
            var held = recipe
            var selection = FilmEdgeSelection(); selection.mode = .manual; selection.manualType = .invertedScan
            held.filmEdgeSelection = selection; held.filmEdgeLayout?.scanZoom = 0.8
            let image = try await renderer.renderFilmEdge(held, maximum: 3000)
            let url = folder.appendingPathComponent("invertedScan-holder.png")
            let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, image, nil); precondition(CGImageDestinationFinalize(dest))
        }
        // Visual review: every preset on a negative print and a slide scan.
        for preset in FilmEdgeDistress.Preset.allCases {
            for type in [FilmEdgeType.negativePrint, .reversalScan] {
                var styled = recipe
                var selection = FilmEdgeSelection(); selection.mode = .manual; selection.manualType = type
                styled.filmEdgeSelection = selection
                styled.filmEdgeLayout?.distress.apply(preset)
                let image = try await renderer.renderFilmEdge(styled, maximum: 1080)
                let url = folder.appendingPathComponent("distress-\(preset.rawValue)-\(type.rawValue).png")
                let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
                CGImageDestinationAddImage(dest, image, nil); precondition(CGImageDestinationFinalize(dest))
            }
        }
        // Visual review: roll-start burn across smooth, cassette plush and frayed burnTexture settings,
        // plus left-edge P1485695-style scan, sprocket/scratch close-up, and photo-vs-rebate continuity check.
        for tex in [0.0, 0.5, 1.0] {
            var burned = recipe
            var selection = FilmEdgeSelection(); selection.mode = .manual; selection.manualType = .invertedScan
            burned.filmEdgeSelection = selection
            burned.filmEdgeLayout?.scanZoom = 0.78
            burned.filmEdgeLayout?.distress.leakShape = .burn
            burned.filmEdgeLayout?.distress.leak = 0.85
            burned.filmEdgeLayout?.distress.burnCoverage = 0.25
            burned.filmEdgeLayout?.distress.leakPosition = 0.80
            burned.filmEdgeLayout?.distress.burnTexture = tex
            burned.filmEdgeLayout?.distress.scratches = 0.55
            burned.filmEdgeLayout?.distress.holeVariation = 0.85
            let image = try await renderer.renderFilmEdge(burned, maximum: 1440)
            let url = folder.appendingPathComponent(String(format: "distress-burn-tex-%.1f.png", tex))
            let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, image, nil); precondition(CGImageDestinationFinalize(dest))
        }
        // Full-strip continuity & color match between photo body and intact rebate across both
        // SpektraFilm routes (.invertedScan, .negativePrint, .negativeScan, .reversalScan) and composed LUT/front routes.
        for (label, leakKind, type, positive) in [
            ("invertedScan-back", FilmEdgeDistress.LeakKind.back, FilmEdgeType.invertedScan, true),
            ("negativePrint-front", FilmEdgeDistress.LeakKind.front, FilmEdgeType.negativePrint, true),
            ("negativeScan-front", FilmEdgeDistress.LeakKind.front, FilmEdgeType.negativeScan, false),
            ("reversalScan-back", FilmEdgeDistress.LeakKind.back, FilmEdgeType.reversalScan, true),
        ] {
            var cont = recipe
            var selection = FilmEdgeSelection(); selection.mode = .manual; selection.manualType = type
            cont.filmEdgeSelection = selection
            if type == .negativeScan { cont.scanFilm = true }
            if type == .negativePrint { cont.filmEdgeLayout?.printZoom = 0.90 } else { cont.filmEdgeLayout?.scanZoom = 0.78 }
            cont.filmEdgeLayout?.gate = FilmEdgeGate(.precise)
            cont.filmEdgeLayout?.distress.leakShape = .burn
            cont.filmEdgeLayout?.distress.leakKind = leakKind
            cont.filmEdgeLayout?.distress.leak = 0.9
            cont.filmEdgeLayout?.distress.burnCoverage = 0.25
            cont.filmEdgeLayout?.distress.leakPosition = 0.80
            cont.filmEdgeLayout?.distress.scratches = 0
            cont.filmEdgeLayout?.distress.holeVariation = 0
            let cg = try await renderer.renderFilmEdge(cont, maximum: 1080)
            let pixels = try PhotoColorBridge.decode(cg)
            let g = FilmEdgeGeometry(
                imageSize: CGSize(width: 900, height: 600),
                layout: cont.renderedFilmEdgeLayout!, longEdge: max(cg.width, cg.height),
                easel: PrintLayout())!
            // Sample just inside the left photo gate vs just above it in the intact inner rebate.
            let sampleX = Int(g.gate.minX) + max(8, Int(2.0 / g.millimetersPerPixel))
            let photoY = g.height / 2
            let rebateY = max(2, Int(g.gate.minY) - max(3, Int(0.35 / g.millimetersPerPixel)))
            let pCol = pixels[photoY * g.width + sampleX]
            let rCol = pixels[rebateY * g.width + sampleX]
            let maxChanDiff = max(abs(pCol.x - rCol.x), abs(pCol.y - rCol.y), abs(pCol.z - rCol.z))
            let polarityOK = positive ? (pCol.x > 0.68 && pCol.z > 0.68) : (pCol.x < 0.12 && pCol.z < 0.12)
            precondition(
                maxChanDiff < 0.03 && polarityOK,
                "\(label) burn mismatched or inverted across gate: photo=\(pCol), rebate=\(rCol)")
            let url = folder.appendingPathComponent("proof-\(label).png")
            let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, cg, nil); precondition(CGImageDestinationFinalize(dest))
        }
        var tilted = recipe
        tilted.filmEdgeLayout?.distress.apply(.worn); tilted.look.enabled = false
        _ = try await renderer.renderFilmEdge(tilted, maximum: 512)  // creative centre + tilted gate mask
        // Creative centres (Develop off, LUT) blend through the gate: no bright rim, no dark seam,
        // and leak light reaches the picture as exposure.
        var cube = "LUT_3D_SIZE 9\n"
        for b in 0..<9 { for g in 0..<9 { for r in 0..<9 {
            cube += String(format: "%.4f %.4f %.4f\n", 0.06 + 0.9 * Double(r) / 8, 0.05 + 0.9 * Double(g) / 8, 0.04 + 0.92 * Double(b) / 8)
        }}}
        let cubeData = Data(cube.utf8), lutID = CubeLUT.hash(cubeData)
        try cubeData.write(to: folder.appendingPathComponent(lutID + ".cube"))
        let lutRenderer = PhotoRenderer(source: source, directory: root.appendingPathComponent("SpektraCam/Resources/ModelData"),
                                        data: encoded as Data, lutDirectory: folder)
        for type in [FilmEdgeType.reversalScan, .cinemaPrint, .negativePrint, .negativeScan] {
            for lut in [false, true] {
                var creative = recipe
                var selection = FilmEdgeSelection(); selection.mode = .manual; selection.manualType = type
                creative.filmEdgeSelection = selection
                if lut { creative.look.mode = .lut; creative.look.first.id = lutID } else { creative.look.enabled = false }
                creative.filmEdgeLayout?.gate.softness = 0.1
                // Compositing rims and seams only: rebate scratches are real lines near the gate.
                creative.filmEdgeLayout?.distress.scratches = 0
                let image = try await lutRenderer.renderFilmEdge(creative, maximum: 1080)
                let pixels = try PhotoColorBridge.decode(image)
                let crop = creative.filmEdgeLayout!.constrainedCrop(CropSelection(), imageSize: CGSize(width: 900, height: 600))
                let g = FilmEdgeGeometry(imageSize: crop.pixelRect(in: CGSize(width: 900, height: 600)).size,
                                         layout: creative.renderedFilmEdgeLayout!, longEdge: max(image.width, image.height),
                                         easel: PrintLayout())!
                precondition(g.width == image.width && g.height == image.height)
                let top = Int(g.gate.minY), bottom = Int(g.gate.maxY)
                func luma(_ x: Int, _ y: Int) -> Double { let v = pixels[y * image.width + x]; return Double(v.x + v.y + v.z) / 3 }
                var seams = 0, columns = 0
                for x in stride(from: image.width / 5, to: image.width * 4 / 5, by: 3) {
                    for (edge, inward) in [(top, 1), (bottom, -1)] {
                        // The rebate's own brightest point beside the gate (it is not perfectly flat).
                        let interior = luma(x, edge + 40 * inward), rebate = (4...10).map { luma(x, edge - $0 * inward) }.max()!
                        let band = (-4...12).map { luma(x, edge + $0 * inward) }
                        precondition(band.max()! < max(interior, rebate) + 0.03,
                            "Creative \(type) LUT \(lut) gate edge has a bright rim at x \(x): \(band.max()!) vs \(interior)")
                        // A negative print's rebate band is black: nothing can be darker than it.
                        if type != .negativePrint && band.min()! < min(interior, rebate) - 0.05 { seams += 1 }
                        columns += 1
                    }
                }
                precondition(seams * 50 < columns, "Creative \(type) LUT \(lut) gate edge has a dark seam in \(seams)/\(columns) columns")
                if lut {
                    var leaky = creative
                    leaky.filmEdgeLayout?.distress.apply(.leaky)
                    leaky.filmEdgeLayout?.distress.leakKind = .front
                    leaky.filmEdgeLayout?.distress.leakShape = .flare
                    leaky.filmEdgeLayout?.distress.leakSize = 14
                    leaky.filmEdgeLayout?.distress.edgeFog = 0
                    let lit = try PhotoColorBridge.decode(try await lutRenderer.renderFilmEdge(leaky, maximum: 1080))
                    var gain = 0.0
                    for y in stride(from: top + 30, to: bottom - 30, by: 4) { for x in stride(from: Int(g.gate.minX) + 30, to: Int(g.gate.maxX) - 30, by: 4) {
                        let a = lit[y * image.width + x], b = pixels[y * image.width + x]
                        gain = max(gain, Double(a.x + a.y + a.z - b.x - b.y - b.z) / 3)
                    }}
                    precondition(gain > 0.05, "Front leak did not reach the \(type) LUT picture: \(gain)")
                }
            }
        }
        do {
            var lutBurn = recipe
            var selection = FilmEdgeSelection(); selection.mode = .manual; selection.manualType = .invertedScan
            lutBurn.filmEdgeSelection = selection
            lutBurn.look.enabled = true; lutBurn.look.mode = .lut; lutBurn.look.first.id = lutID
            lutBurn.filmEdgeLayout?.scanZoom = 0.78
            lutBurn.filmEdgeLayout?.gate = FilmEdgeGate(.precise)
            lutBurn.filmEdgeLayout?.distress.leakShape = .burn
            lutBurn.filmEdgeLayout?.distress.leakKind = .back
            lutBurn.filmEdgeLayout?.distress.leak = 0.9
            lutBurn.filmEdgeLayout?.distress.burnCoverage = 0.25
            lutBurn.filmEdgeLayout?.distress.leakPosition = 0.80
            lutBurn.filmEdgeLayout?.distress.scratches = 0
            lutBurn.filmEdgeLayout?.distress.holeVariation = 0
            let cgBurn = try await lutRenderer.renderFilmEdge(lutBurn, maximum: 1080)
            let pxBurn = try PhotoColorBridge.decode(cgBurn)
            let gBurn = FilmEdgeGeometry(
                imageSize: CGSize(width: 900, height: 600),
                layout: lutBurn.renderedFilmEdgeLayout!, longEdge: max(cgBurn.width, cgBurn.height),
                easel: PrintLayout())!
            let sx = Int(gBurn.gate.minX) + max(8, Int(2.0 / gBurn.millimetersPerPixel))
            let py = gBurn.height / 2
            let ry = max(2, Int(gBurn.gate.minY) - max(3, Int(0.35 / gBurn.millimetersPerPixel)))
            let pc = pxBurn[py * gBurn.width + sx], rc = pxBurn[ry * gBurn.width + sx]
            let dLUT = max(abs(pc.x - rc.x), abs(pc.y - rc.y), abs(pc.z - rc.z))
            precondition(dLUT < 0.03 && pc.x > 0.68 && rc.x > 0.68,
                "Composed LUT burn diverged between photo \(pc) and rebate \(rc)")
            let url = folder.appendingPathComponent("proof-burn-lut.png")
            let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, cgBurn, nil); precondition(CGImageDestinationFinalize(dest))
        }
        recipe.filmEdgeSelection = nil
        recipe.flags["camera.auto_exposure"] = true
        var paper = PrintLayout(); paper.paper = .eightByTen; paper.margin = 0.125
        recipe.printLayout = paper
        recipe.tone.monochrome = true
        let restored = try JSONDecoder().decode(EditRecipe.self, from: JSONEncoder().encode(recipe))
        precondition(restored == recipe)
        let preview = try await renderer.renderPresentation(restored, maximum: 1080)
        let (url, w, h) = try await renderer.export(restored, size: .small, format: .png, quality: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        let exported = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(url as CFURL, nil)!, 0, nil)!
        // A 1080 px long edge of the sheet; the picture keeps native resolution up to that.
        let planned = await renderer.exportDimensions(restored, size: .small)
        precondition(max(w, h) == 1080 && abs(Double(w) / Double(h) - 1.25) < 0.01 && preview.width == w && preview.height == h
            && planned.width == w && planned.height == h,
            "Finishing lost the paper shape, exceeded its size or disagreed with the planned size: \(w)×\(h), planned \(planned)")
        let a = try PhotoColorBridge.decode(preview), b = try PhotoColorBridge.decode(exported)
        precondition(a.count == b.count)
        for i in a.indices {
            precondition(abs(a[i].x - b[i].x) < 0.005 && abs(a[i].y - b[i].y) < 0.005 && abs(a[i].z - b[i].z) < 0.005,
                "Saved presentation and PNG export diverged")
            precondition(abs(b[i].x - b[i].y) < 0.002 && abs(b[i].x - b[i].z) < 0.002, "B&W did not include the edge")
        }
        // An enlarger print's margin is the paper's own white (its unexposed base), never table shadow.
        precondition(b[0].x >= 254.0 / 255 && abs(b[0].x - b[b.count - 1].x) < 0.005, "Paper inherited edge density or table shadows: \(b[0]) vs \(b[b.count - 1])")
        // Export sizes resolve against the native output and never enlarge. A crop exports its own
        // pixels; on paper the picture keeps one source pixel per output pixel.
        do {
            var plain = EditRecipe()
            plain.flags["film_render.grain.active"] = false
            plain.crop.normalizedRect = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
            for (size, expected) in [(PhotoExporter.Size.original, (450, 300)), (.percent(50), (225, 150)),
                                     (.longEdge(2048), (450, 300)), (.longEdge(300), (300, 200))] {
                let planned = await renderer.exportDimensions(plain, size: size)
                let (file, w, h) = try await renderer.export(plain, size: size, format: .png, quality: 1)
                try? FileManager.default.removeItem(at: file)
                precondition(w == expected.0 && h == expected.1 && planned.width == w && planned.height == h,
                             "\(size.rawValue) on a crop gave \(w)×\(h), planned \(planned)")
            }
            var sheet = PrintLayout(); sheet.paper = .fourBySix; sheet.handSet = false
            sheet.margin = 1.0 / 6
            plain.printLayout = sheet
            let small = await renderer.exportDimensions(plain, size: .original)
            precondition(max(small.width, small.height) == 900, "Half-scale picture on paper was not kept at native resolution: \(small)")
            sheet.fill = true
            plain.printLayout = sheet
            let cropped = await renderer.exportDimensions(plain, size: .original)
            precondition(max(cropped.width, cropped.height) == 450, "A borderless sheet resampled the picture: \(cropped)")
            let printed = await renderer.exportDimensions(plain, size: .print(ppi: 300))
            precondition(printed == cropped, "Print size enlarged a small picture: \(printed)")
            precondition(PhotoExporter.Size(rawValue: "long:2048") == .longEdge(2048) && PhotoExporter.Size(rawValue: "print:300") == .print(ppi: 300)
                && PhotoExporter.Size(rawValue: "percent:0") == nil && PhotoExporter.Size(rawValue: "L") == nil, "Size storage")
        }
        // Cancellation cannot publish a file or leave the serial worker unusable.
        let cancelled = Task { try await renderer.renderFilmEdge(recipe, maximum: 720) }
        cancelled.cancel()
        do { _ = try await cancelled.value; preconditionFailure("Cancelled edge work completed") } catch is CancellationError {}
        _ = try await renderer.renderFilmEdge(recipe, maximum: 256)
        let proof = folder.appendingPathComponent("paper-bw.png")
        try? FileManager.default.removeItem(at: proof)
        try FileManager.default.copyItem(at: url, to: proof)
        // The batch worker consumes the same durable recipe from original bytes.
        let original = folder.appendingPathComponent("source.png")
        try (encoded as Data).write(to: original)
        let resources = FilmRenderResources(directory: root.appendingPathComponent("SpektraCam/Resources/ModelData"))
        let batch = BatchPhotoExporter(directory: root.appendingPathComponent("SpektraCam/Resources/ModelData"),
            luts: folder, resources: resources)
        let item = BatchExportItem(id: UUID(), name: "source.png", source: original, recipe: restored, width: 900, height: 600)
        let batchURL = try await batch.export(item, size: .small, format: .png, quality: 1)
        defer { try? FileManager.default.removeItem(at: batchURL) }
        let batchImage = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(batchURL as CFURL, nil)!, 0, nil)!
        let c = try PhotoColorBridge.decode(batchImage)
        precondition(c == b, "Batch finishing differed from the editor export")
        // Old adaptive recipes are cropped to the physical gate at every rendering entry.
        recipe.geometry.quarterTurns = 1
        recipe.crop.normalizedRect = CGRect(x: 0.1, y: 0.2, width: 0.7, height: 0.6)
        recipe.printLayout = nil
        recipe.filmEdgeLayout?.format = .roll120
        let rotated = try await renderer.renderPresentation(recipe, maximum: 720)
        recipe.constrainFilmEdgeCrop(imageSize: CGSize(width: 900, height: 600))
        let fixedCrop = recipe.crop.pixelRect(in: CGSize(width: 600, height: 900))
        let expected = FilmEdgeGeometry(imageSize: recipe.crop.pixelRect(in: CGSize(width: 600, height: 900)).size,
            layout: recipe.renderedFilmEdgeLayout!, longEdge: Int(max(fixedCrop.width, fixedCrop.height)), easel: PrintLayout())!
        // A negative print sits on its sheet with the easel's automatic border; a scan is the canvas.
        if let sheetLayout = recipe.printedLayout {
            let canvas = CGSize(width: expected.width, height: expected.height)
            let sheet = PrintGeometry(imageSize: canvas, layout: sheetLayout, longEdge: CGFloat(max(rotated.width, rotated.height)),
                                      content: recipe.printContent(canvas: canvas))!
            precondition(rotated.width == Int(sheet.paperSize.width) && rotated.height == Int(sheet.paperSize.height),
                         "Rotated print \(rotated.width)×\(rotated.height), sheet \(sheet.paperSize)")
        } else {
            precondition(rotated.width == expected.width && rotated.height == expected.height)
        }
        recipe.look.enabled = false
        _ = try await renderer.renderFilmEdge(recipe, maximum: 256)
        recipe.look.enabled = true; recipe.look.mode = .lut
        _ = try await renderer.renderFilmEdge(recipe, maximum: 256)
        let largeContext = CGContext(data: nil, width: 2160, height: 1440, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        largeContext.draw(source, in: CGRect(x: 0, y: 0, width: 2160, height: 1440))
        let large = PhotoRenderer(source: largeContext.makeImage()!, directory: root.appendingPathComponent("SpektraCam/Resources/ModelData"))
        var settled = initial
        settled.filmEdgeSelection = nil; settled.filmEdgeLayout = FilmEdgeLayout()
        settled.look.enabled = true; settled.look.mode = .spektrafilm; settled.mix = 1
        let previewStart = ProcessInfo.processInfo.systemUptime
        _ = try await large.renderFilmEdge(settled, maximum: 720)
        let quickMS = (ProcessInfo.processInfo.systemUptime - previewStart) * 1000
        let refineStart = ProcessInfo.processInfo.systemUptime
        let refined = try await large.renderFilmEdge(settled, maximum: 2160)
        // A negative print: the easel opening (98.5 %) plus its paper margin.
        let settledGeometry = FilmEdgeGeometry(imageSize: CGSize(width: 2160, height: 1440), layout: settled.renderedFilmEdgeLayout!,
                                               longEdge: 2160, easel: PrintLayout())!
        precondition(refined.width == settledGeometry.width && refined.height == settledGeometry.height && refined.width == 2160)
        let refineMS = (ProcessInfo.processInfo.systemUptime - refineStart) * 1000
        do {
            _ = try await large.export(settled, size: .full, format: .png, quality: 1)
            preconditionFailure("Edge export silently substituted a preview when original bytes were missing")
        } catch PhotoExporter.Failure.decode {}

        // v5 Clean & Lab Scan handling, seeded tilt/bulge, reroll, clamping, leak-shape toggles, curved hairs & holder lint.
        precondition(abs(FilmEdgeLayout().printZoom - 0.93) < 1e-9, "Default printZoom should be 0.93")
        let cleanDefaults = FilmEdgeDistress.Preset.clean.values(seed: 1)
        let wornDefaults = FilmEdgeDistress.Preset.worn.values(seed: 1)
        let leakyDefaults = FilmEdgeDistress.Preset.leaky.values(seed: 1)
        precondition(
            cleanDefaults.scratches == 0
                && cleanDefaults.edgeFog == 0
                && cleanDefaults.tilt == 0
                && cleanDefaults.bulge == 0
                && abs(cleanDefaults.holeVariation - 0.25) < 1e-9
                && abs(leakyDefaults.holeVariation - 0.25) < 1e-9
                && abs(wornDefaults.holeVariation - 0.50) < 1e-9
                && cleanDefaults.dust == 0
                && !cleanDefaults.isLeakEnabled,
            "Unexpected Clean/Leaky/Worn preset holeVariation or defaults")
        var labTiltPos = false, labTiltNeg = false, labBulgePos = false, labBulgeNeg = false
        for s in UInt32(1)...24 {
            let lab = FilmEdgeDistress.Preset.lab.values(seed: s)
            precondition(
                abs(lab.tilt) >= 0.049 && abs(lab.tilt) <= 0.251
                    && abs(lab.bulge) >= 0.039 && abs(lab.bulge) <= 0.201
                    && abs(lab.holeVariation - 0.25) < 1e-9
                    && abs(lab.edgeFog - 0.20) < 1e-9 && abs(lab.scratches - 0.10) < 1e-9
                    && lab.dust == 0 && !lab.isLeakEnabled,
                "Lab preset defaults out of range for seed \(s): \(lab)")
            if lab.tilt > 0 { labTiltPos = true } else { labTiltNeg = true }
            if lab.bulge > 0 { labBulgePos = true } else { labBulgeNeg = true }
            precondition(lab.preset == .lab, "Lab scan lost preset identity for seed \(s)")
        }
        precondition(labTiltPos && labTiltNeg && labBulgePos && labBulgeNeg, "Lab signs did not vary across seeds")
        // Verify legacy v4 JSON without explicit holeVariation still decodes to 0.5 and matches legacy preset identity.
        let decodedLegacyClean = try JSONDecoder().decode(
            FilmEdgeDistress.self, from: Data(#"{"seed":1,"scratches":0,"edgeFog":0}"#.utf8))
        precondition(decodedLegacyClean.revision == 4 && decodedLegacyClean.preset == .clean,
            "Legacy v4 clean JSON lost preset identity: \(decodedLegacyClean)")
        var rerolled = FilmEdgeLayout.newDefault(seed: 1)
        let tiltSeed1 = rerolled.distress.tilt
        let altSeed = (UInt32(2)...50).first { FilmEdgeDistress.labTilt(seed: $0) != tiltSeed1 }!
        rerolled.distress.rerollPattern(seed: altSeed)
        precondition(rerolled.distress.preset == .lab && rerolled.distress.tilt != tiltSeed1, "Lab reroll did not update seeded tilt")
        rerolled.distress.tilt = 1.25
        precondition(rerolled.distress.preset == nil, "Manual tilt did not yield Custom")
        rerolled.distress.rerollPattern(seed: 11)
        precondition(abs(rerolled.distress.tilt - 1.25) < 1e-9, "Custom reroll overwrote manual tilt")
        rerolled.distress.tilt = 2.5; rerolled.distress.bulge = 0.9; rerolled.distress.amount = 2.0
        precondition(abs(rerolled.distress.effective.tilt - 3.0) < 1e-9 && abs(rerolled.distress.effective.bulge - 1.5) < 1e-9,
            "Effective tilt/bulge did not clamp cleanly: \(rerolled.distress.effective)")

        // Leak-shape toggle semantics & pixel difference across all 4 shapes on first tap.
        let toggled = FilmEdgeDistress.Preset.lab.values(seed: 5)
        precondition(!toggled.isLeakEnabled)
        for shape in FilmEdgeDistress.LeakShape.allCases {
            var copy = toggled
            copy.toggleLeakShape(shape)
            precondition(copy.isLeakEnabled && copy.leakShape == shape && abs(copy.leak - 0.30) < 1e-9,
                "Tap \(shape) did not enable 30% leak")
            if shape == .burn { precondition(abs(copy.burnCoverage - 0.35) < 1e-9, "Burn coverage did not start at 35%") }
            copy.toggleLeakShape(shape)
            precondition(!copy.isLeakEnabled && copy.leak == 0 && copy.burnCoverage == 0.35,
                "Second tap on \(shape) did not turn leak off while preserving burnCoverage")
        }

        // Seed 12 holder-hair reproduction (`1400×933`, `scanZoom=0.78`, `Natural` holder detail).
        var seed12Layout = FilmEdgeLayout(); seed12Layout.gate = FilmEdgeGate(.natural)
        seed12Layout.scanZoom = 0.78; seed12Layout.distress.seed = 12
        seed12Layout.distress.scanHolder = true
        let gSeed12 = FilmEdgeGeometry(imageSize: CGSize(width: 1400, height: 933), layout: seed12Layout, longEdge: 1400)!
        var openFibreHits = 0
        for y in 0..<gSeed12.height {
            let cy = (Double(y) + 0.5 - Double(gSeed12.height) / 2) * gSeed12.millimetersPerPixel
            for x in 0..<gSeed12.width {
                let cx = (Double(x) + 0.5 - Double(gSeed12.width) / 2) * gSeed12.millimetersPerPixel
                let f = gSeed12.holderFibres(cx, cy)
                let c = gSeed12.carrierCoverage(x: x, y: y)
                if gSeed12.carrierDistance(x: x, y: y) < -max(gSeed12.distress.carrierBlur, gSeed12.pixelRadius) && f > 0.05 {
                    precondition(abs(c - (1 - f)) < 1e-9, "carrierCoverage dropped holder fibre at (\(x),\(y)): c=\(c), f=\(f)")
                    openFibreHits += 1
                }
            }
        }
        precondition(openFibreHits > 20, "Seed 12 natural holder showed only \(openFibreHits) interior fibre pixels")

        let legacyCine = try JSONDecoder().decode(
            FilmEdgeLayout.self, from: Data(#"{"format":"film35","cinePerforations":true}"#.utf8))
        let legacyStill = try JSONDecoder().decode(
            FilmEdgeLayout.self, from: Data(#"{"format":"film35","cinePerforations":false}"#.utf8))
        precondition(legacyCine.sourcePerforations == .cineBH && legacyStill.sourcePerforations == .auto)
        let autoEncoded = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(FilmEdgeLayout())) as! [String: Any]
        precondition(autoEncoded["sourcePerforations"] == nil, "Default .auto layout grew JSON keys")
        var stillEdge = FilmEdgeLayout()
        stillEdge.sourcePerforations = .stillKS
        stillEdge.scanZoom = 0.78
        stillEdge.distress = FilmEdgeDistress()
        let decodedStillEdge = try JSONDecoder().decode(
            FilmEdgeLayout.self, from: try JSONEncoder().encode(stillEdge))
        precondition(decodedStillEdge.sourcePerforations == .stillKS)

        var perfRecipe = EditRecipe()
        perfRecipe.filmID = "kodak_vision3_250d"
        perfRecipe.printID = "kodak_2383"
        perfRecipe.flags["film_render.grain.active"] = false
        var scanSel = FilmEdgeSelection(); scanSel.mode = .manual; scanSel.manualType = .negativeScan
        perfRecipe.filmEdgeSelection = scanSel
        perfRecipe.filmEdgeLayout = stillEdge
        let ksImage = try await large.renderFilmEdge(perfRecipe, maximum: 720)
        perfRecipe.filmEdgeLayout?.sourcePerforations = .cineBH
        let bhImage = try await large.renderFilmEdge(perfRecipe, maximum: 720)
        let ksPixels = try PhotoColorBridge.decode(ksImage)
        let bhPixels = try PhotoColorBridge.decode(bhImage)
        precondition(ksPixels.count == bhPixels.count)
        let changedPerf = zip(ksPixels, bhPixels).reduce(0) { count, pair in
            abs(pair.0.x - pair.1.x) > 0.02 ? count + 1 : count
        }
        precondition(changedPerf > 500,
            "Explicit stillKS vs cineBH source perforations failed to differ on Vision3 250D: \(changedPerf) px")

        // Stage 2: calibrated 101.5% 135 aperture, legacy 1.0 decode, half-frame 135, zero-clamping border grid.
        var colorRecipe = initial
        colorRecipe.flags["film_render.grain.active"] = false
        do {
            let defLayout = FilmEdgeLayout.newDefault()
            precondition(abs(defLayout.apertureScale - 1.015) < 1e-9, "newDefault apertureScale != 1.015")
            precondition(abs(defLayout.gateAlong - 36.54) < 1e-9 && abs(defLayout.gateAcross - 24.36) < 1e-9)
            let shoulder = FilmEdgeGeometry.holeCenter - FilmEdgeGeometry.holeAcross / 2 - defLayout.gateAcross / 2
            precondition(abs(shoulder - 0.5035) < 0.01, "Calibrated 135 shoulder \(shoulder) mm")
            let legacyLayout = try JSONDecoder().decode(FilmEdgeLayout.self, from: Data(#"{"format":"film35"}"#.utf8))
            precondition(abs(legacyLayout.apertureScale - 1.0) < 1e-9, "Legacy JSON altered apertureScale")

            var half = FilmEdgeLayout.newDefault()
            half.setFrame35(.half)
            precondition(half.frame35 == .half && half.cropAspect == .fourThree && abs(half.apertureScale - 1.0) < 1e-9)
            precondition(half.gateTitle(portrait: true) == "18 × 24 mm" && half.gateTitle(portrait: false) == "24 × 18 mm")
            half.setFrame35(.full)
            precondition(abs(half.apertureScale - 1.015) < 1e-9)
            half.setFrame35(.half)
            var halfSel = FilmEdgeSelection(); halfSel.mode = .manual; halfSel.manualType = .invertedScan
            var halfPort = colorRecipe; halfPort.filmEdgeSelection = halfSel; halfPort.filmEdgeLayout = half
            let portSrcCtx = CGContext(data: nil, width: 600, height: 800, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            portSrcCtx.setFillColor(CGColor(red: 0.25, green: 0.55, blue: 0.70, alpha: 1))
            portSrcCtx.fill(CGRect(x: 0, y: 0, width: 600, height: 800))
            portSrcCtx.setFillColor(CGColor(red: 0.85, green: 0.35, blue: 0.15, alpha: 1))
            portSrcCtx.fill(CGRect(x: 0, y: 400, width: 600, height: 400))
            let portCG = portSrcCtx.makeImage()!
            let portData = NSMutableData()
            let portEnc = CGImageDestinationCreateWithData(portData, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(portEnc, portCG, nil); precondition(CGImageDestinationFinalize(portEnc))
            let halfRenderer = PhotoRenderer(source: portCG,
                directory: root.appendingPathComponent("SpektraCam/Resources/ModelData"), data: portData as Data)
            let halfImg = try await halfRenderer.renderFilmEdge(halfPort, maximum: 1080)
            let halfCrop = half.constrainedCrop(CropSelection(), imageSize: CGSize(width: 600, height: 800))
            let gHalf = FilmEdgeGeometry(imageSize: halfCrop.pixelRect(in: CGSize(width: 600, height: 800)).size,
                                         layout: halfPort.renderedFilmEdgeLayout!, longEdge: 1080)!
            precondition(!gHalf.portrait && halfImg.height > halfImg.width, "3:4 portrait half-frame should sit on horizontal strip")
            let halfUrl = folder.appendingPathComponent("proof-135-half-frame.png")
            let halfDest = CGImageDestinationCreateWithURL(halfUrl as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(halfDest, halfImg, nil); precondition(CGImageDestinationFinalize(halfDest))

            // Calibrated full-frame 135 proof matching P1485707 holder geometry.
            var cal135 = colorRecipe; cal135.filmEdgeSelection = halfSel
            cal135.filmEdgeLayout = FilmEdgeLayout.newDefault()
            cal135.filmEdgeLayout?.scanZoom = 0.78
            let calImg = try await renderer.renderFilmEdge(cal135, maximum: 1440)
            let calUrl = folder.appendingPathComponent("proof-135-calibrated-holder.png")
            let calDest = CGImageDestinationCreateWithURL(calUrl as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(calDest, calImg, nil); precondition(CGImageDestinationFinalize(calDest))

            // Zero-clamping boundary-coded border image: magenta perimeter (outer 2 px), teal interior.
            let bw = 900, bh = 600
            let borderCtx = CGContext(data: nil, width: bw, height: bh, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            borderCtx.setFillColor(CGColor(red: 1.0, green: 0.0, blue: 1.0, alpha: 1))
            borderCtx.fill(CGRect(x: 0, y: 0, width: bw, height: bh))
            borderCtx.setFillColor(CGColor(red: 0.10, green: 0.50, blue: 0.40, alpha: 1))
            borderCtx.fill(CGRect(x: 2, y: 2, width: bw - 4, height: bh - 4))
            let borderCG = borderCtx.makeImage()!
            let borderData = NSMutableData()
            let borderEnc = CGImageDestinationCreateWithData(borderData, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(borderEnc, borderCG, nil); precondition(CGImageDestinationFinalize(borderEnc))
            let borderRenderer = PhotoRenderer(source: borderCG,
                directory: root.appendingPathComponent("SpektraCam/Resources/ModelData"), data: borderData as Data)
            for (gName, cfg) in [
                ("precise", { (l: inout FilmEdgeLayout) in l.gate = FilmEdgeGate(.precise) }),
                ("natural", { (l: inout FilmEdgeLayout) in l.gate = FilmEdgeGate(.natural); l.distress.bulge = 1; l.distress.tilt = 2 }),
                ("loose", { (l: inout FilmEdgeLayout) in l.gate = FilmEdgeGate(.loose); l.distress.bulge = 1; l.distress.tilt = 2 }),
                ("holga", { (l: inout FilmEdgeLayout) in l.format = .roll120; l.rollFrame = .six6; l.rollGate = .toy; l.gate = FilmEdgeGate(.loose); l.distress.bulge = 1 }),
                ("hasselblad", { (l: inout FilmEdgeLayout) in l.format = .roll120; l.rollFrame = .six6; l.rollGate = .hasselblad; l.gate = FilmEdgeGate(.loose); l.distress.bulge = 1 }),
            ] as [(String, (inout FilmEdgeLayout) -> Void)] {
                var br = recipe
                br.look.enabled = false
                var rSel = FilmEdgeSelection(); rSel.mode = .manual; rSel.manualType = .reversalScan
                br.filmEdgeSelection = rSel
                var bl = FilmEdgeLayout.newDefault()
                bl.distress = FilmEdgeDistress()
                cfg(&bl)
                br.filmEdgeLayout = bl
                let outImg = try await borderRenderer.renderFilmEdge(br, maximum: 900)
                let outPx = try PhotoColorBridge.decode(outImg)
                let sq = CropSelection()
                _ = bl.sourceSupport(for: sq, imageSize: CGSize(width: 800, height: 800))
                precondition(sq.normalizedRect == CropSelection.fullImage, "sourceSupport mutated caller CropSelection")
                let supCrop = bl.constrainedCrop(CropSelection(), imageSize: CGSize(width: bw, height: bh))
                let bg = FilmEdgeGeometry(imageSize: supCrop.pixelRect(in: CGSize(width: bw, height: bh)).size,
                                          layout: br.renderedFilmEdgeLayout!, longEdge: max(outImg.width, outImg.height))!
                var magentaPixels = 0
                for y in 0..<bg.height {
                    for x in 0..<bg.width where bg.gateCoverage(x: x, y: y) > 0.5 {
                        let p = outPx[y * bg.width + x]
                        if p.x > 0.7 && p.z > 0.7 && p.y < 0.25 { magentaPixels += 1 }
                    }
                }
                precondition(magentaPixels == 0, "Gate \(gName) clamped \(magentaPixels) outermost border pixels into aperture")
            }
        }

        // Stage 3: Unified Burn preset, coverage 0/35/100%, legacy burn migration, and continuous cross-gate
        // burn across all 5 edge types for Original, LUT, and partial Mix.
        do {
            let leaky = FilmEdgeDistress.Preset.leaky.values
            precondition(
                leaky.leakShape == .burn && abs(leaky.burnCoverage - 0.35) < 1e-9
                    && abs(leaky.leak - 0.7) < 1e-9 && abs(leaky.warmth - 0.7) < 1e-9,
                "Preset.leaky defaults unexpected")
            let legacyBurn = try JSONDecoder().decode(
                FilmEdgeLayout.self,
                from: Data(#"{"format":"film35","distress":{"leakShape":"burn","leakSize":13.6,"leakPosition":0.3}}"#.utf8))
            precondition(abs(legacyBurn.distress.burnCoverage - 0.35) < 1e-6,
                         "Legacy .burn leakSize migration mismatch: \(legacyBurn.distress.burnCoverage)")

            var zeroCov = FilmEdgeLayout(); zeroCov.distress.apply(.leaky); zeroCov.distress.burnCoverage = 0
            var midCov = zeroCov; midCov.distress.burnCoverage = 0.35
            var fullCov = zeroCov; fullCov.distress.burnCoverage = 1.0
            let g0 = FilmEdgeGeometry(imageSize: CGSize(width: 900, height: 600), layout: zeroCov, longEdge: 720)!
            let gMid = FilmEdgeGeometry(imageSize: CGSize(width: 900, height: 600), layout: midCov, longEdge: 720)!
            let gFull = FilmEdgeGeometry(imageSize: CGSize(width: 900, height: 600), layout: fullCov, longEdge: 720)!
            precondition(g0.burnFrontDepth < -50 && g0.burnLightAt(filmX: 0, filmY: 0) == .zero)
            precondition(abs(gMid.burnFrontDepth - (1.0 + 0.35 * 36.0)) < 1e-6, "35% burnFrontDepth \(gMid.burnFrontDepth)")
            precondition(gFull.burnLightAt(filmX: 0, filmY: 0).x > 50)

            for type in FilmEdgeType.allCases {
                for (routeName, configure) in [
                    ("original", { (r: inout EditRecipe) in r.look.enabled = false }),
                    ("lut", { (r: inout EditRecipe) in r.look.enabled = true; r.look.mode = .lut; r.look.first.id = lutID }),
                    ("mix50", { (r: inout EditRecipe) in r.look.enabled = true; r.look.mode = .spektrafilm; r.mix = 0.5 }),
                ] as [(String, (inout EditRecipe) -> Void)] {
                    var r = colorRecipe
                    configure(&r)
                    var sel = FilmEdgeSelection(); sel.mode = .manual; sel.manualType = type
                    r.filmEdgeSelection = sel
                    r.filmEdgeLayout = FilmEdgeLayout.newDefault()
                    if type == .negativePrint { r.filmEdgeLayout?.printZoom = 0.90 } else { r.filmEdgeLayout?.scanZoom = 0.78 }
                    r.filmEdgeLayout?.gate = FilmEdgeGate(.precise)
                    r.filmEdgeLayout?.distress.apply(.leaky)
                    r.filmEdgeLayout?.distress.leak = 0.9
                    r.filmEdgeLayout?.distress.burnCoverage = 0.30
                    r.filmEdgeLayout?.distress.leakPosition = 0.80
                    r.filmEdgeLayout?.distress.scratches = 0
                    r.filmEdgeLayout?.distress.holeVariation = 0
                    let cg = try await lutRenderer.renderFilmEdge(r, maximum: 1080)
                    let px = try PhotoColorBridge.decode(cg)
                    let crop = r.filmEdgeLayout!.constrainedCrop(CropSelection(), imageSize: CGSize(width: 900, height: 600))
                    let g = FilmEdgeGeometry(imageSize: crop.pixelRect(in: CGSize(width: 900, height: 600)).size,
                                             layout: r.renderedFilmEdgeLayout!, longEdge: max(cg.width, cg.height),
                                             easel: PrintLayout())!
                    let sx = Int(g.gate.minX) + max(8, Int(2.0 / g.millimetersPerPixel))
                    let py = g.height / 2
                    let ry = max(2, Int(g.gate.minY) - max(3, Int(0.35 / g.millimetersPerPixel)))
                    let pc = px[py * g.width + sx], rc = px[ry * g.width + sx]
                    let diff = max(abs(pc.x - rc.x), abs(pc.y - rc.y), abs(pc.z - rc.z))
                    if type == .negativeScan {
                        precondition(pc.x < 0.14 && pc.z < 0.14 && diff < 0.04,
                            "\(routeName)+\(type) did not produce dark negative burn matching rebate: pic \(pc) rebate \(rc)")
                    } else if type != .negativePrint || r.filmEdgeLayout!.printZoom <= 0.92 {
                        precondition(diff < 0.04 && (pc.x > 0.55 || pc.y > 0.35),
                            "\(routeName)+\(type) diverged across gate: pic \(pc) rebate \(rc)")
                    }
                    if routeName == "original" && (type == .negativeScan || type == .cinemaPrint || type == .negativePrint) {
                        let url = folder.appendingPathComponent("proof-original-\(type.rawValue)-burn.png")
                        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
                        CGImageDestinationAddImage(dest, cg, nil); precondition(CGImageDestinationFinalize(dest))
                    }
                }
            }
        }

        // Loupe patch (`renderEdgeDetail`) vs native whole-frame red-channel parity at Dust 0% and 100%
        // (0/255 on a flat midtone + neutral distress; <= 1/255 across the tilted Lab Scan red/green step edge)
        // + first-tap pixel difference for all 4 leak shapes.
        do {
            let flatCtx = CGContext(data: nil, width: 900, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            flatCtx.setFillColor(CGColor(red: 0.48, green: 0.48, blue: 0.48, alpha: 1))
            flatCtx.fill(CGRect(x: 0, y: 0, width: 900, height: 600))
            let flatCG = flatCtx.makeImage()!
            let flatEncoded = NSMutableData()
            let flatDest = CGImageDestinationCreateWithData(flatEncoded, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(flatDest, flatCG, nil); precondition(CGImageDestinationFinalize(flatDest))
            let flatLoupeRenderer = PhotoRenderer(
                source: flatCG, directory: root.appendingPathComponent("SpektraCam/Resources/ModelData"),
                data: flatEncoded as Data, previewMaximum: 360)

            let loupeRenderer = PhotoRenderer(
                source: source, directory: root.appendingPathComponent("SpektraCam/Resources/ModelData"),
                data: encoded as Data, previewMaximum: 360)
            var lr = EditRecipe(); lr.look.enabled = false
            lr.flags["camera.auto_exposure"] = false
            lr.flags["film_render.grain.active"] = false
            lr.flags["camera.diffusion_filter.active"] = false
            lr.flags["print_render.glare.active"] = false
            lr.numbers["scanner.lens_blur"] = 0
            lr.numbers["scanner.unsharp_mask[1]"] = 0
            let visibleRegion = CGRect(x: 0.25, y: 0.25, width: 0.35, height: 0.35)

            func maxRedDifference(renderer rdr: PhotoRenderer, recipe rcp: EditRecipe) async throws -> Int {
                let full = try await rdr.renderFilmEdge(rcp, maximum: nil)
                let fullBytes = pixels8(full)
                let detail = try await rdr.renderEdgeDetail(rcp, visible: visibleRegion)!
                let patchBytes = pixels8(detail.image)
                let ox = Int((detail.rect.minX * Double(full.width)).rounded())
                let oy = Int((detail.rect.minY * Double(full.height)).rounded())
                var maxRedDiff = 0
                for y in 0..<detail.image.height {
                    for x in 0..<detail.image.width {
                        let fx = ox + x, fy = oy + y
                        guard fx >= 0, fx < full.width, fy >= 0, fy < full.height else { continue }
                        let fi = (fy * full.width + fx) * 4
                        let pi = (y * detail.image.width + x) * 4
                        maxRedDiff = max(maxRedDiff, abs(Int(fullBytes[fi]) - Int(patchBytes[pi])))
                    }
                }
                return maxRedDiff
            }

            var flatLayout = FilmEdgeLayout.newDefault(seed: 21)
            flatLayout.distress = FilmEdgeDistress()
            flatLayout.distress.seed = 21
            flatLayout.printZoom = 0.985; flatLayout.scanZoom = 0.90

            var tiltedLayout = FilmEdgeLayout.newDefault(seed: 21)
            tiltedLayout.distress = FilmEdgeDistress.Preset.lab.values(seed: 21)
            tiltedLayout.printZoom = 0.985; tiltedLayout.scanZoom = 0.90

            for type in [FilmEdgeType.negativePrint, .cinemaPrint] {
                var lSel = FilmEdgeSelection(); lSel.mode = .manual; lSel.manualType = type
                lr.filmEdgeSelection = lSel
                for dustVal in [0.0, 1.0] {
                    lr.filmEdgeLayout = flatLayout
                    lr.filmEdgeLayout?.distress.dust = dustVal
                    let flatDiff = try await maxRedDifference(renderer: flatLoupeRenderer, recipe: lr)
                    precondition(flatDiff == 0,
                        "Flat midtone loupe vs whole-frame diverged on \(type) Dust=\(dustVal): max red diff \(flatDiff)/255")

                    lr.filmEdgeLayout = tiltedLayout
                    lr.filmEdgeLayout?.distress.dust = dustVal
                    let tiltedDiff = try await maxRedDifference(renderer: loupeRenderer, recipe: lr)
                    precondition(tiltedDiff <= 1,
                        "Tilted Lab loupe vs whole-frame diverged on \(type) Dust=\(dustVal): max red diff \(tiltedDiff)/255")
                }
            }
            var baselineNeutral = recipe
            var nSel = FilmEdgeSelection(); nSel.mode = .manual; nSel.manualType = .negativeScan
            baselineNeutral.filmEdgeSelection = nSel
            baselineNeutral.filmEdgeLayout = FilmEdgeLayout.newDefault(seed: 21)
            let offPx = pixels8(try await renderer.renderFilmEdge(baselineNeutral, maximum: 480))
            for shape in FilmEdgeDistress.LeakShape.allCases {
                var onRecipe = baselineNeutral
                onRecipe.filmEdgeLayout?.distress.toggleLeakShape(shape)
                let onPx = pixels8(try await renderer.renderFilmEdge(onRecipe, maximum: 480))
                var changed = 0
                for idx in offPx.indices where abs(Int(onPx[idx]) - Int(offPx[idx])) > 2 { changed += 1 }
                precondition(changed > 100, "Tapping \(shape) produced negligible visual difference (\(changed) channels)")

                var rerolledRecipe = onRecipe
                let prevTilt = rerolledRecipe.filmEdgeLayout!.distress.tilt
                let prevBulge = rerolledRecipe.filmEdgeLayout!.distress.bulge
                rerolledRecipe.filmEdgeLayout?.distress.rerollLeak(seed: 777)
                precondition(
                    rerolledRecipe.filmEdgeLayout?.distress.tilt == prevTilt
                        && rerolledRecipe.filmEdgeLayout?.distress.bulge == prevBulge,
                    "rerollLeak mutated tilt or bulge on \(shape)")
                let rerolledPx = pixels8(try await renderer.renderFilmEdge(rerolledRecipe, maximum: 480))
                var rerollChanged = 0
                for idx in onPx.indices where abs(Int(rerolledPx[idx]) - Int(onPx[idx])) > 2 { rerollChanged += 1 }
                precondition(rerollChanged > 80, "rerollLeak on \(shape) produced negligible pixel change (\(rerollChanged))")
            }

            // Consecutive Burn dice taps must never collide on either seed or leakPosition,
            // and v1.1 Darkroom defaults (printZoom = 0.93, labTilt in ±0.25°, holeVariation 25%/50%) must hold.
            precondition(abs(FilmEdgeLayout().printZoom - 0.93) < 1e-9, "Default printZoom should be 0.93")
            precondition(abs(FilmEdgeDistress.Preset.clean.values.holeVariation - 0.25) < 1e-9)
            precondition(abs(FilmEdgeDistress.Preset.lab.values.holeVariation - 0.25) < 1e-9)
            precondition(abs(FilmEdgeDistress.Preset.leaky.values.holeVariation - 0.25) < 1e-9)
            precondition(abs(FilmEdgeDistress.Preset.worn.values.holeVariation - 0.50) < 1e-9)
            for s in UInt32(1)...200 {
                let t = FilmEdgeDistress.Preset.lab.values(seed: s).tilt
                precondition(abs(t) <= 0.25 + 1e-9, "Lab scan tilt \(t) exceeded ±0.25° for seed \(s)")
            }
            var burnDice = FilmEdgeDistress()
            burnDice.toggleLeakShape(.burn)
            for _ in 0..<50 {
                let prevSeed = burnDice.seed
                let prevPos = burnDice.leakPosition
                burnDice.rerollLeak()
                precondition(
                    burnDice.seed != prevSeed && burnDice.leakPosition != prevPos,
                    "Burn rerollLeak collided: seed \(prevSeed)->\(burnDice.seed), pos \(prevPos)->\(burnDice.leakPosition)")
            }

            // Default Lab Scan (`scratches = 0.10`, `edgeFog = 0.20`, `printZoom = 0.93`, `scanZoom = 0.90`) must render
            // clearly visible rebate scratches at 1080 px preview resolution on both RA-4 print and scan across seeds,
            // as well as on composed B&W/LUT routes.
            for seed in [UInt32(1), 7, 11] {
                for edgeType in [FilmEdgeType.negativePrint, .invertedScan] {
                    var withScratch = settled
                    var sel = FilmEdgeSelection(); sel.mode = .manual; sel.manualType = edgeType
                    withScratch.filmEdgeSelection = sel
                    withScratch.filmEdgeLayout = FilmEdgeLayout.newDefault(seed: seed)
                    withScratch.flags["film_render.grain.active"] = false
                    var withoutScratch = withScratch
                    withoutScratch.filmEdgeLayout?.distress.scratches = 0
                    let imgWith = try await large.renderFilmEdge(withScratch, maximum: 1080)
                    let imgWithout = try await large.renderFilmEdge(withoutScratch, maximum: 1080)
                    let pxWith = pixels8(imgWith)
                    let pxWithout = pixels8(imgWithout)
                    precondition(pxWith.count == pxWithout.count)
                    var visibleScratchPixels = 0
                    var peakDelta = 0
                    for p in 0..<(pxWith.count / 4) {
                        let i = p * 4
                        let d = max(
                            abs(Int(pxWith[i]) - Int(pxWithout[i])),
                            abs(Int(pxWith[i + 1]) - Int(pxWithout[i + 1])),
                            abs(Int(pxWith[i + 2]) - Int(pxWithout[i + 2]))
                        )
                        if d >= 4 { visibleScratchPixels += 1 }
                        if d > peakDelta { peakDelta = d }
                    }
                    precondition(
                        visibleScratchPixels >= 15 && peakDelta >= 6,
                        "Default Lab Scan scratches vanished on \(edgeType) seed=\(seed) at 1080 px: \(visibleScratchPixels) px >= 4/255, peak \(peakDelta)/255")
                }
            }
            do {
                var bwScratch = recipe
                var sel = FilmEdgeSelection(); sel.mode = .manual; sel.manualType = .negativePrint
                bwScratch.filmEdgeSelection = sel
                bwScratch.filmEdgeLayout = FilmEdgeLayout.newDefault(seed: 7)
                var bwClean = bwScratch
                bwClean.filmEdgeLayout?.distress.scratches = 0
                let pxWith = pixels8(try await renderer.renderFilmEdge(bwScratch, maximum: 1080))
                let pxWithout = pixels8(try await renderer.renderFilmEdge(bwClean, maximum: 1080))
                var peakBW = 0
                for idx in pxWith.indices { peakBW = max(peakBW, abs(Int(pxWith[idx]) - Int(pxWithout[idx]))) }
                precondition(peakBW >= 2, "Composed B&W 540 px Lab Scan scratches vanished: peak \(peakBW)/255")

                var bwLarge = settled
                bwLarge.tone.monochrome = true
                var selScan = FilmEdgeSelection(); selScan.mode = .manual; selScan.manualType = .invertedScan
                bwLarge.filmEdgeSelection = selScan
                bwLarge.filmEdgeLayout = FilmEdgeLayout.newDefault(seed: 1)
                var bwLargeClean = bwLarge
                bwLargeClean.filmEdgeLayout?.distress.scratches = 0
                let pxLargeWith = pixels8(try await large.renderFilmEdge(bwLarge, maximum: 1080))
                let pxLargeWithout = pixels8(try await large.renderFilmEdge(bwLargeClean, maximum: 1080))
                var peakBWLarge = 0
                for idx in pxLargeWith.indices { peakBWLarge = max(peakBWLarge, abs(Int(pxLargeWith[idx]) - Int(pxLargeWithout[idx]))) }
                precondition(peakBWLarge >= 6, "Composed B&W 1080 px Lab Scan scratches vanished: peak \(peakBWLarge)/255")
            }
            // Seam-free max Edge Fog (100%): no centerline discontinuity on Film Edge (135/120) or Clean Print,
            // plus Clean Print vs Film Edge edgeFog/perforationFog/autoEV/B&W consistency and 2160 px Burn speed.
            do {
                var maxFog = FilmEdgeDistress(); maxFog.seed = 3; maxFog.edgeFog = 1.0
                var fog35 = FilmEdgeLayout.newDefault(seed: 3); fog35.distress = maxFog
                var fog120 = FilmEdgeLayout.newDefault(seed: 3); fog120.format = .roll120; fog120.rollFrame = .six7; fog120.distress = maxFog
                let size120 = fog120.constrainedCrop(CropSelection(), imageSize: CGSize(width: 1000, height: 800))
                    .pixelRect(in: CGSize(width: 1000, height: 800)).size
                for gFog in [
                    FilmEdgeGeometry(imageSize: CGSize(width: 900, height: 600), layout: fog35, longEdge: 720)!,
                    FilmEdgeGeometry(imageSize: size120, layout: fog120, longEdge: 720)!,
                    FilmEdgeGeometry(cleanPrintSize: CGSize(width: 1200, height: 800), distress: maxFog, longEdge: 720)!,
                ] {
                    let cy = gFog.height / 2
                    let sampleX = gFog.width / 2
                    let stepA = abs(gFog.exposureFields(x: sampleX, y: cy).fog - gFog.exposureFields(x: sampleX, y: cy - 1).fog)
                    let stepB = abs(gFog.exposureFields(x: sampleX, y: cy + 1).fog - gFog.exposureFields(x: sampleX, y: cy).fog)
                    precondition(max(stepA, stepB) < 0.005, "Max edgeFog centerline discontinuity: stepA=\(stepA), stepB=\(stepB)")
                }

                // Compare Clean Print vs Film Edge at edgeFog = 0.20 (Lab) and 0.60 across picture boundary.
                for fogLevel in [0.20, 0.60] {
                    var fogDistress = FilmEdgeDistress(); fogDistress.seed = 5; fogDistress.edgeFog = fogLevel
                    var edgeL = FilmEdgeLayout.newDefault(seed: 5); edgeL.distress = fogDistress
                    let gEdge = FilmEdgeGeometry(imageSize: CGSize(width: 900, height: 600), layout: edgeL, longEdge: 720)!
                    let gClean = FilmEdgeGeometry(cleanPrintSize: CGSize(width: 900, height: 600), distress: fogDistress, longEdge: 720)!
                    let cleanEdgeFog = gClean.exposureFields(x: gClean.width / 2, y: 2).fog
                    let filmPictureEdgeY = Int(gEdge.gate.minY) + 2
                    let filmEdgeFog = gEdge.exposureFields(x: gEdge.width / 2, y: filmPictureEdgeY).fog
                    let ratio = cleanEdgeFog / max(filmEdgeFog, 1e-6)
                    precondition(ratio > 0.7 && ratio < 1.35,
                        "Clean print edgeFog=\(fogLevel) diverged from Film Edge: clean=\(cleanEdgeFog), film=\(filmEdgeFog), ratio=\(ratio)")
                    precondition(gClean.perforationFogExposure(x: gClean.width / 2, y: 2) > 0,
                        "3:2 Clean print lost perforation fog at edgeFog=\(fogLevel)")
                }
                for nonRectSize in [CGSize(width: 1000, height: 1000), CGSize(width: 1200, height: 900)] {
                    var fog1 = FilmEdgeDistress(); fog1.seed = 9; fog1.edgeFog = 1.0
                    let gRect = FilmEdgeGeometry(cleanPrintSize: nonRectSize, distress: fog1, longEdge: 600)!
                    var midPerf = 0.0, edgePerf = 0.0
                    for y in 0..<gRect.height {
                        precondition(gRect.supportCoverage(x: gRect.width / 2, y: y) == 1.0, "Clean print punched sprocket holes")
                        let v = gRect.perforationFogExposure(x: gRect.width / 2, y: y)
                        if abs(Double(y) - Double(gRect.height) / 2) < Double(gRect.height) * 0.25 {
                            midPerf = max(midPerf, v)
                        } else {
                            edgePerf = max(edgePerf, v)
                        }
                    }
                    precondition(midPerf == 0 && edgePerf > 0.01,
                        "Clean print \(nonRectSize) perforation fog misplaced: mid=\(midPerf), edge=\(edgePerf)")
                }

                // Render check: flat mid-grey at edgeFog = 1.0 has no midline seam, B&W Burn stays neutral monochrome,
                // Spektrafilm with high autoEV doesn't over-amplify Clean Print fog, and 2160px Burn is fast.
                var bwBurn = recipe
                bwBurn.look.enabled = false
                bwBurn.tone.monochrome = true
                bwBurn.filmEdgeLayout = nil
                var burnD = FilmEdgeDistress.cleanPrintFallback
                burnD.applyCleanPrintPreset(.leaky)
                burnD.leak = 0.8
                burnD.burnCoverage = 0.45
                bwBurn.distress = burnD
                let bwBurnImg = try await renderer.renderPresentation(bwBurn, maximum: 720)
                let bwPx = pixels8(bwBurnImg)
                var maxChroma = 0
                for p in 0..<(bwPx.count / 4) {
                    let i = p * 4
                    let spread = max(bwPx[i], bwPx[i + 1], bwPx[i + 2]) - min(bwPx[i], bwPx[i + 1], bwPx[i + 2])
                    maxChroma = max(maxChroma, Int(spread))
                }
                precondition(maxChroma <= 2, "B&W Clean Print burn left colored fringe: \(maxChroma)/255")

                // Dark Spektrafilm input with positive exposureCompensationEV (+2.5 EV): Clean Print edgeFog=0.20
                // must match Film Edge picture-interior edgeFog (sceneExposureScale must prevent EV blow-up).
                do {
                    let evCtx = CGContext(data: nil, width: 900, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                    evCtx.setFillColor(CGColor(red: 0.14, green: 0.14, blue: 0.14, alpha: 1))
                    evCtx.fill(CGRect(x: 0, y: 0, width: 900, height: 600))
                    let evCG = evCtx.makeImage()!
                    let evData = NSMutableData()
                    let evDest = CGImageDestinationCreateWithData(evData, UTType.png.identifier as CFString, 1, nil)!
                    CGImageDestinationAddImage(evDest, evCG, nil); precondition(CGImageDestinationFinalize(evDest))
                    let evRenderer = PhotoRenderer(
                        source: evCG, directory: root.appendingPathComponent("SpektraCam/Resources/ModelData"),
                        data: evData as Data)
                    var evBase = recipe
                    evBase.numbers["camera.exposure_compensation_ev"] = 2.5
                    var evDistress = FilmEdgeDistress.cleanPrintFallback
                    evDistress.seed = 5
                    evDistress.edgeFog = 0.20

                    var evClean = evBase
                    evClean.filmEdgeLayout = nil
                    evClean.distress = evDistress
                    let evCleanImg = try await evRenderer.renderPresentation(evClean, maximum: 540)
                    let evCleanPx = try PhotoColorBridge.decode(evCleanImg)

                    var evFilm = evBase
                    var evLayout = FilmEdgeLayout.newDefault(seed: 5)
                    evLayout.distress = evDistress
                    evFilm.filmEdgeLayout = evLayout
                    var evSel = FilmEdgeSelection(); evSel.mode = .manual; evSel.manualType = .negativePrint
                    evFilm.filmEdgeSelection = evSel
                    let evFilmImg = try await evRenderer.renderFilmEdge(evFilm, maximum: 540)
                    let evFilmPx = try PhotoColorBridge.decode(evFilmImg)
                    let gEv = FilmEdgeGeometry(
                        imageSize: CGSize(width: 900, height: 600),
                        layout: evFilm.renderedFilmEdgeLayout!, longEdge: max(evFilmImg.width, evFilmImg.height))!
                    let cleanTop = evCleanPx[4 * evCleanImg.width + evCleanImg.width / 2]
                    let filmTop = evFilmPx[(Int(gEv.gate.minY) + 4) * evFilmImg.width + evFilmImg.width / 2]
                    let evLumDiff = abs(((cleanTop.x + cleanTop.y + cleanTop.z) - (filmTop.x + filmTop.y + filmTop.z)) / 3.0)
                    precondition(
                        evLumDiff < 0.06,
                        "Positive EV blew out Clean Print edgeFog vs Film Edge: clean=\(cleanTop) film=\(filmTop)")
                }

                let burnStart = ProcessInfo.processInfo.systemUptime
                var hiBurn = recipe
                hiBurn.look.enabled = false
                hiBurn.filmEdgeLayout = nil
                hiBurn.distress = burnD
                let hiBurnImg = try await large.renderPresentation(hiBurn, maximum: 2160)
                let burnMs = (ProcessInfo.processInfo.systemUptime - burnStart) * 1000
                precondition(hiBurnImg.width > 0 && burnMs < 1500, "2160px Burn took too long: \(burnMs) ms")
                print(String(format: "PASS: 2160px Clean Print Burn rendered in %.1f ms", burnMs))
            }
            do {
                var cleanBase = recipe
                cleanBase.crop = CropSelection()
                cleanBase.filmEdgeLayout = nil
                cleanBase.distress = nil
                var cleanLeak = cleanBase
                var distress = FilmEdgeDistress.cleanPrintFallback
                distress.applyCleanPrintPreset(.leaky)
                distress.dust = 0.8
                distress.scratches = 0.9
                cleanLeak.distress = distress
                precondition(!distress.scratchesInImage, "Clean-print distress enabled scratchesInImage by default")
                let basePresentation = try await renderer.renderPresentation(cleanBase, maximum: 720)
                let leakPresentation = try await renderer.renderPresentation(cleanLeak, maximum: 720)
                // Clean print with only scratches > 0 and scratchesInImage == false must keep scratches off the photo.
                var scratchesOffOnly = cleanBase
                var offDistress = FilmEdgeDistress.cleanPrintFallback
                offDistress.scratches = 0.9
                scratchesOffOnly.distress = offDistress
                let scratchesOffImg = try await renderer.renderPresentation(scratchesOffOnly, maximum: 720)
                var inPhotoDistress = offDistress
                inPhotoDistress.scratchesInImage = true
                var scratchesOnOnly = cleanBase
                scratchesOnOnly.distress = inPhotoDistress
                let scratchesOnImg = try await renderer.renderPresentation(scratchesOnOnly, maximum: 720)
                let offPx = pixels8(scratchesOffImg)
                let onPx = pixels8(scratchesOnImg)
                var scratchDelta = 0
                for idx in offPx.indices { scratchDelta = max(scratchDelta, abs(Int(onPx[idx]) - Int(offPx[idx]))) }
                precondition(scratchDelta >= 12, "Turning scratchesInImage on did not render Clean-print scratches: peak \(scratchDelta)/255")
                precondition(
                    basePresentation.width == leakPresentation.width && basePresentation.height == leakPresentation.height,
                    "Clean-print distress changed canvas size: \(basePresentation.width)x\(basePresentation.height) vs \(leakPresentation.width)x\(leakPresentation.height)")
                let pxBase = pixels8(basePresentation)
                let pxLeak = pixels8(leakPresentation)
                var changed = 0
                for p in 0..<(pxBase.count / 4) {
                    let i = p * 4
                    if abs(Int(pxLeak[i]) - Int(pxBase[i])) >= 12
                        || abs(Int(pxLeak[i + 1]) - Int(pxBase[i + 1])) >= 12
                        || abs(Int(pxLeak[i + 2]) - Int(pxBase[i + 2])) >= 12
                    {
                        changed += 1
                    }
                }
                precondition(changed >= 200, "Clean-print distress had too little effect: \(changed) px")

                // Cropped Clean print export matches un-distressed cropped export dimensions.
                var croppedBase = recipe
                croppedBase.filmEdgeLayout = nil
                croppedBase.distress = nil
                var croppedLeak = croppedBase
                croppedLeak.distress = distress
                let (baseURL, baseW, baseH) = try await renderer.export(croppedBase, size: .longEdge(720), format: .png, quality: 0.9)
                let (leakURL, leakW, leakH) = try await renderer.export(croppedLeak, size: .longEdge(720), format: .png, quality: 0.9)
                try? FileManager.default.removeItem(at: baseURL)
                try? FileManager.default.removeItem(at: leakURL)
                precondition(baseW == leakW && baseH == leakH, "Cropped clean-print distress export changed size: \(baseW)x\(baseH) vs \(leakW)x\(leakH)")

                var printWithPaper = cleanLeak
                var paper = PrintLayout(); paper.paper = .fiveBySeven; paper.margin = 0.06
                printWithPaper.printLayout = paper
                let (exportedURL, exportW, exportH) = try await renderer.export(
                    printWithPaper, size: .longEdge(900), format: .png, quality: 0.9)
                try? FileManager.default.removeItem(at: exportedURL)
                precondition(max(exportW, exportH) == 900, "Clean-print distressed paper export unexpected size: \(exportW)x\(exportH)")
            }
        }

        // Cold-start Original + Clean Print dust must not load spectral model or Metal pipeline.
        let coldResources = FilmRenderResources(directory: root.appendingPathComponent("SpektraCam/Resources/ModelData"))
        let coldRenderer = PhotoRenderer(
            source: source, directory: root.appendingPathComponent("SpektraCam/Resources/ModelData"),
            data: encoded as Data, resources: coldResources)
        var dustOnly = EditRecipe()
        dustOnly.look.enabled = false
        var dustDistress = FilmEdgeDistress.cleanPrintFallback
        dustDistress.dust = 0.45
        dustOnly.distress = dustDistress
        _ = try await coldRenderer.renderPresentation(dustOnly, maximum: 720)
        let resourcesLoaded = await coldResources.isLoaded
        precondition(!resourcesLoaded, "Cold-start Original + dust loaded FilmRenderResources unnecessarily")

        print("PASS: grain-enabled 720→2160 full-support refinement. Quick ms \(quickMS), settled ms \(refineMS); no silent resolution reduction")
        print("PASS: real source → four families → saved recipe → paper/B&W → matching PNG export; creative/LUT gate without rim or seam, leaks through LUT pictures; export sizes (crop, percent, long edge, print, native paper); cancellation recovery; native output bounded. Workflow \((ProcessInfo.processInfo.systemUptime - started) * 1000) ms; proof PNGs \(folder.path)")
    }

    static func pixels8(_ image: CGImage) -> [UInt8] {
        let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(
            start: context.data!.assumingMemoryBound(to: UInt8.self),
            count: image.width * image.height * 4))
    }
}
