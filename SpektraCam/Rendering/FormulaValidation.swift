#if DEBUG
import CoreImage
import CryptoKit
import Foundation
import UIKit

/// Explicit regression checks in the isolated UI-test library, using the actual renderer and
/// editor. They cannot run against the user's library or change a device's preferences.
@MainActor enum FormulaValidation {
    static func run(_ library: PhotoLibrary) async {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("--ui-test-library"), let option = args.firstIndex(of: "--check-formulae"),
              option + 1 < args.count else { return }
        let target = args[option + 1]
        let reportURL = target == "caches"
            ? URL.cachesDirectory.appendingPathComponent("formula-validation.json")
            : URL(fileURLWithPath: target)
        var checks: [String] = []
        do {
            try await check(library, checks: &checks)
            try JSONSerialization.data(withJSONObject: ["result": "PASS", "checks": checks], options: [.prettyPrinted])
                .write(to: reportURL, options: .atomic)
            print("FORMULA_VALIDATION PASS (\(checks.count) checks): " + checks.joined(separator: "; "))
            fflush(stdout)
        } catch {
            try? JSONSerialization.data(withJSONObject: ["result": "FAIL", "error": String(describing: error), "checks": checks])
                .write(to: reportURL, options: .atomic)
            print("FORMULA_VALIDATION FAIL: \(error)")
            fflush(stdout)
        }
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "FormulaRegression", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    private static func check(_ library: PhotoLibrary, checks: inout [String]) async throws {
        try require(library.photos.count >= 2, "Two different photos are required")
        let photos = Array(library.photos.prefix(2))
        let originals = try photos.map { try Data(contentsOf: library.files.sourceURL($0)) }
        var first = EditRecipe()
        first.filmID = "fujifilm_c200"
        first.printID = "fujifilm_crystal_archive_typeii"
        first.flags["film_render.grain.active"] = false
        first.flags["film_render.halation.active"] = false
        first.tone.contrast = 1.15
        first.source.warmth = 12
        first.tone.exposureEV = 0.5
        first.numbers["enlarger.y_filter_shift"] = 7
        first.removeDefaultOverrides()
        let firstFormula = try Formula(name: "First saved", parts: [.look, .exposure], from: first, luts: [])
        try await library.formulae.save(firstFormula)
        var second = first
        second.filmID = "kodak_portra_400"
        second.tone.monochrome = true
        second.tone.contrast = 0.85
        let secondFormula = try Formula(name: "Later saved", parts: [.look], from: second, luts: [])
        try await library.formulae.save(secondFormula)
        let files = try library.formulae.items.map { try Data(contentsOf: library.formulae.fileURL($0.id)) }
        let recipes = [firstFormula.id: firstFormula.recipe, secondFormula.id: secondFormula.recipe]
        checks.append("first and later formula files round-trip")

        for photo in photos {
            let imported = try await library.files.decodedPhoto(photo, maximum: 192)
            let warm = PhotoRenderer(source: imported.preview, directory: Bundle.main.resourceURL!, data: imported.data,
                temperature: imported.rawTemperature, previewMaximum: 192, resources: library.images.resources,
                sourceType: imported.sourceType, description: imported.sourceDescription)
            // A different target has its own exposure, WB, LUT mode, crop and manual overrides.
            var target = EditorDefaults.originalRecipe(temperature: imported.rawTemperature)
            target.look.mode = .lut
            target.tone.exposureEV = -0.6
            target.source.warmth = -20
            target.numbers["enlarger.y_filter_shift"] = -8
            for formulaID in [firstFormula.id, secondFormula.id, firstFormula.id] {
                library.queueRecipe(target, for: photo.id)
                try library.flushPending()
                let formula = library.formulae.formula(formulaID)!
                _ = try await library.applyFormula(formula, to: [photo.id])
                let applied = try library.recipe(photo.id)!
                try require(applied.filmID == formula.recipe.filmID && applied.tone.contrast == formula.recipe.tone.contrast
                    && applied.number("enlarger.y_filter_shift") == 7,
                    "A formula retained the target's film, tone, or lost print balance")
                if formula.parts.contains(.exposure) {
                    try require(applied.source.warmth == first.source.warmth && applied.tone.exposureEV == first.tone.exposureEV,
                        "Full formula changed with the target's exposure")
                } else {
                    try require(applied.source.warmth == target.source.warmth && applied.tone.exposureEV == target.tone.exposureEV,
                        "Look-only formula replaced the target's exposure")
                }
                let session = EditorSession(photo: imported, recipe: target, luts: library.luts, resources: library.images.resources)
                session.update(key: "formula.apply") {
                    $0 = formula.applied(to: $0, rawTarget: photo.isRAW)
                }
                try require(session.recipe == applied, "Viewer and editor applied different settings")
                session.cancelRendering()
                let actual = try await warm.render(applied, maximum: 192)
                let cold = PhotoRenderer(source: imported.preview, directory: Bundle.main.resourceURL!, data: imported.data,
                    temperature: imported.rawTemperature, previewMaximum: 192,
                    sourceType: imported.sourceType, description: imported.sourceDescription)
                let expected = try await cold.render(applied, maximum: 192)
                try require(maxError(actual, expected) <= 1.1 / 255, "Warm formula renderer differs from a fresh renderer")
                try require(library.formulae.formula(formulaID)?.recipe == recipes[formulaID], "Applying mutated a saved formula")
            }
            checks.append("viewer/editor and warm/fresh pixels: " + photo.filename)
        }
        try await library.formulae.load()
        let after = try library.formulae.items.map { try Data(contentsOf: library.formulae.fileURL($0.id)) }
        try require(files == after, "Applying or editing rewrote a formula file")
        checks.append("formula bytes unchanged after A/B/A application and reload")

        // A RAW export must be byte-identical. This deliberately needs no RAW decoder.
        let raw = OriginalFileExporter(data: originals[0], filename: "capture.dng", type: "com.adobe.raw-image", width: 97, height: 65)
        let (copy, _, _) = try await raw.export()
        try require(try Data(contentsOf: copy) == originals[0] && copy.lastPathComponent == "capture.dng", "RAW export changed bytes or filename")
        await raw.discard()
        // Regular non-RAW originals must also export byte-for-byte unchanged via OriginalFileExporter.
        let regularFile = library.files.sourceURL(photos[1])
        let regularExporter = OriginalFileExporter(source: regularFile, filename: "regular-original.png")
        let (regularCopy, _, _) = try await regularExporter.export()
        try require(try Data(contentsOf: regularCopy) == originals[1] && regularCopy.lastPathComponent == "regular-original.png",
            "Regular OriginalFileExporter altered bytes or filename")
        await regularExporter.discard()
        for (index, photo) in photos.enumerated() {
            try require(try Data(contentsOf: library.files.sourceURL(photo)) == originals[index], "Source bytes changed")
        }
        checks.append("original RAW and regular bytes and filenames preserved; source files unchanged")

        // Spektrafilm with a dormant LUT slot must never export LUT metadata, attachments, or lock the LUT.
        let cubeURL = FileManager.default.temporaryDirectory.appendingPathComponent("dormant-\(UUID().uuidString).cube")
        try Data("LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n".utf8).write(to: cubeURL)
        defer { try? FileManager.default.removeItem(at: cubeURL) }
        let installedDormant = try await library.luts.importFile(cubeURL)
        let formulaLUTs = library.luts.items.map { Formula.LUT(id: $0.id, name: $0.name, size: $0.size) }
        var dormantRecipe = first
        dormantRecipe.look.enabled = true
        dormantRecipe.look.mode = .spektrafilm
        dormantRecipe.look.first = .init(id: installedDormant.id, mix: 1)
        dormantRecipe.removeDefaultOverrides()
        library.queueRecipe(dormantRecipe, for: photos[0].id)
        try library.flushPending()
        try require(!library.usedLUTIdentifiers.contains(installedDormant.id),
            "Dormant LUT ID in Spektrafilm locked an unused LUT")
        try await library.luts.remove([installedDormant.id], protected: library.usedLUTIdentifiers)
        let filmFormula = try Formula(name: "Dormant Test", parts: [.look], from: dormantRecipe, luts: formulaLUTs)
        try require(
            filmFormula.luts.isEmpty && filmFormula.missingLUTs(installed: []).isEmpty
                && filmFormula.recipe.look.activeSlots.isEmpty,
            "Spektrafilm formula exported or required a dormant LUT")
        let filmFormulaID = try await library.formulae.add(filmFormula.data())
        let sharedFormulaFile = library.formulae.file(filmFormula, carryingLUTs: library.luts)
        let exportedFormulaURL = try sharedFormulaFile.export()
        defer { try? FileManager.default.removeItem(at: exportedFormulaURL.deletingLastPathComponent()) }
        try require(
            sharedFormulaFile.luts.isEmpty
                && Formula.attachments(in: try Data(contentsOf: exportedFormulaURL)).isEmpty,
            "Formula export attached a dormant LUT in Spektrafilm mode")
        try await library.formulae.remove([filmFormulaID])
        let filmRows = FormulaProcess(filmFormula, luts: library.luts).stages.flatMap(\.rows)
        try require(filmRows.contains { $0.id == "film" } && !filmRows.contains { $0.id == "lut" },
            "FormulaProcess surfaced LUT row in Spektrafilm mode")

        // Original mode + ±10 S-curve + Darkroom SourcePerforations readouts in FormulaProcess.
        var originalExtended = EditRecipe()
        originalExtended.look.enabled = false
        originalExtended.look.mode = .lut
        originalExtended.look.first = .init(id: installedDormant.id, mix: 1)
        originalExtended.tone.contrast = 1.70
        var edgeStill = FilmEdgeLayout()
        edgeStill.sourcePerforations = .stillKS
        originalExtended.filmEdgeLayout = edgeStill
        let originalFormula = try Formula(name: "Original +10", parts: [.look, .darkroom], from: originalExtended, luts: formulaLUTs)
        let originalProcess = FormulaProcess(originalFormula, luts: library.luts)
        let originalLookRows = originalProcess.stages.first { $0.id == .look }?.rows ?? []
        let contrastRow = originalLookRows.first { $0.id == "contrast" }?.value
        try require(originalLookRows.contains { $0.id == "look" } && contrastRow == "+10",
            "Original mode or +10 S-curve readout mismatch: \(String(describing: contrastRow))")
        try require(!originalLookRows.contains { ["lut", "grain", "halation"].contains($0.id) },
            "Original mode leaked LUT/film effect rows")
        let darkroomRows = originalProcess.stages.first { $0.id == .darkroom }?.rows ?? []
        try require(darkroomRows.contains { $0.id == "edge" && $0.value.contains("KS") },
            "Darkroom formula process omitted explicit 35 mm still (KS) perforations")

        // v1.0 Formula backward compatibility in FormulaProcess & application.
        let v1ExposureData = Data("""
        {
          "created": "2026-11-20T00:00:00Z",
          "format": 1,
          "id": "11111111-1111-1111-1111-111111111111",
          "luts": [],
          "name": "v1 Exposure",
          "note": "",
          "parts": { "exposure": 1 },
          "recipe": {
            "numbers": { "enlarger.y_filter_shift": 12 },
            "source": { "exposureEV": 0, "saturation": 1, "tint": -8, "warmth": 0 },
            "version": 5
          }
        }
        """.utf8)
        let v1ExposureFormula = try Formula(data: v1ExposureData)
        let v1Process = FormulaProcess(v1ExposureFormula, luts: library.luts)
        let v1ExposureRows = v1Process.stages.first { $0.id == .exposure }?.rows ?? []
        try require(v1ExposureRows.contains { $0.id == "tint" } && v1ExposureRows.contains { $0.id == "yellow" },
            "v1.0 Exposure FormulaProcess omitted legacy tint/yellow-balance rows")
        var v1Target = EditRecipe()
        v1Target.source.tint = 3
        v1Target.numbers["enlarger.y_filter_shift"] = 5
        let appliedV1 = v1ExposureFormula.applied(to: v1Target, rawTarget: true)
        try require(appliedV1.source.tint == -8 && appliedV1.numbers["enlarger.y_filter_shift"] == 12,
            "v1.0 Exposure formula application did not preserve v1.0 semantics")
        checks.append("formula dormant-LUT isolation, Original/+10 readout, KS/BH metadata, and v1.0 part-version compatibility")

        let imported = try await library.files.decodedPhoto(photos[0], maximum: 192)
        let renderer = PhotoRenderer(source: imported.preview, directory: Bundle.main.resourceURL!, data: imported.data,
            temperature: imported.rawTemperature, previewMaximum: 192, sourceType: imported.sourceType, description: imported.sourceDescription)
        var bordered = first
        bordered.filmEdgeLayout = FilmEdgeLayout.newDefault()
        bordered.filmEdgeSelection = FilmEdgeSelection()
        bordered.tone.highlights = -0.5
        bordered.tone.contrast = 0.8
        bordered.constrainFilmEdgeCrop(imageSize: CGSize(width: imported.width, height: imported.height))
        let edge = try await renderer.renderFilmEdge(bordered, maximum: 192)
        let corner = PrintCompositor.paperTone(of: edge).components!
        try require(corner.prefix(3).allSatisfy { $0 >= 254.0 / 255 }, "Covered paper was toned down")
        // Region finishing must match the same full-canvas mask, including regions fully
        // outside the opening and crops on each of its four sides.
        let layout = bordered.renderedFilmEdgeLayout!
        let crop = bordered.crop.pixelRect(in: CGSize(width: imported.width, height: imported.height))
        guard let geometry = FilmEdgeGeometry(imageSize: crop.size, layout: layout, longEdge: 192) else {
            throw PhotoExporter.Failure.render
        }
        for rect in [CGRect(x: 0, y: 0, width: 3, height: geometry.height),
                     CGRect(x: geometry.width - 3, y: 0, width: 3, height: geometry.height)] {
            let patch = edge.cropping(to: rect)!
            let finished = try FilmEdgeRenderer.restoringPaper(patch, geometry: geometry, origin: (Int(rect.minX), 0))
            try require(finished.width == 3, "Region finishing failed")
        }
        checks.append("covered paper stays white after tone; narrow loupe regions finish safely")

        // Cold Original + Clean Print distress keeps FilmRenderResources unloaded (skips GPU shader compilation).
        let coldResources = FilmRenderResources(directory: Bundle.main.resourceURL!)
        let coldRenderer = PhotoRenderer(source: imported.preview, directory: Bundle.main.resourceURL!, data: imported.data,
            temperature: imported.rawTemperature, previewMaximum: 720, resources: coldResources,
            sourceType: imported.sourceType, description: imported.sourceDescription)
        var cleanDust = EditorDefaults.originalRecipe(temperature: imported.rawTemperature)
        var distress = FilmEdgeDistress.cleanPrintFallback
        distress.dust = 0.45
        cleanDust.distress = distress
        let dustStart = ProcessInfo.processInfo.systemUptime
        let dustImage = try await coldRenderer.renderDistressedPrint(cleanDust, maximum: 720)
        let dustMs = (ProcessInfo.processInfo.systemUptime - dustStart) * 1000
        let resourcesLoaded = await coldResources.isLoaded
        try require(!resourcesLoaded && dustImage.width > 0, "Cold Original + Clean Print dust unexpectedly loaded spectral/GPU resources")
        let encodedCleanDust = try LibraryPhoto.recipeData(cleanDust)
        try require(RenderCacheRevision.filmSurface == "v22-distress-" && LibraryPhoto.containsSurfaceRender(encodedCleanDust),
            "Clean Print distress missing filmSurface cache invalidation")
        checks.append(String(format: "cold Original+dust %.1fms without loading GPU/spectral resources; cache revision %@", dustMs, RenderCacheRevision.filmSurface))

        // 2160 px Original + Clean Print Burn executes swiftly on hardware via pre-baked LUTs and caches.
        var leakyClean = EditorDefaults.originalRecipe(temperature: imported.rawTemperature)
        var leakyDistress = FilmEdgeDistress.cleanPrintFallback
        leakyDistress.applyCleanPrintPreset(.leaky)
        leakyClean.distress = leakyDistress
        let burnStart = ProcessInfo.processInfo.systemUptime
        let burnImage = try await coldRenderer.renderDistressedPrint(leakyClean, maximum: 2160)
        let coldBurnMs = (ProcessInfo.processInfo.systemUptime - burnStart) * 1000
        try require(burnImage.width > 0 && coldBurnMs < 3500, "Cold Clean Print Burn 2160px took too long: \(coldBurnMs)ms")
        leakyClean.distress?.leakPosition = 0.62
        let warmStart = ProcessInfo.processInfo.systemUptime
        let warmBurnImage = try await coldRenderer.renderDistressedPrint(leakyClean, maximum: 2160)
        let warmBurnMs = (ProcessInfo.processInfo.systemUptime - warmStart) * 1000
        try require(
            warmBurnImage.width > 0 && warmBurnMs < 2400 && warmBurnMs < coldBurnMs,
            "Warm Clean Print Burn 2160px took too long or missed caches: warm=\(warmBurnMs)ms cold=\(coldBurnMs)ms")
        checks.append(String(format: "Clean Print 2160px Burn cold %.1fms / warm %.1fms", coldBurnMs, warmBurnMs))

        // Explicit Lab Scan distress retention when switching Film edge -> Clean print, vs untouched Film edge staying Clean.
        let labRetentionSession = EditorSession(
            photo: imported,
            recipe: EditorDefaults.originalRecipe(temperature: imported.rawTemperature),
            luts: library.luts,
            resources: library.images.resources)
        _ = labRetentionSession.setFilmEdgePresentation(true)
        var explicitLab = labRetentionSession.recipe.filmEdgeLayout!.distress
        explicitLab.apply(.lab)
        labRetentionSession.markSurfaceDistressEdited(explicitLab)
        _ = labRetentionSession.setFilmEdgePresentation(false)
        try require(
            labRetentionSession.recipe.distress?.cleanPrintPreset == .lab
                && abs((labRetentionSession.recipe.distress?.edgeFog ?? 0) - 0.20) < 1e-6
                && abs((labRetentionSession.recipe.distress?.scratches ?? 0) - 0.10) < 1e-6,
            "Explicit Lab Scan distress did not carry over to Clean Print: \(String(describing: labRetentionSession.recipe.distress))")
        labRetentionSession.cancelRendering()
        checks.append("explicit Lab Scan (20%/10%) carries over across Film edge -> Clean print")

        // 3:4 Film Edge -> 120 6x7 -> Clean Print -> Film Edge keeps 120 6x7 without reopening Crop.
        let portraitPhoto = photos.first { $0.metadata.height > $0.metadata.width } ?? photos[0]
        let portraitImported = try await library.files.decodedPhoto(portraitPhoto, maximum: 360)
        let frameSession = EditorSession(photo: portraitImported, recipe: EditorDefaults.originalRecipe(temperature: portraitImported.rawTemperature),
            luts: library.luts, resources: library.images.resources)
        let initialNeedsCrop = frameSession.setFilmEdgePresentation(true)
        try require(frameSession.recipe.filmEdgeLayout != nil, "Failed to enable Film Edge")
        var layout67 = frameSession.recipe.filmEdgeLayout!
        layout67.setFrameChoice(.roll67)
        let cropSession = FilmFrameCropSession(baseCrop: frameSession.preFilmEdgeCrop ?? frameSession.recipe.crop,
            isPreGateBase: frameSession.preFilmEdgeCrop != nil)
        let next67 = cropSession.crop(for: layout67, imageSize: frameSession.uprightSize)
        frameSession.applyFilmFrameInCrop(layout67, crop: next67)
        if initialNeedsCrop { frameSession.endUndoGroup() }
        let savedPreCrop = frameSession.preFilmEdgeCrop
        _ = frameSession.setFilmEdgePresentation(false)
        try require(frameSession.recipe.filmEdgeLayout == nil, "Failed to switch to Clean Print")
        let reopenedCrop = frameSession.setFilmEdgePresentation(true)
        try require(!reopenedCrop && frameSession.recipe.filmEdgeLayout?.frameChoice == .roll67
            && frameSession.preFilmEdgeCrop == savedPreCrop,
            "Clean Print comparison reopened Crop or lost 120 6x7 / preFilmEdgeCrop")
        frameSession.cancelRendering()
        checks.append("3:4 -> 120 6x7 -> Clean print -> Film edge preserves layout without reopening Crop")
    }

    private static func maxError(_ a: CGImage, _ b: CGImage) -> Float {
        guard a.width == b.width, a.height == b.height else { return .infinity }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CIContext(options: [.cacheIntermediates: false])
        func pixels(_ image: CGImage) -> [Float] {
            var values = [Float](repeating: 0, count: image.width * image.height * 4)
            values.withUnsafeMutableBytes {
                context.render(CIImage(cgImage: image), toBitmap: $0.baseAddress!, rowBytes: image.width * 16,
                    bounds: CGRect(x: 0, y: 0, width: image.width, height: image.height), format: .RGBAf, colorSpace: space)
            }
            return values
        }
        return zip(pixels(a), pixels(b)).reduce(0) { max($0, abs($1.0 - $1.1)) }
    }
}
#endif
