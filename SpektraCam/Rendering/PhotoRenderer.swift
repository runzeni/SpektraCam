import CoreGraphics
import CoreImage
import Foundation
import ImageIO

/// Owns one source and one GPU worker. Preview input, baseline metering and the latest film
/// frame are cached independently. Mix reuses the film frame; export uses original bytes.
actor PhotoRenderer {
    static let placeholderSource: CGImage = {
        let context = CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        return context.makeImage()!
    }()

    private let source: CGImage, data: Data?, initialTemperature: Double?
    private let sourceType: String?
    private let sourceFilename: String?
    private let sourceDescription: PhotoSource.Description?
    private let sourcePrefersDeep: Bool
    private final class PreviewState {
        let maximum: Int
        let decoder: SourceImageRenderer.Decoder
        init(maximum: Int, cachesIntermediates: Bool = true) {
            self.maximum = maximum
            self.decoder = SourceImageRenderer.Decoder(cachesIntermediates: cachesIntermediates)
        }
        var neutralKey: EditRecipe.Source?
        var neutralTemperature: Double?
        var neutralImage: CGImage?
        var opticsKey: EditRecipe?
        var opticsSize = CGSize.zero
        var opticsImage: CGImage?
        var grainKey: EditRecipe?
        var grainSize = CGSize.zero
        var grainImages: (CGImage, CGImage)?
        var previousMode: EditRecipe.LookMode?
        var baseline: SourceImageRenderer.Input?
        var baselineImage: CIImage?
        var input: SourceImageRenderer.Input?
        var inputKey: EditRecipe.Source?
        var inputTemperature: Double?
        var inputLookMode: EditRecipe.LookMode?
        var meter: MeteringCore.Image?
        var meteredEV = [String: Double]()
        var filmRecipe: EditRecipe?
        var filmImage: CGImage?
        var precision: RenderPrecision?
    }
    private var preview: PreviewState
    // Finishing must not evict Develop's scene/LUT cache or meter the padded canvas.
    private var edgeMetering: PreviewState
    // At most the active and one alternate resolution. A drag cannot evict the settled
    // source/film cache, and a 2160 px setting does not create an unbounded image ladder.
    private var alternatePreview: (maximum: Int, state: PreviewState)?
    private var previewMaximum: Int
    private let previewLimit: Int
    private let cachesIntermediates: Bool
    private let detailDecoder: SourceImageRenderer.Decoder
    private let edgeDecoder: SourceImageRenderer.Decoder
    private let renderResources: FilmRenderResources
    private let lutDirectory: URL?
    private var cubes: [String: CubeLUT] = [:]
    private var activePrecisionSetting: RenderPrecision
    private var exportKey: EditRecipe?
    private var exportSize: PhotoExporter.Size?
    private var exportImage: CGImage?

    private func syncPrecision() {
        let current = RenderPrecision.selected
        guard current != activePrecisionSetting else { return }
        activePrecisionSetting = current
        discardExport()
        releasePreviewCaches(keepMetering: true)
    }

    init(
        source: CGImage, directory: URL, data: Data? = nil, temperature: Double? = nil,
        lutDirectory: URL? = nil, previewMaximum: Int = PreviewQuality.editorMaximum,
        resources: FilmRenderResources? = nil,
        sourceType: String? = nil, description: PhotoSource.Description? = nil,
        sourceFilename: String? = nil, cachesIntermediates: Bool = true
    ) {
        self.sourceFilename = sourceFilename
        self.source = source
        self.previewMaximum = previewMaximum
        self.cachesIntermediates = cachesIntermediates
        self.detailDecoder = SourceImageRenderer.Decoder(cachesIntermediates: cachesIntermediates)
        self.edgeDecoder = SourceImageRenderer.Decoder(cachesIntermediates: cachesIntermediates)
        preview = PreviewState(maximum: previewMaximum, cachesIntermediates: cachesIntermediates)
        edgeMetering = PreviewState(maximum: 720, cachesIntermediates: cachesIntermediates)
        edgeMetering.inputLookMode = .spektrafilm
        previewLimit = previewMaximum
        renderResources = resources ?? FilmRenderResources(directory: directory)
        self.data = data
        let description = description ?? data.flatMap { PhotoSource.describe($0, typeHint: sourceType) }
        self.sourceDescription = description
        let prefersDeep = description?.prefersDeepPipeline ?? (source.bitsPerComponent > 10)
        self.sourcePrefersDeep = prefersDeep
        self.activePrecisionSetting = RenderPrecision.selected
        self.sourceType = description?.type ?? sourceType
        initialTemperature = temperature ?? description?.temperature
        self.lutDirectory = lutDirectory
    }
    private func baselineInput(state: PreviewState? = nil) throws -> SourceImageRenderer.Input {
        let cache = state ?? preview
        if let baseline = cache.baseline { return baseline }
        var recipe = EditRecipe()
        recipe.look.mode = cache.inputLookMode ?? .spektrafilm
        recipe.temperature = initialTemperature
        let result = try SourceImageRenderer.prepare(
            data: data, fallback: source, recipe: recipe, maximum: cache.maximum,
            sourceType: sourceType, description: sourceDescription, decoder: cache.decoder)
        cache.baseline = result
        if sourceDescription?.isRAW != true { cache.baselineImage = SourceImageRenderer.image(result) }
        return result
    }
    private func exposure(_ recipe: EditRecipe, library: ModelLibrary, state: PreviewState? = nil) throws -> Double {
        let cache = state ?? preview
        guard recipe.flag("camera.auto_exposure") else { return 0 }
        let method = recipe.choice("camera.auto_exposure_method")
        if let value = cache.meteredEV[method] { return value }
        if cache.meter == nil {
            let baseline = try baselineInput(state: cache)
            let y = ModelLibrary.vector(library.index.meteringY)
            let luminance = baseline.pixels.map {
                Double($0.x) * y.x + Double($0.y) * y.y + Double($0.z) * y.z
            }
            cache.meter = try MeteringCore.Image(
                width: baseline.width, height: baseline.height, luminance: luminance
            ).smallPreview()
        }
        let value = cache.meter!.exposureEV(method: method)
        cache.meteredEV[method] = value
        return value
    }
    private func seedEdgeMeteringIfNeeded() {
        guard edgeMetering.meter == nil else { return }
        for state in [preview, alternatePreview?.state].compactMap({ $0 }) {
            if state.inputLookMode == .spektrafilm, let meter = state.meter {
                edgeMetering.inputLookMode = .spektrafilm
                edgeMetering.meter = meter
                edgeMetering.meteredEV = state.meteredEV
                return
            }
        }
    }
    private func selectInputMode(_ mode: EditRecipe.LookMode) {
        if preview.inputLookMode != mode {
            // Film/RAW and SDR photo-LUT input have different rendering intents, including HEIF gain maps.
            preview.baseline = nil
            preview.baselineImage = nil
            preview.input = nil
            preview.meter = nil
            preview.meteredEV.removeAll()
        }
        preview.inputLookMode = mode
    }
    private func previewInput(_ recipe: EditRecipe) throws -> SourceImageRenderer.Input {
        selectInputMode(recipe.inputMode)
        let resolvedTemperature = recipe.temperature ?? initialTemperature
        if preview.inputKey == recipe.source, preview.inputTemperature == resolvedTemperature, let input = preview.input {
            return input
        }
        let result: SourceImageRenderer.Input
        if recipe.source == EditRecipe.Source(), resolvedTemperature == initialTemperature {
            result = try baselineInput()
        } else {
            let canReuse = sourceDescription?.isRAW != true
            if canReuse { _ = try baselineInput() }
            result = try SourceImageRenderer.prepare(
                data: canReuse ? nil : data, fallback: source, recipe: recipe,
                maximum: previewMaximum,
                renderedSource: canReuse ? preview.baselineImage : nil, sourceType: sourceType,
                description: sourceDescription, decoder: preview.decoder)
        }
        preview.input = result
        preview.inputKey = recipe.source
        preview.inputTemperature = resolvedTemperature
        return result
    }
    func render(
        _ recipe: EditRecipe, maximum: Int? = nil, use: RenderPrecision.Use = .output
    ) async throws -> CGImage {
        try await RenderPrecision.withContext(sourcePrefersDeep: sourcePrefersDeep, use: use) {
            try await renderBody(recipe, maximum: maximum)
        }
    }
    private func renderBody(_ recipe: EditRecipe, maximum: Int?) async throws -> CGImage {
        try Task.checkCancellation()
        syncPrecision()
        let requested = min(previewLimit, maximum ?? previewLimit)
        if requested != previewMaximum {
            let previous = (maximum: previewMaximum, state: preview)
            preview = alternatePreview?.maximum == requested
                ? alternatePreview!.state
                : PreviewState(maximum: requested, cachesIntermediates: cachesIntermediates)
            alternatePreview = previous
            previewMaximum = requested
        }
        let effectivePrecision = RenderPrecision.resolved
        if preview.precision != effectivePrecision {
            // Precision change affects rendered intermediates without discarding reusable metering.
            preview.baseline = nil
            preview.baselineImage = nil
            preview.input = nil
            preview.filmRecipe = nil
            preview.filmImage = nil
            preview.opticsKey = nil
            preview.opticsImage = nil
            preview.grainKey = nil
            preview.grainImages = nil
            preview.neutralKey = nil
            preview.neutralImage = nil
            preview.precision = effectivePrecision
        }
        let width = sourceDescription?.width ?? source.width
        let height = sourceDescription?.height ?? source.height
        let scale = min(1, Double(requested) / Double(max(width, height)))
        do {
            _ = try RenderMemoryBudget.check(
                width: max(1, Int(ceil(Double(width) * scale))),
                height: max(1, Int(ceil(Double(height) * scale))), recipe: recipe)
        } catch {
            // The alternate is disposable. Do not keep it at the cost of an active preview.
            guard alternatePreview != nil else { throw error }
            alternatePreview = nil
            _ = try RenderMemoryBudget.check(
                width: max(1, Int(ceil(Double(width) * scale))),
                height: max(1, Int(ceil(Double(height) * scale))), recipe: recipe)
        }
        let input = try previewInput(recipe)
        let plan = try RenderMemoryBudget.check(
            width: input.width, height: input.height, recipe: recipe)
        if !recipe.look.enabled {
            return try neutralFrame(input, recipe: recipe)
        }
        let (library, gpu) = try await renderResources.load()
        try Task.checkCancellation()
        if preview.previousMode != recipe.look.mode {
            preview.filmRecipe = nil
            preview.filmImage = nil
            preview.opticsKey = nil
            preview.opticsImage = nil
            preview.grainKey = nil
            preview.grainImages = nil
            preview.previousMode = recipe.look.mode
        }
        return try await frame(
            input, recipe: recipe, library: library, gpu: gpu, preview: true, state: preview,
            plan: plan)
    }
    private static let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private var tiling: MetalFilmPipeline.Tiling { .fitting(available: ImageMemoryAllowance.available) }
    /// Storage for a frame that renders in tiles: a full-size export's own store, or a copy of a
    /// preview whose diffusion transform would not fit as one frame.
    private func tileStore(
        _ input: SourceImageRenderer.Input, recipe: EditRecipe, edge: FilmEdgeGeometry? = nil,
        plan: RenderMemoryBudget.Plan? = nil
    ) throws -> PixelStore? {
        if let store = input.store { return store }
        let useTiles = plan?.tiled ?? RenderMemoryBudget.rendersInTiles(
            width: input.width, height: input.height, recipe: recipe,
            pixelPitchMicrometers: edge?.pixelPitchMicrometers)
        guard useTiles else { return nil }
        let store = try PixelStore(width: input.width, height: input.height, format: .working)
        input.pixels.withUnsafeBytes {
            store.write(
                x: 0, y: 0, width: input.width, height: input.height, from: $0.baseAddress!,
                sourceRowBytes: input.width * 16)
        }
        return store
    }
    /// Film render of a preview-size array, or of a full-size store rendered in tiles.
    /// `finished` asks a tiled render for the final 8-bit image when no grading follows.
    private func filmImage(
        _ input: SourceImageRenderer.Input, pipeline: FilmPipeline, gpu: MetalFilmPipeline,
        autoExposureEV: Double, edge: FilmEdgeGeometry? = nil, finished: Bool = false,
        plan: RenderMemoryBudget.Plan? = nil
    ) async throws -> CGImage {
        guard let store = try tileStore(input, recipe: pipeline.recipe, edge: edge, plan: plan) else {
            return try await gpu.processImage(
                input.pixels, width: input.width, height: input.height, pipeline: pipeline,
                autoExposureEV: autoExposureEV, edge: edge)
        }
        let result = try await gpu.processImage(
            store, pipeline: pipeline, autoExposureEV: autoExposureEV, edge: edge,
            format: finished ? .byte : .working, tiling: plan?.tiling ?? tiling)
        return try result.image(
            colorSpace: CGColorSpace(name: finished ? CGColorSpace.sRGB : CGColorSpace.extendedSRGB)!)
    }
    private func neutralFrame(
        _ input: SourceImageRenderer.Input, recipe: EditRecipe, workingOutput: Bool = false
    ) throws -> CGImage {
        let source = try SourceImageRenderer.workingImage(input)
        return workingOutput
            ? try ToneRenderer.working(source, tone: recipe.tone)
            : try ToneRenderer.render(source, tone: recipe.tone)
    }
    private func applications(_ recipe: EditRecipe) throws -> [CubeLUT.Application] {
        var active: [String: CubeLUT] = [:]
        var result: [CubeLUT.Application] = []
        for slot in [recipe.look.first, recipe.look.second] {
            guard let id = slot.id, slot.mix > 0 else { continue }
            guard let lutDirectory else { throw CubeLUT.Failure.missing }
            let cube = try active[id] ?? cubes[id] ?? CubeLUT.load(id: id, directory: lutDirectory)
            active[id] = cube
            result.append(.init(cube: cube, mix: slot.mix))
        }
        cubes = active
        return result
    }
    private func effectFrames(
        _ input: SourceImageRenderer.Input, recipe: EditRecipe,
        library: ModelLibrary, gpu: MetalFilmPipeline, preview: Bool, state: PreviewState,
        plan: RenderMemoryBudget.Plan? = nil
    ) async throws -> (CGImage, CGImage?, CGImage?) {
        let cache = state
        var physical = EditRecipe()
        // The carrier uses film optics, but its RAW controls share the LUT source reference.
        physical.look.mode = .lut
        let prefixes = [
            "film_render.grain.", "film_render.halation.", "camera.diffusion_filter.",
            "enlarger.diffusion_filter.",
        ]
        physical.numbers = recipe.numbers.filter { entry in
            prefixes.contains { entry.key.hasPrefix($0) }
        }
        physical.flags = recipe.flags.filter { entry in
            prefixes.contains { entry.key.hasPrefix($0) }
        }
        physical.choices = recipe.choices.filter { entry in
            prefixes.contains { entry.key.hasPrefix($0) }
        }
        physical.numbers["camera.film_format_mm"] = recipe.number("camera.film_format_mm")
        physical.monochromeGrain = false
        physical.tone = recipe.tone.rawStage
        physical.source = recipe.source
        physical.temperature = recipe.temperature
        // Scatter is an energy mixture in RGB. Extrapolating it creates negative edge light.
        physical.numbers["film_render.halation.scatter_amount"] = min(
            max(physical.number("film_render.halation.scatter_amount"), 0), 1)
        let size = CGSize(width: input.width, height: input.height)
        let opticalFlags = [
            "film_render.halation.active", "camera.diffusion_filter.active",
            "enlarger.diffusion_filter.active",
        ]
        var optics = physical
        optics.numbers = optics.numbers.filter { !$0.key.hasPrefix("film_render.grain.") }
        optics.flags = optics.flags.filter { !$0.key.hasPrefix("film_render.grain.") }
        optics.flags["film_render.grain.active"] = false
        let source: CGImage
        if preview, cache.opticsKey == optics, cache.opticsSize == size, let image = cache.opticsImage {
            source = image
        } else {
            if opticalFlags.contains(where: { optics.flag($0) }) || !optics.tone.rawStage.isIdentity
            {
                let pipeline = try await renderResources.pipeline(optics)
                if let store = try tileStore(input, recipe: pipeline.recipe, plan: plan) {
                    source = try await gpu.processOptics(
                        store, pipeline: pipeline, tiling: plan?.tiling ?? tiling
                    ).image(colorSpace: Self.linear)
                } else {
                    source = try await gpu.processOptics(
                        input.pixels, width: input.width, height: input.height,
                        pipeline: pipeline)
                }
            } else {
                source = try SourceImageRenderer.workingImage(input)
            }
            if preview {
                cache.opticsKey = optics
                cache.opticsSize = size
                cache.opticsImage = source
            }
        }
        var grain = physical
        grain.numbers = grain.numbers.filter {
            $0.key.hasPrefix("film_render.grain.") || $0.key == "camera.film_format_mm"
        }
        grain.flags = grain.flags.filter { $0.key.hasPrefix("film_render.grain.") }
        grain.choices = [:]
        for flag in opticalFlags { grain.flags[flag] = false }
        grain.flags["print_render.glare.active"] = false
        let noise: (CGImage, CGImage)?
        if !grain.flag("film_render.grain.active") {
            noise = nil
            if preview {
                cache.grainImages = nil
                cache.grainKey = nil
            }
        } else if preview, cache.grainKey == grain, cache.grainSize == size, let frames = cache.grainImages {
            noise = frames
        } else {
            let exposure = try exposure(grain, library: library)
            let pipeline = try await renderResources.pipeline(grain)
            if let store = try tileStore(input, recipe: pipeline.recipe, plan: plan) {
                let pair = try await gpu.processGrainPair(
                    store, pipeline: pipeline, autoExposureEV: exposure,
                    tiling: plan?.tiling ?? tiling)
                noise = try (
                    pair.0.image(colorSpace: Self.linear), pair.1.image(colorSpace: Self.linear)
                )
            } else {
                noise = try await gpu.processGrainPair(
                    input.pixels, width: input.width, height: input.height,
                    pipeline: pipeline, autoExposureEV: exposure)
            }
            if preview {
                cache.grainKey = grain
                cache.grainSize = size
                cache.grainImages = noise
            }
        }
        return (source, noise?.0, noise?.1)
    }

    private func frame(
        _ input: SourceImageRenderer.Input, recipe: EditRecipe,
        library: ModelLibrary, gpu: MetalFilmPipeline, preview: Bool, state: PreviewState? = nil,
        framing: (recipe: EditRecipe, footprint: CGRect, size: CGSize, maximum: Int, geometry: FilmEdgeGeometry)? = nil,
        plan: RenderMemoryBudget.Plan? = nil, workingOutput: Bool = false
    ) async throws -> CGImage {
        let cache = state ?? PreviewState(maximum: previewMaximum, cachesIntermediates: cachesIntermediates)
        var recipe = recipe
        recipe.numbers["film_render.halation.scatter_amount"] = min(
            max(recipe.number("film_render.halation.scatter_amount"), 0), 1)
        if recipe.look.mode == .lut {
            let frames = try await effectFrames(
                input, recipe: recipe, library: library, gpu: gpu, preview: preview, state: cache,
                plan: plan)
            let residual: (CGImage, CGImage)? = frames.1.flatMap { dirty in
                frames.2.map { (dirty, $0) }
            }
            return workingOutput
                ? try ToneRenderer.working(
                    frames.0, tone: recipe.tone.outputStage, luts: applications(recipe),
                    residual: residual, monochromeResidual: recipe.monochromeGrain)
                : try ToneRenderer.render(
                    frames.0, tone: recipe.tone.outputStage, luts: applications(recipe),
                    residual: residual, monochromeResidual: recipe.monochromeGrain)
        }
        var key = recipe.processingRecipe
        key.mix = 1
        key.tone = recipe.tone.rawStage
        key.look = EditRecipe.Look()
        let film: CGImage
        if preview, cache.filmRecipe == key, let cached = cache.filmImage {
            film = cached
        } else {
            let pipeline = try await renderResources.pipeline(recipe)
            // With nothing to grade afterwards, a tiled render writes the finished 8-bit image.
            film = try await filmImage(
                input, pipeline: pipeline, gpu: gpu,
                autoExposureEV: exposure(recipe, library: library, state: cache),
                finished: !workingOutput && recipe.mix >= 1 && recipe.tone.outputStage.isIdentity,
                plan: plan)
            if preview {
                cache.filmRecipe = key
                cache.filmImage = film
            }
        }
        try Task.checkCancellation()
        let mixed: CGImage
        if recipe.mix >= 1 {
            mixed = film
        } else {
            // Mix endpoints share output reference white, not merely a linear transfer curve.
            // Scene light belongs inside the film model; the zero endpoint is a developed photo.
            let neutral: CGImage
            let resolvedTemperature = recipe.temperature ?? initialTemperature
            if preview, cache.neutralKey == recipe.source, cache.neutralTemperature == resolvedTemperature,
                let cached = cache.neutralImage
            {
                neutral = cached
            } else {
                let developed = try framing.map {
                    // A film-edge centre keeps its framed decode across handling changes and shares
                    // unwanted exposure with the film graph so partial-Mix blends stay continuous.
                    try FilmEdgeRenderer.exposeCenter(
                        edgeSource(
                            recipe, framing: $0.recipe, footprint: $0.footprint, maximum: $0.maximum,
                            intent: .developedPhoto, size: $0.size),
                        geometry: $0.geometry, intent: .developedPhoto)
                } ?? SourceImageRenderer.prepare(
                    data: data, fallback: source, recipe: recipe,
                    maximum: max(input.width, input.height), sourceType: sourceType,
                    intent: .developedPhoto, description: sourceDescription,
                    decoder: preview ? cache.decoder : nil, allowsStore: !preview)
                neutral = try SourceImageRenderer.workingImage(developed)
                if preview {
                    cache.neutralKey = recipe.source
                    cache.neutralTemperature = resolvedTemperature
                    cache.neutralImage = neutral
                }
            }
            let rawSource = try ToneRenderer.working(neutral, tone: recipe.tone.rawStage)
            mixed = try SourceImageRenderer.blend(
                film: film, sourceImage: rawSource, amount: recipe.mix)
        }
        return workingOutput
            ? try ToneRenderer.working(mixed, tone: recipe.tone.outputStage)
            : try ToneRenderer.render(mixed, tone: recipe.tone.outputStage)
    }

    /// An enlarger print's margin is unexposed paper; the sheet around it is the same paper.
    private static func paper(_ recipe: EditRecipe, _ image: CGImage) -> CGColor? {
        recipe.renderedFilmEdgeLayout?.distress.enlargerPrint == true ? PrintCompositor.paperTone(of: image) : nil
    }
    /// Sharp pixels for the visible part of a zoomed preview.
    struct Detail: @unchecked Sendable {
        let image: CGImage
        /// Where the image lies in the displayed (turned and cropped) photo, in unit coordinates.
        let rect: CGRect
    }
    /// Render only what is on screen, at the resolution the zoom needs. `visible` is the part
    /// of the displayed photo in view (unit coordinates, origin top left); `longEdge` is how
    /// many pixels the whole displayed photo's long edge would need at this zoom.
    /// Wide effects come from a low-resolution capture of the whole frame that is prepared once
    /// per edit, so panning only pays for the tiles it exposes. Returns nil when the regular
    /// preview is already sharp enough or the recipe needs the whole-frame route.
    func renderDetail(_ original: EditRecipe, visible: CGRect, longEdge: Int) async throws -> Detail? {
        try await RenderPrecision.withContext(sourcePrefersDeep: sourcePrefersDeep, use: .output) {
            try await renderDetailBody(original, visible: visible, longEdge: longEdge)
        }
    }
    private func renderDetailBody(
        _ original: EditRecipe, visible: CGRect, longEdge: Int
    ) async throws -> Detail? {
        try Task.checkCancellation()
        syncPrecision()
        guard let data, original.look.enabled, original.look.mode == .spektrafilm,
            original.mix >= 1, original.filmEdgeLayout == nil,
            original.printLayout.map(\.isIdentity) ?? true,
            original.geometry.straightenDegrees == 0
        else { return nil }
        var recipe = original
        recipe.numbers["film_render.halation.scatter_amount"] = min(
            max(recipe.number("film_render.halation.scatter_amount"), 0), 1)
        let nativeWidth = sourceDescription?.width ?? source.width
        let nativeHeight = sourceDescription?.height ?? source.height
        let oriented = recipe.geometry.quarterTurns % 2 == 0
            ? CGSize(width: nativeWidth, height: nativeHeight)
            : CGSize(width: nativeHeight, height: nativeWidth)
        let crop = recipe.crop.pixelRect(in: oriented)
        guard crop.width >= 1, crop.height >= 1 else { return nil }
        // Zoom levels halve the native size, so a level's capture is reused while panning.
        let wanted = Double(longEdge) / Double(max(crop.width, crop.height))
        var scale = 1.0
        while scale / 2 >= wanted { scale /= 2 }
        let maximum = Int(ceil(Double(max(nativeWidth, nativeHeight)) * scale))
        guard maximum > previewMaximum * 5 / 4 else { return nil }
        func decode(_ region: SourceImageRenderer.Region?, target: CGSize? = nil, long: Int)
            throws -> SourceImageRenderer.Input
        {
            try SourceImageRenderer.prepare(
                data: data, fallback: source, recipe: recipe, maximum: long,
                sourceType: sourceType, intent: .sceneLinear, description: sourceDescription,
                decoder: region == nil ? nil : detailDecoder, targetSize: target, region: region)
        }
        let size = try decode(.measure, long: maximum)
        let width = size.width, height = size.height
        let tiling = self.tiling
        let factor = tiling.resolvedFactor(width: width, height: height)
        let (library, gpu) = try await renderResources.load()
        let pipeline = try await renderResources.pipeline(recipe)
        let autoEV = try exposure(recipe, library: library, state: preview)
        var prepared = try await gpu.prepareRegion(
            width: width, height: height, factor: factor, pipeline: pipeline,
            autoExposureEV: autoEV, tiling: tiling, proxy: nil)
        if prepared == nil {
            let proxyWidth = (width + factor - 1) / factor, proxyHeight = (height + factor - 1) / factor
            let proxy = try decode(
                nil, target: CGSize(width: proxyWidth, height: proxyHeight),
                long: max(proxyWidth, proxyHeight))
            try Task.checkCancellation()
            prepared = try await gpu.prepareRegion(
                width: width, height: height, factor: factor, pipeline: pipeline,
                autoExposureEV: autoEV, tiling: tiling, proxy: proxy.pixels)
        }
        guard let halo = prepared else { throw PhotoExporter.Failure.render }
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        let shown = visible.intersection(unit)
        guard !shown.isEmpty else { return nil }
        let turned = CGRect(
            x: (crop.minX + shown.minX * crop.width) / oriented.width,
            y: (crop.minY + shown.minY * crop.height) / oriented.height,
            width: shown.width * crop.width / oriented.width,
            height: shown.height * crop.height / oriented.height)
        let from = recipe.geometry.sourceRect(forOriented: turned)
        let x0 = min(max(Int(floor(from.minX * Double(width))), 0), width - 1)
        let y0 = min(max(Int(floor(from.minY * Double(height))), 0), height - 1)
        let x1 = min(max(Int(ceil(from.maxX * Double(width))), x0 + 1), width)
        let y1 = min(max(Int(ceil(from.maxY * Double(height))), y0 + 1), height)
        let sx0 = max(0, x0 - halo), sy0 = max(0, y0 - halo)
        let sx1 = min(width, x1 + halo), sy1 = min(height, y1 + halo)
        let part = try decode(
            .rect(x: sx0, y: sy0, width: sx1 - sx0, height: sy1 - sy0), long: maximum)
        guard let store = part.store else { throw PhotoExporter.Failure.render }
        try Task.checkCancellation()
        let key = MetalFilmPipeline.RegionKey(
            recipe: pipeline.recipe, width: width, height: height, factor: factor,
            autoExposureEV: autoEV, seed: 0)
        let result = try await gpu.processRegion(
            store, origin: (sx0, sy0), region: (x0, y0, x1 - x0, y1 - y0), key: key,
            pipeline: pipeline)
        try Task.checkCancellation()
        let film = try result.image(colorSpace: CGColorSpace(name: CGColorSpace.extendedSRGB)!)
        let finished = try ToneRenderer.render(film, tone: recipe.tone.outputStage)
        guard let image = GeometryRenderer.render(finished, geometry: recipe.geometry.orientationOnly)
        else { throw PhotoExporter.Failure.render }
        let back = recipe.geometry.orientedRect(
            forSource: CGRect(
                x: Double(x0) / Double(width), y: Double(y0) / Double(height),
                width: Double(x1 - x0) / Double(width), height: Double(y1 - y0) / Double(height)))
        return Detail(
            image: image,
            rect: CGRect(
                x: (back.minX * oriented.width - crop.minX) / crop.width,
                y: (back.minY * oriented.height - crop.minY) / crop.height,
                width: back.width * oriented.width / crop.width,
                height: back.height * oriented.height / crop.height))
    }

    /// Saved viewer/library presentation uses the same edge and paper finishing as export.
    func renderPresentation(_ recipe: EditRecipe, maximum: Int) async throws -> CGImage {
        try await RenderPrecision.withContext(sourcePrefersDeep: sourcePrefersDeep, use: .output) {
            try await renderPresentationBody(recipe, maximum: maximum)
        }
    }
    private func renderPresentationBody(_ recipe: EditRecipe, maximum: Int) async throws -> CGImage {
        let photograph: CGImage
        if recipe.filmEdgeLayout != nil {
            // `maximum` bounds the finished sheet; the picture renders at exactly the size it will
            // occupy on it, as an export does, so the two never differ.
            let caps = exportLongEdges(recipe, size: .longEdge(maximum))
            photograph = try await renderFilmEdge(recipe, maximum: caps.picture ?? maximum)
        } else if recipe.activeCleanPrintDistress != nil {
            let caps = exportLongEdges(recipe, size: .longEdge(maximum))
            photograph = try await renderDistressedPrint(recipe, maximum: caps.picture ?? maximum)
        } else {
            let developed = try await render(recipe, maximum: maximum)
            guard let transformed = GeometryRenderer.render(developed, geometry: recipe.geometry),
                  let cropped = transformed.cropping(to: recipe.crop.pixelRect(in: CGSize(width: transformed.width, height: transformed.height)))
            else { throw PhotoExporter.Failure.render }
            photograph = cropped
        }
        if let layout = recipe.printedLayout {
            return try PrintCompositor.render(photograph, layout: layout, maximum: maximum, paper: Self.paper(recipe, photograph),
                                              content: recipe.printContent(canvas: CGSize(width: photograph.width, height: photograph.height)))
        }
        return photograph
    }

    /// The framed source of a film-edge render. Handling and gate sliders re-render the support
    /// many times without touching the photograph, so its decode is kept between frames.
    private struct EdgeSourceKey: Equatable {
        let source: EditRecipe.Source, temperature: Double?, footprint: CGRect
        let geometry: ImageGeometry, maximum: Int, size: CGSize
        let intent: SourceImageRenderer.Intent, precision: RenderPrecision
    }
    private struct EdgeCentreExposureKey: Equatable {
        let format: FilmEdgeLayout.Format
        let perforation: FilmEdgeGeometry.Perforation
        let seed: UInt32
        let edgeFog: Double
        let holeVariation: Double
        let nonBurnLeak: Double
        let leakKind: FilmEdgeDistress.LeakKind
        let leakShape: FilmEdgeDistress.LeakShape
        let leakSize: Double
        let leakPosition: Double
        let warmth: Double
        let sceneExposureScale: Double
        init?(
            _ layout: FilmEdgeLayout, effective d: FilmEdgeDistress,
            perforation: FilmEdgeGeometry.Perforation, sceneExposureScale: Double = 1.0
        ) {
            self.init(
                format: layout.format, effective: d, perforation: perforation,
                sceneExposureScale: sceneExposureScale)
        }
        init?(
            format: FilmEdgeLayout.Format, effective d: FilmEdgeDistress,
            perforation: FilmEdgeGeometry.Perforation, sceneExposureScale: Double = 1.0
        ) {
            let hasFog = d.edgeFog > 0
            let hasNonBurnLeak = d.leak > 0 && d.leakShape != .burn
            guard hasFog || hasNonBurnLeak else { return nil }
            self.format = format
            self.perforation = perforation
            self.seed = d.seed
            self.edgeFog = hasFog ? d.edgeFog : 0
            self.holeVariation = (hasFog && format == .film35) ? d.holeVariation : 0
            self.nonBurnLeak = hasNonBurnLeak ? d.leak : 0
            self.leakKind = hasNonBurnLeak ? d.leakKind : .back
            self.leakShape = hasNonBurnLeak ? d.leakShape : .glow
            self.leakSize = hasNonBurnLeak ? d.leakSize : 0
            self.leakPosition = hasNonBurnLeak ? d.leakPosition : 0
            self.warmth = hasNonBurnLeak ? d.warmth : 0
            self.sceneExposureScale = sceneExposureScale
        }
    }
    private struct EdgeCentreKey: Equatable {
        let baseRecipe: EditRecipe
        let footprint: CGRect
        let size: CGSize
        let precision: RenderPrecision
        let exposure: EdgeCentreExposureKey?
    }
    private struct GateMaskKey: Equatable {
        let width: Int, height: Int, millimetersPerPixel: Double, portrait: Bool
        let gate: CGRect, gateCorner: Double, notched: Bool, erodesGate: Bool
        let tilt: Double, bulge: Double, gateSoftness: Double, gateWear: Double, seed: UInt32
        init(_ g: FilmEdgeGeometry) {
            width = g.width; height = g.height; millimetersPerPixel = g.millimetersPerPixel
            portrait = g.portrait; gate = g.gate; gateCorner = g.gateCorner; notched = g.notched
            erodesGate = g.erodesGate; tilt = g.distress.tilt; bulge = g.distress.bulge
            gateSoftness = g.distress.gateSoftness; gateWear = g.distress.gateWear; seed = g.distress.seed
        }
    }
    private var edgeSources: [(key: EdgeSourceKey, input: SourceImageRenderer.Input)] = []
    private var edgeCentres: [(key: EdgeCentreKey, image: CGImage)] = []
    private var edgeMasks: [(key: GateMaskKey, values: [Float], image: CIImage)] = []
    private var cachedBurnResponse: (key: EditRecipe, ev: Double, response: FilmEdgeRenderer.MaterialBurnResponse)?
    private func burnResponse(
        material: EditRecipe, pipeline: FilmPipeline, autoExposureEV: Double
    ) -> FilmEdgeRenderer.MaterialBurnResponse {
        let key = material.processingRecipe
        if let cached = cachedBurnResponse, cached.key == key, abs(cached.ev - autoExposureEV) <= 1e-6 {
            return cached.response
        }
        let response = FilmEdgeRenderer.MaterialBurnResponse(
            pipeline: pipeline, autoExposureEV: autoExposureEV)
        cachedBurnResponse = (key: key, ev: autoExposureEV, response: response)
        return response
    }
    private func gateCoverage(for geometry: FilmEdgeGeometry) throws -> (values: [Float], mask: CIImage) {
        let key = GateMaskKey(geometry)
        if let index = edgeMasks.firstIndex(where: { $0.key == key }) {
            let hit = edgeMasks.remove(at: index)
            edgeMasks.append(hit)
            return (hit.values, hit.image)
        }
        let values = try FilmEdgeRenderer.gateCoverageMap(geometry)
        let mask = try FilmEdgeRenderer.gateMask(values, geometry)
        edgeMasks.append((key, values, mask))
        if edgeMasks.count > 3 { edgeMasks.removeFirst() }
        return (values, mask)
    }
    private func edgeSource(
        _ recipe: EditRecipe, framing: EditRecipe, footprint: CGRect, maximum: Int,
        intent: SourceImageRenderer.Intent, size: CGSize
    ) throws -> SourceImageRenderer.Input {
        let key = EdgeSourceKey(
            source: recipe.source, temperature: recipe.temperature ?? initialTemperature, footprint: footprint,
            geometry: framing.geometry, maximum: maximum, size: size,
            intent: intent, precision: RenderPrecision.resolved)
        if let index = edgeSources.firstIndex(where: { $0.key == key }) {
            let hit = edgeSources.remove(at: index)
            edgeSources.append(hit)
            return hit.input
        }
        let decoder = PixelStore.isLarge(width: Int(size.width), height: Int(size.height)) ? nil : edgeDecoder
        let input = try SourceImageRenderer.prepare(
            data: data, fallback: source, recipe: recipe, maximum: maximum, sourceType: sourceType,
            intent: intent, description: sourceDescription, decoder: decoder,
            framing: framing, customCropNormalized: footprint, targetSize: size, allowsStore: true)
        // The quick frame, the settled frame and the loupe each keep one size.
        edgeSources.append((key, input))
        if edgeSources.count > 4 { edgeSources.removeFirst() }
        return input
    }
    /// The patch of a film-edge presentation under the loupe, at the photo's native resolution.
    /// `visible` is in unit coordinates of the strip canvas. Rebate patches render on every route,
    /// and composed Original / optical-free LUT patches blend locally over the gate. Nil when a
    /// composed gate-overlapping center needs wide spatial blurs or the preview already has every pixel.
    func renderEdgeDetail(_ original: EditRecipe, visible: CGRect) async throws -> Detail? {
        try await RenderPrecision.withContext(sourcePrefersDeep: sourcePrefersDeep, use: .output) {
            try await renderEdgeDetailBody(original, visible: visible)
        }
    }
    private func renderEdgeDetailBody(_ original: EditRecipe, visible: CGRect) async throws -> Detail? {
        try Task.checkCancellation()
        syncPrecision()
        guard data != nil, let layout = original.renderedFilmEdgeLayout else { return nil }
        let dimensions = sourceDescription.map { CGSize(width: $0.width, height: $0.height) }
            ?? CGSize(width: source.width, height: source.height)
        var recipe = original
        let oriented = original.geometry.quarterTurns % 2 == 0 ? dimensions
            : CGSize(width: dimensions.height, height: dimensions.width)
        let support = layout.sourceSupport(for: recipe.crop, imageSize: oriented)
        recipe.crop = support.constrainedCrop
        let crop = recipe.crop.pixelRect(in: oriented)
        let long = max(1, Int(max(crop.width, crop.height)))
        guard long > previewMaximum * 5 / 4 else { return nil }
        recipe.tone.monochrome = false
        let material = FilmEdgeRenderer.materialRecipe(recipe)
        let composes = material.processingRecipe != recipe.processingRecipe
        guard let geometry = FilmEdgeGeometry(
            imageSize: crop.size, layout: layout, longEdge: long,
            perforation: layout.resolvedPerforation(filmID: material.filmID),
            easel: recipe.printLayout ?? PrintLayout())
        else { return nil }
        let shown = visible.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !shown.isEmpty else { return nil }
        let width = geometry.width, height = geometry.height
        let x0 = min(max(Int(floor(shown.minX * Double(width))), 0), width - 1)
        let y0 = min(max(Int(floor(shown.minY * Double(height))), 0), height - 1)
        let x1 = min(max(Int(ceil(shown.maxX * Double(width))), x0 + 1), width)
        let y1 = min(max(Int(ceil(shown.maxY * Double(height))), y0 + 1), height)
        var materialGeometry = geometry
        materialGeometry.erodesGate = composes
        var fxMin = Double.infinity, fxMax = -Double.infinity
        var fyMin = Double.infinity, fyMax = -Double.infinity
        var aMin = Double.infinity, aMax = -Double.infinity
        var tMin = Double.infinity, tMax = -Double.infinity
        for (cx, cy) in [(x0, y0), (x1, y0), (x0, y1), (x1, y1)] {
            let (fx, fy) = geometry.film(Double(cx), Double(cy))
            fxMin = min(fxMin, fx); fxMax = max(fxMax, fx)
            fyMin = min(fyMin, fy); fyMax = max(fyMax, fy)
            let (a, t) = geometry.portrait ? (fy, -fx) : (fx, fy)
            aMin = min(aMin, a); aMax = max(aMax, a)
            tMin = min(tMin, t); tMax = max(tMax, t)
        }
        let mm = geometry.millimetersPerPixel
        let ha0 = (geometry.portrait ? geometry.gate.height : geometry.gate.width) * mm / 2
        let ht0 = (geometry.portrait ? geometry.gate.width : geometry.gate.height) * mm / 2
        let exc = materialGeometry.apertureExcursionMm()
        let patchIntersectsGate = aMax >= -(ha0 + exc.outAlong) && aMin <= (ha0 + exc.outAlong)
            && tMax >= -(ht0 + exc.outAcross) && tMin <= (ht0 + exc.outAcross)
        let centerHasSpatial = recipe.look.enabled && (
            recipe.look.mode == .spektrafilm
            || recipe.flag("film_render.halation.active")
            || recipe.flag("camera.diffusion_filter.active")
            || recipe.flag("enlarger.diffusion_filter.active")
            || recipe.flag("film_render.grain.active"))
        if composes && patchIntersectsGate && centerHasSpatial { return nil }
        let tiling = self.tiling
        let factor = tiling.resolvedFactor(width: geometry.width, height: geometry.height)
        let (library, gpu) = try await renderResources.load()
        seedEdgeMeteringIfNeeded()
        let autoEV = try exposure(material, library: library, state: edgeMetering)
        let pipeline = try await renderResources.pipeline(material)
        let originalLong = max(dimensions.width, dimensions.height)
        let footprintLong = max(1.0, max(support.footprint.width * oriented.width, support.footprint.height * oriented.height))
        func framed(_ g: FilmEdgeGeometry) throws -> SourceImageRenderer.Input {
            let size = g.supportPixelSize
            let supportLong = max(size.width, size.height)
            let maximum = min(Int(originalLong), max(1, Int(ceil(originalLong * supportLong / footprintLong))))
            return try edgeSource(
                material, framing: recipe, footprint: support.footprint, maximum: maximum,
                intent: .sceneLinear, size: size)
        }
        var prepared = try await gpu.prepareRegion(
            width: geometry.width, height: geometry.height, factor: factor, pipeline: pipeline,
            autoExposureEV: autoEV, tiling: tiling, edge: materialGeometry, layout: layout, proxy: nil)
        if prepared == nil {
            let coarse = materialGeometry.coarser(by: factor)
            let canvas = try FilmEdgeRenderer.padded(framed(coarse), geometry: coarse)
            try Task.checkCancellation()
            prepared = try await gpu.prepareRegion(
                width: geometry.width, height: geometry.height, factor: factor, pipeline: pipeline,
                autoExposureEV: autoEV, tiling: tiling, edge: materialGeometry, layout: layout,
                proxy: canvas.pixels)
        }
        guard let halo = prepared else { throw PhotoExporter.Failure.render }
        let sx0 = max(0, x0 - halo), sy0 = max(0, y0 - halo)
        let sx1 = min(width, x1 + halo), sy1 = min(height, y1 + halo)
        let part = try FilmEdgeRenderer.padded(
            framed(materialGeometry), geometry: materialGeometry, region: (sx0, sy0, sx1 - sx0, sy1 - sy0))
        guard let store = part.store else { throw PhotoExporter.Failure.render }
        try Task.checkCancellation()
        let key = MetalFilmPipeline.RegionKey(
            recipe: pipeline.recipe, width: width, height: height, factor: factor,
            autoExposureEV: autoEV, seed: 0, edge: layout)
        let result = try await gpu.processRegion(
            store, origin: (sx0, sy0), region: (x0, y0, x1 - x0, y1 - y0), key: key, pipeline: pipeline)
        try Task.checkCancellation()
        let film = try result.image(colorSpace: CGColorSpace(name: CGColorSpace.extendedSRGB)!)
        let composedFilm: CGImage
        if composes && patchIntersectsGate {
            let pw = x1 - x0, ph = y1 - y0
            let supX = geometry.supportHalf.x, supY = geometry.supportHalf.y
            let supportSize = geometry.supportPixelSize
            let swFull = Double(supportSize.width), shFull = Double(supportSize.height)
            let ix0 = min(max(Int(floor((fxMin + supX) / (2 * supX) * swFull)) - 3, 0), Int(swFull))
            let ix1 = min(max(Int(ceil((fxMax + supX) / (2 * supX) * swFull)) + 3, ix0), Int(swFull))
            let iy0 = min(max(Int(floor((fyMin + supY) / (2 * supY) * shFull)) - 3, 0), Int(shFull))
            let iy1 = min(max(Int(ceil((fyMax + supY) / (2 * supY) * shFull)) + 3, iy0), Int(shFull))
            let subW = ix1 - ix0, subH = iy1 - iy0
            if subW > 0 && subH > 0 {
                let subFxMin = -supX + Double(ix0) / swFull * (2 * supX)
                let subFxMax = -supX + Double(ix1) / swFull * (2 * supX)
                let subFyMin = -supY + Double(iy0) / shFull * (2 * supY)
                let subFyMax = -supY + Double(iy1) / shFull * (2 * supY)
                let subBounds = (minX: subFxMin, maxX: subFxMax, minY: subFyMin, maxY: subFyMax)
                let subFootprint = CGRect(
                    x: support.footprint.minX + (Double(ix0) / swFull) * support.footprint.width,
                    y: support.footprint.minY + (Double(iy0) / shFull) * support.footprint.height,
                    width: (Double(subW) / swFull) * support.footprint.width,
                    height: (Double(subH) / shFull) * support.footprint.height)
                let decodeMaximum = min(
                    Int(originalLong),
                    max(1, Int(ceil(originalLong * max(swFull, shFull) / footprintLong))))
                let subSize = CGSize(width: subW, height: subH)
                let subCenterInput = try SourceImageRenderer.prepare(
                    data: data, fallback: source, recipe: recipe, maximum: decodeMaximum,
                    sourceType: sourceType, intent: .developedPhoto, description: sourceDescription,
                    decoder: detailDecoder, framing: recipe, customCropNormalized: subFootprint,
                    targetSize: subSize, allowsStore: false)
                let exposedPatch = try FilmEdgeRenderer.exposeCenter(
                    subCenterInput, geometry: geometry, intent: .developedPhoto, filmBounds: subBounds)
                let luts = recipe.look.enabled ? try applications(recipe) : []
                let tonedPatch = try ToneRenderer.working(
                    try SourceImageRenderer.workingImage(exposedPatch), tone: recipe.tone.rawStage)
                var gradedPatch = try ToneRenderer.render(
                    tonedPatch, tone: recipe.tone.outputStage, luts: luts)
                if layout.distress.leakShape == .burn && layout.distress.leak > 0 && geometry.burnFrontDepth > -50 {
                    let subScene = try SourceImageRenderer.prepare(
                        data: data, fallback: source, recipe: material, maximum: decodeMaximum,
                        sourceType: sourceType, intent: .sceneLinear, description: sourceDescription,
                        decoder: detailDecoder, framing: recipe, customCropNormalized: subFootprint,
                        targetSize: subSize, allowsStore: false)
                    let burn = burnResponse(material: material, pipeline: pipeline, autoExposureEV: autoEV)
                    let cancelFlag = FilmEdgeRenderer.CancelFlag()
                    gradedPatch = try await withTaskCancellationHandler {
                        try FilmEdgeRenderer.applyMaterialBurn(
                            gradedPatch, scene: subScene, geometry: geometry,
                            response: burn, filmBounds: subBounds,
                            isCancelled: { cancelFlag.isCancelled })
                    } onCancel: {
                        cancelFlag.cancel()
                    }
                }
                let paperPrint = !material.bypassesPrint
                    && FilmStock.prints.first { $0.id == material.printID }?.support != "film"
                composedFilm = try FilmEdgeRenderer.replacingCenterPatch(
                    film, with: gradedPatch, filmBounds: subBounds,
                    origin: (x0, y0), size: (pw, ph),
                    geometry: geometry, paperPrint: paperPrint,
                    finished: original.tone.outputStage.isIdentity)
            } else {
                composedFilm = film
            }
        } else {
            composedFilm = film
        }
        return Detail(
            image: try FilmEdgeRenderer.restoringPaper(
                ToneRenderer.render(composedFilm, tone: original.tone.outputStage),
                geometry: geometry, origin: (x0, y0)),
            rect: CGRect(
                x: Double(x0) / Double(width), y: Double(y0) / Double(height),
                width: Double(x1 - x0) / Double(width), height: Double(y1 - y0) / Double(height)))
    }

    /// Complete capture-support presentation, before paper placement and final file encoding.
    /// The final long edge includes the rebate; native export never grows the canvas silently.
    func renderFilmEdge(
        _ original: EditRecipe, maximum: Int?, allowOvercommit: Bool = false,
        use: RenderPrecision.Use = .output
    ) async throws -> CGImage {
        try await RenderPrecision.withContext(sourcePrefersDeep: sourcePrefersDeep, use: use) {
            try await renderFilmEdgeBody(original, maximum: maximum, allowOvercommit: allowOvercommit)
        }
    }

    func renderDistressedPrint(
        _ original: EditRecipe, maximum: Int?, allowOvercommit: Bool = false,
        use: RenderPrecision.Use = .output
    ) async throws -> CGImage {
        try await RenderPrecision.withContext(sourcePrefersDeep: sourcePrefersDeep, use: use) {
            try await renderDistressedPrintBody(original, maximum: maximum, allowOvercommit: allowOvercommit)
        }
    }

    private func renderDistressedPrintBody(
        _ original: EditRecipe, maximum: Int?, allowOvercommit: Bool
    ) async throws -> CGImage {
        try Task.checkCancellation()
        syncPrecision()
        guard let rawDistress = original.activeCleanPrintDistress else {
            let developed = try await render(original, maximum: maximum)
            guard let transformed = GeometryRenderer.render(developed, geometry: original.geometry),
                  let cropped = transformed.cropping(to: original.crop.pixelRect(in: CGSize(width: transformed.width, height: transformed.height)))
            else { throw PhotoExporter.Failure.render }
            return cropped
        }
        let dimensions = sourceDescription.map { CGSize(width: $0.width, height: $0.height) }
            ?? CGSize(width: source.width, height: source.height)
        var recipe = original
        recipe.tone.monochrome = false
        let oriented = recipe.geometry.quarterTurns % 2 == 0 ? dimensions
            : CGSize(width: dimensions.height, height: dimensions.width)
        let crop = recipe.crop.pixelRect(in: oriented)
        let nativeLong = max(1, Int(max(crop.width, crop.height)))
        let long = min(nativeLong, maximum ?? nativeLong)
        guard let geometry = FilmEdgeGeometry(cleanPrintSize: crop.size, distress: rawDistress, longEdge: long)
        else { throw PhotoExporter.Failure.render }
        let supportSize = geometry.supportPixelSize
        let footprint = CGRect(
            x: crop.minX / max(1, oriented.width),
            y: crop.minY / max(1, oriented.height),
            width: crop.width / max(1, oriented.width),
            height: crop.height / max(1, oriented.height))
        let footprintLong = max(1.0, max(crop.width, crop.height))
        let supportLong = max(supportSize.width, supportSize.height)
        let originalLong = max(dimensions.width, dimensions.height)
        let decodeMaximum = min(Int(originalLong), max(1, Int(ceil(originalLong * supportLong / footprintLong))))
        let decodeScale = Double(decodeMaximum) / originalLong
        _ = try RenderMemoryBudget.check(
            width: max(1, Int(ceil(dimensions.width * decodeScale))),
            height: max(1, Int(ceil(dimensions.height * decodeScale))),
            recipe: recipe, allowOvercommit: allowOvercommit,
            pixelPitchMicrometers: geometry.pixelPitchMicrometers)
        let plan = try RenderMemoryBudget.check(
            width: geometry.width, height: geometry.height,
            recipe: recipe, allowOvercommit: allowOvercommit,
            pixelPitchMicrometers: geometry.pixelPitchMicrometers)
        let centerIntent: SourceImageRenderer.Intent =
            recipe.inputMode == .spektrafilm ? .sceneLinear : .developedPhoto
        let loadedResources: (library: ModelLibrary, gpu: MetalFilmPipeline)?
        let sceneExposureScale: Double
        if recipe.look.enabled {
            let loaded = try await renderResources.load()
            loadedResources = loaded
            seedEdgeMeteringIfNeeded()
            if centerIntent == .sceneLinear {
                let autoEV = try exposure(recipe, library: loaded.0, state: edgeMetering)
                sceneExposureScale = pow(2, autoEV + recipe.number("camera.exposure_compensation_ev") + recipe.tone.rawStage.exposureEV)
            } else {
                sceneExposureScale = 1.0
            }
        } else {
            loadedResources = nil
            sceneExposureScale = 1.0
        }
        var baseRecipe = recipe
        baseRecipe.filmEdgeLayout = nil
        baseRecipe.filmEdgeSelection = nil
        baseRecipe.printLayout = nil
        baseRecipe.distress = nil
        let centreKey = EdgeCentreKey(
            baseRecipe: baseRecipe, footprint: footprint, size: supportSize,
            precision: RenderPrecision.resolved,
            exposure: EdgeCentreExposureKey(
                format: .film35, effective: geometry.distress, perforation: .ks1870,
                sceneExposureScale: sceneExposureScale))
        let unburnedCenter: CGImage
        if let hit = edgeCentres.firstIndex(where: { $0.key == centreKey }) {
            let entry = edgeCentres.remove(at: hit)
            edgeCentres.append(entry)
            unburnedCenter = entry.image
        } else {
            let sourceInput = try edgeSource(
                recipe, framing: recipe, footprint: footprint, maximum: decodeMaximum,
                intent: centerIntent, size: supportSize)
            let exposeFlag = FilmEdgeRenderer.CancelFlag()
            let centerInput = try await withTaskCancellationHandler {
                try FilmEdgeRenderer.exposeCenter(
                    sourceInput, geometry: geometry, intent: centerIntent,
                    sceneExposureScale: sceneExposureScale,
                    isCancelled: { exposeFlag.isCancelled })
            } onCancel: {
                exposeFlag.cancel()
            }
            if let (library, gpu) = loadedResources {
                unburnedCenter = try await frame(
                    centerInput, recipe: recipe, library: library, gpu: gpu, preview: false,
                    state: edgeMetering,
                    framing: (recipe, footprint, supportSize, decodeMaximum, geometry),
                    plan: plan, workingOutput: true)
            } else {
                unburnedCenter = try neutralFrame(centerInput, recipe: recipe, workingOutput: true)
            }
            edgeCentres.append((centreKey, unburnedCenter))
            if edgeCentres.count > 3 { edgeCentres.removeFirst() }
        }
        try Task.checkCancellation()
        let center: CGImage
        if rawDistress.leakShape == .burn && rawDistress.isLeakEnabled && geometry.burnFrontDepth > -50 {
            let library: ModelLibrary = if let loadedResources {
                loadedResources.0
            } else {
                try await renderResources.loadModel()
            }
            seedEdgeMeteringIfNeeded()
            let material = FilmEdgeRenderer.materialRecipe(recipe)
            let materialPipeline = try await renderResources.pipeline(material)
            let burnEV = try exposure(material, library: library, state: edgeMetering)
            let sceneInput = try edgeSource(
                material, framing: recipe, footprint: footprint, maximum: decodeMaximum,
                intent: .sceneLinear, size: supportSize)
            let burn = burnResponse(material: material, pipeline: materialPipeline, autoExposureEV: burnEV)
            let burnFlag = FilmEdgeRenderer.CancelFlag()
            center = try await withTaskCancellationHandler {
                try FilmEdgeRenderer.applyMaterialBurn(
                    unburnedCenter, scene: sceneInput, geometry: geometry, response: burn,
                    isCancelled: { burnFlag.isCancelled })
            } onCancel: {
                burnFlag.cancel()
            }
        } else {
            center = unburnedCenter
        }
        try Task.checkCancellation()
        let paperPrint = !recipe.bypassesPrint && FilmStock.prints.first { $0.id == recipe.printID }?.support != "film"
        let finished = original.tone.outputStage.isIdentity
        let damaged = try FilmEdgeRenderer.applyCleanPrintDamage(
            center, geometry: geometry, paperPrint: paperPrint, finished: finished)
        return finished ? damaged : try ToneRenderer.render(damaged, tone: original.tone.outputStage)
    }

    func renderDistressedPrintDetail(_ original: EditRecipe, visible: CGRect) async throws -> Detail? {
        try await RenderPrecision.withContext(sourcePrefersDeep: sourcePrefersDeep, use: .output) {
            try await renderDistressedPrintDetailBody(original, visible: visible)
        }
    }

    private func renderDistressedPrintDetailBody(_ original: EditRecipe, visible: CGRect) async throws -> Detail? {
        try Task.checkCancellation()
        syncPrecision()
        guard data != nil,
              original.geometry.straightenDegrees == 0,
              let rawDistress = original.activeCleanPrintDistress
        else { return nil }
        var recipe = original
        recipe.tone.monochrome = false
        let centerHasSpatial = recipe.look.enabled && (
            recipe.look.mode == .spektrafilm
            || recipe.flag("film_render.halation.active")
            || recipe.flag("camera.diffusion_filter.active")
            || recipe.flag("enlarger.diffusion_filter.active")
            || recipe.flag("film_render.grain.active"))
        if centerHasSpatial { return nil }
        let dimensions = sourceDescription.map { CGSize(width: $0.width, height: $0.height) }
            ?? CGSize(width: source.width, height: source.height)
        let oriented = recipe.geometry.quarterTurns % 2 == 0 ? dimensions
            : CGSize(width: dimensions.height, height: dimensions.width)
        let crop = recipe.crop.pixelRect(in: oriented)
        let long = max(1, Int(max(crop.width, crop.height)))
        guard long > previewMaximum * 5 / 4,
              let geometry = FilmEdgeGeometry(cleanPrintSize: crop.size, distress: rawDistress, longEdge: long)
        else { return nil }
        let shown = visible.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !shown.isEmpty else { return nil }
        let width = geometry.width, height = geometry.height
        let x0 = min(max(Int(floor(shown.minX * Double(width))), 0), width - 1)
        let y0 = min(max(Int(floor(shown.minY * Double(height))), 0), height - 1)
        let x1 = min(max(Int(ceil(shown.maxX * Double(width))), x0 + 1), width)
        let y1 = min(max(Int(ceil(shown.maxY * Double(height))), y0 + 1), height)
        let pw = x1 - x0, ph = y1 - y0
        let supX = geometry.supportHalf.x, supY = geometry.supportHalf.y
        let mm = geometry.millimetersPerPixel
        let subFxMin = (Double(x0) - Double(width) / 2) * mm
        let subFxMax = (Double(x1) - Double(width) / 2) * mm
        let subFyMin = (Double(y0) - Double(height) / 2) * mm
        let subFyMax = (Double(y1) - Double(height) / 2) * mm
        let subBounds = (minX: subFxMin, maxX: subFxMax, minY: subFyMin, maxY: subFyMax)
        let nx0 = min(max((subFxMin + supX) / (2 * supX), 0), 1)
        let nx1 = min(max((subFxMax + supX) / (2 * supX), nx0), 1)
        let ny0 = min(max((subFyMin + supY) / (2 * supY), 0), 1)
        let ny1 = min(max((subFyMax + supY) / (2 * supY), ny0), 1)
        let footprint = CGRect(
            x: crop.minX / max(1, oriented.width),
            y: crop.minY / max(1, oriented.height),
            width: crop.width / max(1, oriented.width),
            height: crop.height / max(1, oriented.height))
        let subFootprint = CGRect(
            x: footprint.minX + nx0 * footprint.width,
            y: footprint.minY + ny0 * footprint.height,
            width: max(1e-6, (nx1 - nx0) * footprint.width),
            height: max(1e-6, (ny1 - ny0) * footprint.height))
        let originalLong = Int(max(dimensions.width, dimensions.height))
        let subSize = CGSize(width: pw, height: ph)
        let subCenterInput = try SourceImageRenderer.prepare(
            data: data, fallback: source, recipe: recipe, maximum: originalLong,
            sourceType: sourceType, intent: .developedPhoto, description: sourceDescription,
            decoder: detailDecoder, framing: recipe, customCropNormalized: subFootprint,
            targetSize: subSize, allowsStore: false)
        let exposedPatch = try FilmEdgeRenderer.exposeCenter(
            subCenterInput, geometry: geometry, intent: .developedPhoto, filmBounds: subBounds)
        let luts = recipe.look.enabled ? try applications(recipe) : []
        var gradedPatch: CGImage
        if recipe.look.enabled {
            let tonedPatch = try ToneRenderer.working(
                try SourceImageRenderer.workingImage(exposedPatch), tone: recipe.tone.rawStage)
            gradedPatch = try ToneRenderer.working(
                tonedPatch, tone: recipe.tone.outputStage, luts: luts)
        } else {
            gradedPatch = try ToneRenderer.working(
                try SourceImageRenderer.workingImage(exposedPatch), tone: recipe.tone)
        }
        try Task.checkCancellation()
        if rawDistress.leakShape == .burn && rawDistress.isLeakEnabled && geometry.burnFrontDepth > -50 {
            let material = FilmEdgeRenderer.materialRecipe(recipe)
            let library = try await renderResources.loadModel()
            seedEdgeMeteringIfNeeded()
            let burnEV = try exposure(material, library: library, state: edgeMetering)
            let materialPipeline = try await renderResources.pipeline(material)
            let subScene = try SourceImageRenderer.prepare(
                data: data, fallback: source, recipe: material, maximum: originalLong,
                sourceType: sourceType, intent: .sceneLinear, description: sourceDescription,
                decoder: detailDecoder, framing: recipe, customCropNormalized: subFootprint,
                targetSize: subSize, allowsStore: false)
            let burn = burnResponse(material: material, pipeline: materialPipeline, autoExposureEV: burnEV)
            let burnFlag = FilmEdgeRenderer.CancelFlag()
            gradedPatch = try await withTaskCancellationHandler {
                try FilmEdgeRenderer.applyMaterialBurn(
                    gradedPatch, scene: subScene, geometry: geometry,
                    response: burn, filmBounds: subBounds,
                    isCancelled: { burnFlag.isCancelled })
            } onCancel: {
                burnFlag.cancel()
            }
        }
        let paperPrint = !recipe.bypassesPrint && FilmStock.prints.first { $0.id == recipe.printID }?.support != "film"
        let finished = original.tone.outputStage.isIdentity
        let damaged = try FilmEdgeRenderer.applyCleanPrintDamage(
            gradedPatch, geometry: geometry, paperPrint: paperPrint, origin: (x0, y0), finished: finished)
        let finalImage = finished ? damaged : try ToneRenderer.render(damaged, tone: original.tone.outputStage)
        return Detail(
            image: finalImage,
            rect: CGRect(
                x: Double(x0) / Double(width), y: Double(y0) / Double(height),
                width: Double(pw) / Double(width), height: Double(ph) / Double(height)))
    }
    private func renderFilmEdgeBody(
        _ original: EditRecipe, maximum: Int?, allowOvercommit: Bool
    ) async throws -> CGImage {
        try Task.checkCancellation()
        syncPrecision()
        guard let layout = original.renderedFilmEdgeLayout else { throw PhotoExporter.Failure.render }
        let dimensions = sourceDescription.map { CGSize(width: $0.width, height: $0.height) }
            ?? CGSize(width: source.width, height: source.height)
        var recipe = original
        let oriented = original.geometry.quarterTurns % 2 == 0 ? dimensions
            : CGSize(width: dimensions.height, height: dimensions.width)
        let support = layout.sourceSupport(for: recipe.crop, imageSize: oriented)
        recipe.crop = support.constrainedCrop
        let crop = recipe.crop.pixelRect(in: oriented)
        let nativeLong = max(1, Int(max(crop.width, crop.height)))
        let long = min(nativeLong, maximum ?? nativeLong)
        recipe.tone.monochrome = false
        let material = FilmEdgeRenderer.materialRecipe(recipe)
        // Holes follow the source stock: cine camera negatives are BH-1866, still film KS-1870.
        guard let geometry = FilmEdgeGeometry(imageSize: crop.size, layout: layout, longEdge: long,
                                              perforation: layout.resolvedPerforation(filmID: material.filmID),
                                              easel: recipe.printLayout ?? PrintLayout())
        else { throw PhotoExporter.Failure.render }
        let supportSize = geometry.supportPixelSize
        let footprintLong = max(1.0, max(support.footprint.width * oriented.width, support.footprint.height * oriented.height))
        let supportLong = max(supportSize.width, supportSize.height)
        let originalLong = max(dimensions.width, dimensions.height)
        let decodeMaximum = min(Int(originalLong), max(1, Int(ceil(originalLong * supportLong / footprintLong))))
        let decodeScale = Double(decodeMaximum) / originalLong
        _ = try RenderMemoryBudget.check(width: max(1, Int(ceil(dimensions.width * decodeScale))),
            height: max(1, Int(ceil(dimensions.height * decodeScale))), recipe: material, allowOvercommit: allowOvercommit,
            pixelPitchMicrometers: geometry.pixelPitchMicrometers)
        let edgePlan = try RenderMemoryBudget.check(width: geometry.width, height: geometry.height,
            recipe: material, allowOvercommit: allowOvercommit, pixelPitchMicrometers: geometry.pixelPitchMicrometers)
        let (library, gpu) = try await renderResources.load()
        seedEdgeMeteringIfNeeded()
        let autoEV = try exposure(material, library: library, state: edgeMetering)
        let input = try edgeSource(
            material, framing: recipe, footprint: support.footprint, maximum: decodeMaximum,
            intent: .sceneLinear, size: supportSize)
        let pipeline = try await renderResources.pipeline(material)
        let composes = material.processingRecipe != recipe.processingRecipe
        // A composed centre fades through the soft gate itself, so the material graph's scene must
        // stop inside the penumbra; otherwise its own developed image shows as a rim.
        var materialGeometry = geometry
        materialGeometry.erodesGate = composes
        var image = try await filmImage(
            FilmEdgeRenderer.padded(input, geometry: geometry), pipeline: pipeline, gpu: gpu,
            autoExposureEV: autoEV, edge: materialGeometry,
            finished: !composes && original.tone.outputStage.isIdentity, plan: edgePlan)
        try Task.checkCancellation()
        if composes {
            // Release FFT work before a large full-res centre render, keeping preview textures warm.
            if PixelStore.isLarge(width: geometry.width, height: geometry.height) {
                await gpu.releaseWorkingCaches()
            }
            var baseRecipe = recipe
            baseRecipe.filmEdgeLayout = nil
            baseRecipe.filmEdgeSelection = nil
            baseRecipe.printLayout = nil
            let centerIntent: SourceImageRenderer.Intent =
                recipe.inputMode == .spektrafilm ? .sceneLinear : .developedPhoto
            let centerExposureScale: Double
            if recipe.look.enabled && centerIntent == .sceneLinear {
                let centerAutoEV = try exposure(recipe, library: library, state: edgeMetering)
                centerExposureScale = pow(2, centerAutoEV + recipe.number("camera.exposure_compensation_ev") + recipe.tone.rawStage.exposureEV)
            } else {
                centerExposureScale = 1.0
            }
            let centreKey = EdgeCentreKey(
                baseRecipe: baseRecipe, footprint: support.footprint, size: supportSize,
                precision: RenderPrecision.resolved,
                exposure: EdgeCentreExposureKey(
                    layout, effective: geometry.distress, perforation: geometry.perforation,
                    sceneExposureScale: centerExposureScale))
            let unburnedCenter: CGImage
            if let hit = edgeCentres.firstIndex(where: { $0.key == centreKey }) {
                let entry = edgeCentres.remove(at: hit)
                edgeCentres.append(entry)
                unburnedCenter = entry.image
            } else {
                let sourceInput = try edgeSource(
                    recipe, framing: recipe, footprint: support.footprint, maximum: decodeMaximum,
                    intent: centerIntent, size: supportSize)
                let exposeFlag = FilmEdgeRenderer.CancelFlag()
                let centerInput = try await withTaskCancellationHandler {
                    try FilmEdgeRenderer.exposeCenter(
                        sourceInput, geometry: geometry, intent: centerIntent,
                        sceneExposureScale: centerExposureScale,
                        isCancelled: { exposeFlag.isCancelled })
                } onCancel: {
                    exposeFlag.cancel()
                }
                unburnedCenter = recipe.look.enabled
                    ? try await frame(
                        centerInput, recipe: recipe, library: library, gpu: gpu, preview: false,
                        state: edgeMetering,
                        framing: (recipe, support.footprint, supportSize, decodeMaximum, geometry),
                        workingOutput: recipe.look.mode == .spektrafilm)
                    : try neutralFrame(centerInput, recipe: recipe)
                edgeCentres.append((centreKey, unburnedCenter))
                if edgeCentres.count > 3 { edgeCentres.removeFirst() }
            }
            let center: CGImage
            if layout.distress.leakShape == .burn && layout.distress.leak > 0 && geometry.burnFrontDepth > -50 {
                let burn = burnResponse(material: material, pipeline: pipeline, autoExposureEV: autoEV)
                let burnFlag = FilmEdgeRenderer.CancelFlag()
                center = try await withTaskCancellationHandler {
                    try FilmEdgeRenderer.applyMaterialBurn(
                        unburnedCenter, scene: input, geometry: geometry, response: burn,
                        isCancelled: { burnFlag.isCancelled })
                } onCancel: {
                    burnFlag.cancel()
                }
            } else {
                center = unburnedCenter
            }
            let paperPrint = !material.bypassesPrint && FilmStock.prints.first { $0.id == material.printID }?.support != "film"
            let coverage = try gateCoverage(for: geometry)
            image = try FilmEdgeRenderer.replacingCenter(
                image, with: center, geometry: geometry, paperPrint: paperPrint, coverage: coverage,
                finished: original.tone.outputStage.isIdentity)
        }
        try Task.checkCancellation()
        return try FilmEdgeRenderer.restoringPaper(
            ToneRenderer.render(image, tone: original.tone.outputStage), geometry: geometry)
    }

    /// Native pixel size of the picture alone (crop, plus its film edge) and of the whole output
    /// (the sheet at one picture pixel per output pixel), before any export size is applied.
    func nativeExportSizes(_ original: EditRecipe) -> (picture: CGSize, output: CGSize) {
        let dimensions = sourceDescription.map { CGSize(width: $0.width, height: $0.height) }
            ?? CGSize(width: source.width, height: source.height)
        var recipe = original
        recipe.constrainFilmEdgeCrop(imageSize: dimensions)
        let oriented = recipe.geometry.quarterTurns % 2 == 0 ? dimensions
            : CGSize(width: dimensions.height, height: dimensions.width)
        let crop = recipe.crop.pixelRect(in: oriented).integral.size
        var picture = crop
        if let layout = recipe.renderedFilmEdgeLayout,
           let geometry = FilmEdgeGeometry(imageSize: crop, layout: layout, longEdge: Int(max(crop.width, crop.height)),
                                          easel: recipe.printLayout ?? PrintLayout()) {
            picture = CGSize(width: geometry.width, height: geometry.height)
        }
        guard let layout = recipe.printedLayout else { return (picture, picture) }
        return (picture, PrintCompositor.nativeSize(imageSize: picture, layout: layout, content: recipe.printContent(canvas: picture)))
    }
    /// The file's pixel size for this export size, known before rendering.
    func exportDimensions(_ recipe: EditRecipe, size: PhotoExporter.Size) -> (width: Int, height: Int) {
        let (picture, output) = nativeExportSizes(recipe)
        let long = max(output.width, output.height)
        let target = exportLongEdges(recipe, size: size).output.map(Double.init) ?? long
        // On paper, the same integer sheet the compositor will make at that long edge.
        if let layout = recipe.printedLayout,
           let sheet = PrintGeometry(imageSize: picture, layout: layout, longEdge: CGFloat(target.rounded()),
                                     content: recipe.printContent(canvas: picture)) {
            return (Int(sheet.paperSize.width), Int(sheet.paperSize.height))
        }
        let factor = target / max(long, 1)
        return (max(1, Int((output.width * factor).rounded())), max(1, Int((output.height * factor).rounded())))
    }
    /// Long-edge caps for the picture render and for the finished output; nil keeps them native.
    private func exportLongEdges(_ recipe: EditRecipe, size: PhotoExporter.Size) -> (picture: Int?, output: Int?) {
        let (picture, output) = nativeExportSizes(recipe)
        let outputLong = max(output.width, output.height), pictureLong = max(picture.width, picture.height)
        let paper = recipe.printedLayout?.paper.longMillimetres.map { $0 / 25.4 }
        guard let cap = size.longEdge(native: Int(outputLong), paperLongInches: paper) else { return (nil, nil) }
        return (Int(ceil(Double(cap) * pictureLong / max(outputLong, 1))), cap)
    }
    func export(
        _ recipe: EditRecipe, size: PhotoExporter.Size, format: PhotoExporter.Format,
        quality: Double,
        allowOvercommit: Bool = false,
        admittedPlan: RenderMemoryBudget.Plan? = nil
    )
        async throws -> (URL, Int, Int)
    {
        try await RenderPrecision.withContext(sourcePrefersDeep: sourcePrefersDeep, use: .output) {
            try await exportBody(
                recipe, size: size, format: format, quality: quality,
                allowOvercommit: allowOvercommit, admittedPlan: admittedPlan)
        }
    }
    private func exportBody(
        _ recipe: EditRecipe, size: PhotoExporter.Size, format: PhotoExporter.Format,
        quality: Double, allowOvercommit: Bool, admittedPlan: RenderMemoryBudget.Plan?
    ) async throws -> (URL, Int, Int) {
        syncPrecision()
        if exportKey != recipe || exportSize != size { exportImage = nil }
        let caps = exportLongEdges(recipe, size: size)
        let image: CGImage
        if let cached = exportImage {
            image = cached
        } else if recipe.filmEdgeLayout != nil {
            guard data != nil else { throw PhotoExporter.Failure.decode }
            releasePreviewCaches(keepMetering: true)
            let (_, gpu) = try await renderResources.load()
            await gpu.releaseWorkingCaches()
            do {
                let edged = try await renderFilmEdge(recipe, maximum: caps.picture, allowOvercommit: allowOvercommit)
                image = try recipe.printedLayout.map {
                    try PrintCompositor.render(edged, layout: $0, maximum: caps.output, paper: Self.paper(recipe, edged),
                                               content: recipe.printContent(canvas: CGSize(width: edged.width, height: edged.height)))
                } ?? edged
            } catch {
                await gpu.releaseWorkingCaches()
                throw error
            }
            await gpu.releaseWorkingCaches()
        } else if recipe.activeCleanPrintDistress != nil {
            guard data != nil else { throw PhotoExporter.Failure.decode }
            releasePreviewCaches(keepMetering: true)
            let (_, gpu) = try await renderResources.load()
            await gpu.releaseWorkingCaches()
            do {
                let distressed = try await renderDistressedPrint(recipe, maximum: caps.picture, allowOvercommit: allowOvercommit)
                image = try recipe.printedLayout.map {
                    try PrintCompositor.render(distressed, layout: $0, maximum: caps.output, paper: Self.paper(recipe, distressed),
                                               content: recipe.printContent(canvas: CGSize(width: distressed.width, height: distressed.height)))
                } ?? distressed
            } catch {
                await gpu.releaseWorkingCaches()
                throw error
            }
            await gpu.releaseWorkingCaches()
        } else {
            releasePreviewCaches(keepMetering: true)
            guard let data else { throw PhotoExporter.Failure.decode }
            let dimensions: CGSize
            if let sourceDescription, sourceDescription.width > 0, sourceDescription.height > 0 {
                dimensions = CGSize(width: sourceDescription.width, height: sourceDescription.height)
            } else {
                dimensions = try PhotoExporter.sourceDimensions(data, sourceType: sourceType)
            }
            let width = Int(dimensions.width)
            let height = Int(dimensions.height)
            let originalLong = max(width, height)
            let baseWidth = CGFloat(sourceDescription?.width ?? source.width)
            let baseHeight = CGFloat(sourceDescription?.height ?? source.height)
            let oriented =
                recipe.geometry.quarterTurns % 2 == 0
                ? CGSize(width: baseWidth, height: baseHeight)
                : CGSize(width: baseHeight, height: baseWidth)
            let crop = recipe.crop.pixelRect(in: oriented)
            let fraction = max(crop.width, crop.height) / max(oriented.width, oriented.height)
            let maximum = min(
                originalLong,
                caps.picture.map { Int(ceil(Double($0) / max(fraction, 1e-6))) } ?? originalLong
            )
            let scale = Double(maximum) / Double(originalLong)
            if recipe.look.enabled {
                let (_, exportGPU) = try await renderResources.load()
                await exportGPU.releaseWorkingCaches()
            }
            preview.filmImage = nil
            preview.opticsImage = nil
            preview.grainImages = nil
            let plan: RenderMemoryBudget.Plan
            if let admittedPlan, admittedPlan.estimatedBytes < ImageMemoryAllowance.available {
                plan = admittedPlan
            } else {
                plan = try RenderMemoryBudget.check(
                    width: max(1, Int(ceil(Double(width) * scale))),
                    height: max(1, Int(ceil(Double(height) * scale))), recipe: recipe,
                    allowOvercommit: allowOvercommit)
            }
            // The RAW input path decodes directly to float; an 8-bit fallback decode is redundant.
            let decoded = source
            selectInputMode(recipe.inputMode)
            let input = try SourceImageRenderer.prepare(
                data: data, fallback: decoded, recipe: recipe, maximum: maximum,
                sourceType: sourceType, description: sourceDescription, allowsStore: true)
            let graded: CGImage
            if recipe.look.enabled {
                let (library, gpu) = try await renderResources.load()
                do {
                    graded = try await frame(
                        input, recipe: recipe, library: library, gpu: gpu, preview: false,
                        plan: plan)
                } catch {
                    await gpu.releaseWorkingCaches()
                    throw error
                }
                await gpu.releaseWorkingCaches()
            } else {
                graded = try neutralFrame(input, recipe: recipe)
            }
            try Task.checkCancellation()
            guard let transformed = GeometryRenderer.render(graded, geometry: recipe.geometry),
                let cropped = transformed.cropping(
                    to: recipe.crop.pixelRect(
                        in: CGSize(width: transformed.width, height: transformed.height)))
            else { throw PhotoExporter.Failure.render }
            if let layout = recipe.printedLayout {
                image = try PrintCompositor.render(cropped, layout: layout, maximum: caps.output)
            } else {
                image = try Self.resize(cropped, maximum: caps.output)
            }
            exportImage = image
            exportKey = recipe
            exportSize = size
        }
        try Task.checkCancellation()
        let url = try PhotoExporter.write(
            image, format: format, quality: quality,
            sourceData: data, sourceType: sourceType, sourceFilename: sourceFilename)
        if Task.isCancelled {
            try? FileManager.default.removeItem(at: url)
            throw CancellationError()
        }
        // The encoded file owns the export now; do not retain a full-resolution float bitmap.
        discardExport()
        return (url, image.width, image.height)
    }
    func discardExport() {
        exportImage = nil
        exportKey = nil
        exportSize = nil
    }
    func releasePreviewCaches(keepMetering: Bool = false) {
        let next = PreviewState(maximum: previewMaximum, cachesIntermediates: cachesIntermediates)
        let nextEdge = PreviewState(maximum: 720, cachesIntermediates: cachesIntermediates)
        nextEdge.inputLookMode = .spektrafilm
        if keepMetering {
            next.meter = preview.meter
            next.meteredEV = preview.meteredEV
            nextEdge.meter = edgeMetering.meter
            nextEdge.meteredEV = edgeMetering.meteredEV
        }
        preview = next
        edgeMetering = nextEdge
        alternatePreview = nil
        edgeSources = []
        edgeCentres = []
        edgeMasks = []
        cachedBurnResponse = nil
    }
    private static func resize(_ image: CGImage, maximum: Int?) throws -> CGImage {
        guard let maximum, max(image.width, image.height) > maximum else { return image }
        let scale = Double(maximum) / Double(max(image.width, image.height))
        let output = CIImage(cgImage: image).applyingFilter(
            "CILanczosScaleTransform",
            parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
        let rect = CGRect(
            x: 0, y: 0, width: floor(Double(image.width) * scale),
            height: floor(Double(image.height) * scale)
        )
        guard
            let resized = CIContext(options: [.cacheIntermediates: false]).createCGImage(
                output, from: rect, format: .RGBA8,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        else { throw PhotoExporter.Failure.render }
        return resized
    }
}
