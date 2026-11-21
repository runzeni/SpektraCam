import Foundation
import Metal

#if os(iOS)
    import os
#endif

/// Conservative admission check before decoding a full-size source. A rejected request
/// stays at the chosen size; it never silently substitutes a low-resolution export.
nonisolated enum RenderMemoryBudget {
    struct Failure: LocalizedError {
        var estimated: UInt64? = nil
        var available: UInt64? = nil
        var errorDescription: String? {
            if let estimated, let available {
                return
                    String(
                        localized: "render.error.memory_estimate",
                        defaultValue:
                            "This render is estimated to need \(estimated / 1_048_576) MB; the current safe allowance is \(available / 1_048_576) MB. Choose a smaller size or disable diffusion and try again."
                    )
            }
            return String(
                localized: "render.error.size_limit",
                defaultValue:
                    "This size exceeds the rendering limits. Choose a smaller size and try again.")
        }
    }
    /// A whole-frame diffusion transform pads to a power of two around the full kernel radius.
    /// Past this size the frame is rendered in tiles, where the transform stays tile-sized.
    static let wholeFrameTransformLimit: UInt64 = 512 * 1024 * 1024
    static func rendersInTiles(width: Int, height: Int, transformBytes: UInt64) -> Bool {
        PixelStore.isLarge(width: width, height: height) || transformBytes > wholeFrameTransformLimit
    }
    /// Whether this frame takes the tiled path. The renderer and the admission check agree on it.
    static func rendersInTiles(
        width: Int, height: Int, recipe: EditRecipe, pixelPitchMicrometers: Double? = nil
    ) -> Bool {
        guard width > 0, height > 0 else { return false }
        let transforms = (try? diffusionTransformBytes(
            width: width, height: height, recipe: recipe,
            pixelPitchMicrometers: pixelPitchMicrometers)) ?? 0
        return rendersInTiles(width: width, height: height, transformBytes: transforms)
    }
    /// Working memory of the whole-frame diffusion transforms this recipe would run.
    static func diffusionTransformBytes(
        width: Int, height: Int, recipe: EditRecipe, pixelPitchMicrometers: Double?
    ) throws -> UInt64 {
        var total: UInt64 = 0
        let pitch = pixelPitchMicrometers
            ?? recipe.number("camera.film_format_mm") * 1000 / Double(max(width, height))
        for prefix in ["camera.diffusion_filter", "enlarger.diffusion_filter"] {
            guard recipe.look.enabled else { continue }
            if prefix.hasPrefix("enlarger") && recipe.bypassesPrint { continue }
            guard recipe.flag(prefix + ".active"), recipe.number(prefix + ".strength") > 0 else {
                continue
            }
            var p = DiffusionCore.Parameters()
            p.family = recipe.choice(prefix + ".filter_family")
            p.spatialScale = recipe.number(prefix + ".spatial_scale")
            p.size = .init(
                recipe.number(prefix + ".core_size"), recipe.number(prefix + ".halo_size"),
                recipe.number(prefix + ".bloom_size"))
            let radius = try DiffusionCore.radius(
                width: width, height: height, pixelSize: pitch, parameters: p)
            func power(_ value: Int) -> UInt64 {
                var n: UInt64 = 1
                while n < value { n *= 2 }
                return n
            }
            total += power(width + 2 * radius) * power(height + 2 * radius) * 128
        }
        return total
    }
    struct Plan: Sendable, Equatable {
        let tiled: Bool
        let tiling: MetalFilmPipeline.Tiling
        let estimatedBytes: UInt64
    }

    /// Selects the largest feasible execution plan for `width × height` under `available` headroom
    /// and `maxBufferLength`, stepping down cleanly across smaller tile candidates so more memory
    /// never rejects an export that already fit at lower headroom.
    static func admittedPlan(
        width: Int, height: Int, recipe: EditRecipe, allowOvercommit: Bool = false,
        pixelPitchMicrometers: Double? = nil, available: UInt64? = nil, maxBufferLength: Int? = nil
    ) throws -> Plan {
        guard width > 0, height > 0, width <= 65536, height <= 65536,
            let resolvedBufferLimit = maxBufferLength ?? MTLCreateSystemDefaultDevice()?.maxBufferLength,
            resolvedBufferLimit > 0
        else { throw Failure() }
        let bufferLimit = UInt64(resolvedBufferLimit)
        let allowance = available ?? ImageMemoryAllowance.available
        let pixels = UInt64(width) * UInt64(height)
        // Full-frame graph storage plus CPU input; decode and pointwise grade have separate lifetimes.
        // Pointwise grading uses 128-row strips, including LUT/noise references.
        let halfFloat = RenderPrecision.resolved.usesHalfFloat
        var wholeFrameEstimate = recipe.look.enabled
            ? pixels * (recipe.look.mode == .lut ? (halfFloat ? 144 : 192) : (halfFloat ? 152 : 176))
                + (halfFloat ? 64 : 96) * 1024 * 1024
            : pixels * (halfFloat ? 48 : 80) + 32 * 1024 * 1024
        // The support graph plus an optional retained center/paper bitmap. No mask bitmap.
        if recipe.filmEdgeLayout != nil { wholeFrameEstimate += pixels * (halfFloat ? 36 : 64) }
        if recipe.look.enabled && recipe.look.mode == .spektrafilm && recipe.mix < 1 {
            wholeFrameEstimate += pixels * (halfFloat ? 16 : 32)
        }
        if recipe.look.enabled && recipe.monochromeGrain && recipe.flag("film_render.grain.active") {
            wholeFrameEstimate += pixels * 32
        }
        if max(width, height) <= 2048 && !recipe.tone.outputStage.isIdentity {
            wholeFrameEstimate += pixels * (halfFloat ? 24 : 48)
        }
        let transforms = try diffusionTransformBytes(
            width: width, height: height, recipe: recipe, pixelPitchMicrometers: pixelPitchMicrometers)
        wholeFrameEstimate += transforms

        if !rendersInTiles(width: width, height: height, transformBytes: transforms) {
            let untiledBufferOK = pixels * 16 <= bufferLimit && transforms / 8 <= bufferLimit
            if untiledBufferOK && (allowOvercommit || wholeFrameEstimate < allowance) {
                return Plan(
                    tiled: false, tiling: .fitting(available: allowance),
                    estimatedBytes: wholeFrameEstimate)
            }
            if !recipe.look.enabled {
                guard untiledBufferOK else { throw Failure() }
                throw Failure(estimated: wholeFrameEstimate, available: allowance)
            }
        }

        // Tiled render: choose the largest buffer-valid tile candidate up to the fitting tier
        // that fits within the process allowance, ensuring strict monotonicity as memory grows.
        let fittingEdge = MetalFilmPipeline.Tiling.fitting(available: allowance).tileEdge
        let perPixel: UInt64 =
            recipe.filmEdgeLayout == nil ? (halfFloat ? 8 : 12) : (halfFloat ? 12 : 18)
        let baseOverhead: UInt64 = (halfFloat ? 112 : 160) * 1024 * 1024
        var largestBufferValid: Plan?
        var smallestEstimate: UInt64?

        for candidate in MetalFilmPipeline.Tiling.candidates where candidate.tileEdge <= fittingEdge {
            let edge = UInt64(min(candidate.tileEdge, max(width, height)))
            let tileBuffer = edge * edge * 16
            let factor = candidate.resolvedFactor(width: width, height: height)
            let proxyWidth = UInt64((width + factor - 1) / factor + 1)
            let proxyHeight = UInt64((height + factor - 1) / factor + 1)
            let proxyBuffer = proxyWidth * proxyHeight * 16
            let fftBuffer =
                transforms > 0
                ? UInt64(candidate.transform) * UInt64(candidate.transform) * 16 : 0
            guard max(tileBuffer, max(proxyBuffer, fftBuffer)) <= bufferLimit else { continue }

            let graph: UInt64 = recipe.look.enabled ? edge * edge * 16 * 14 : 0
            let estimate = graph + pixels * perPixel + baseOverhead
            let plan = Plan(tiled: true, tiling: candidate, estimatedBytes: estimate)
            if largestBufferValid == nil { largestBufferValid = plan }
            smallestEstimate = estimate
            if estimate < allowance {
                return plan
            }
        }

        guard let fallback = largestBufferValid, let smallestEstimate else {
            throw Failure()
        }
        if allowOvercommit { return fallback }
        throw Failure(estimated: smallestEstimate, available: allowance)
    }

    @discardableResult
    static func check(
        width: Int, height: Int, recipe: EditRecipe, allowOvercommit: Bool = false,
        pixelPitchMicrometers: Double? = nil, available: UInt64? = nil, maxBufferLength: Int? = nil
    ) throws -> Plan {
        try admittedPlan(
            width: width, height: height, recipe: recipe, allowOvercommit: allowOvercommit,
            pixelPitchMicrometers: pixelPitchMicrometers, available: available,
            maxBufferLength: maxBufferLength)
    }
}
