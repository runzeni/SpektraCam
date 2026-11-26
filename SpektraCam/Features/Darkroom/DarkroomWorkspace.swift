import SwiftUI
import UIKit

/// Retained across tool switches within one open `EditorView` so returning to Darkroom from
/// Adjust, Develop or Crop keeps the loupe's placement and last rendered film-edge frame intact.
struct DarkroomWorkspaceState {
    var loupeAnchor: CGPoint?
    var edgeImage: UIImage?
    var edgeImageKey: EditRecipe?
    var edgeImageMaximum = 0
    var loupeImage: UIImage?
    var loupeKey: EditRecipe?
    var loupePatch: PhotoRenderer.Detail?
    var loupePatchKey: EditRecipe?
    /// Edits whose route cannot render a patch fall back to one whole frame for the loupe.
    var wholeFrameKey: EditRecipe?

    mutating func releaseTransientImages(keepEdgePreview: Bool) {
        loupeImage = nil
        loupeKey = nil
        loupePatch = nil
        loupePatchKey = nil
        if !keepEdgePreview {
            edgeImage = nil
            edgeImageKey = nil
            edgeImageMaximum = 0
        }
    }
}

/// Finishing work has a separate lifetime from Develop. Paper drags never start a film frame.
struct DarkroomWorkspace: View {
    let session: EditorSession
    @Binding var state: DarkroomWorkspaceState
    var suspended = false
    var layout = WorkspaceLayout.stacked
    var adjustCrop: (_ groupingStarted: Bool) -> Void = { _ in }
    @Environment(\.displayScale) private var displayScale
    @State private var viewportLongEdge: CGFloat = 0
    @State private var pending = false
    @State private var failure: String?
    @State private var retry = 0
    @State private var interacting = false
    @State private var edgeDesiredRevision: UInt64 = 0
    @State private var edgeRenderTask: Task<Void, Never>?
    @State private var edgeInFlightSettled = false
    @State private var loupeRefining = false
    @State private var loupeRect: CGRect?
    @AppStorage("darkroom.loupe") private var showLoupe = false
    private static let unitSquare = CGRect(x: 0, y: 0, width: 1, height: 1)
    /// Enough for 100 % at native resolution on most phones without an export-sized render; capped under thermal pressure.
    private static var loupeMaximum: Int {
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical: 2560
        case .nominal, .fair: 4096
        @unknown default: 2560
        }
    }
    private var renderKey: EditRecipe {
        var key = session.recipe
        // The easel's hand-set placement is part of a film-edge render; the paper is not.
        key.printLayout = key.printLayout?.easelOnly
        return key
    }
    /// The cropped photograph's pixel size after its quarter turns (constrained to `recipe`'s gate if any).
    private func cropSize(for recipe: EditRecipe) -> CGSize {
        let upright = recipe.geometry.quarterTurns % 2 == 0
            ? CGSize(width: session.photo.width, height: session.photo.height)
            : CGSize(width: session.photo.height, height: session.photo.width)
        let crop = recipe.filmEdgeLayout?.constrainedCrop(recipe.crop, imageSize: upright) ?? recipe.crop
        return crop.pixelRect(in: upright).size
    }
    private var rawCropSize: CGSize {
        let upright = session.recipe.geometry.quarterTurns % 2 == 0
            ? CGSize(width: session.photo.width, height: session.photo.height)
            : CGSize(width: session.photo.height, height: session.photo.width)
        return session.recipe.crop.pixelRect(in: upright).size
    }
    private func matchesAspect(_ a: CGSize, _ b: CGSize, tolerance: Double = 0.025) -> Bool {
        guard a.width > 0, a.height > 0, b.width > 0, b.height > 0 else { return false }
        let samePortrait = (a.height > a.width) == (b.height > b.width)
            || abs(b.width - b.height) / max(b.width, b.height) < 0.02
        return samePortrait && abs(log((a.width / a.height) / (b.width / b.height))) < tolerance
    }
    private func loupePixelWidth(crop: CGSize, canvas: CGSize) -> CGFloat? {
        guard crop.width > 0, crop.height > 0, canvas.width > 0, canvas.height > 0 else { return nil }
        let long = max(crop.width, crop.height)
        return (long * canvas.width / max(canvas.width, canvas.height)).rounded()
    }
    private struct PresentedCanvas {
        let image: UIImage
        let imageReady: Bool
        let sourceSize: CGSize
        let imageSubRect: CGRect
        let canvasFill: Color?
        let canvasFillRect: CGRect
        let renderedEdge: FilmEdgeLayout?
        let visibleKey: EditRecipe
        let loupeWidth: CGFloat?
    }
    private func canReuseEdgePreview(_ edgeLayout: FilmEdgeLayout, for currentEdge: FilmEdgeLayout) -> Bool {
        guard edgeLayout.format == currentEdge.format,
              edgeLayout.frame35 == currentEdge.frame35,
              edgeLayout.rollFrame == currentEdge.rollFrame,
              edgeLayout.distress.enlargerPrint == currentEdge.distress.enlargerPrint,
              edgeLayout.distress.invertedScan == currentEdge.distress.invertedScan
        else { return false }
        if interacting { return true }
        return abs(edgeLayout.apertureScale - currentEdge.apertureScale) < 1e-6
            && abs(edgeLayout.printZoom - currentEdge.printZoom) < 1e-6
            && abs(edgeLayout.scanZoom - currentEdge.scanZoom) < 1e-6
    }
    private var presented: PresentedCanvas {
        let currentCrop = cropSize(for: session.recipe)
        guard session.recipe.filmEdgeLayout != nil else {
            if let currentDistress = session.recipe.activeCleanPrintDistress {
                if let edgeImage = state.edgeImage,
                   let edgeKey = state.edgeImageKey,
                   edgeKey.filmEdgeLayout == nil,
                   let cachedDistress = edgeKey.activeCleanPrintDistress,
                   edgeKey.geometry == session.recipe.geometry,
                   edgeKey.crop == session.recipe.crop,
                   edgeKey.processingRecipe == renderKey.processingRecipe
                {
                    let canvasSize = edgeImage.size
                    return PresentedCanvas(
                        image: edgeImage,
                        imageReady: matchesAspect(edgeImage.size, currentCrop, tolerance: 0.03),
                        sourceSize: canvasSize,
                        imageSubRect: Self.unitSquare,
                        canvasFill: nil,
                        canvasFillRect: Self.unitSquare,
                        renderedEdge: nil,
                        visibleKey: edgeKey,
                        loupeWidth: loupePixelWidth(crop: currentCrop, canvas: currentCrop)
                    )
                }
            }
            return PresentedCanvas(
                image: session.displayImage,
                imageReady: matchesAspect(session.displayImage.size, currentCrop),
                sourceSize: currentCrop,
                imageSubRect: Self.unitSquare,
                canvasFill: nil,
                canvasFillRect: Self.unitSquare,
                renderedEdge: nil,
                visibleKey: renderKey,
                loupeWidth: loupePixelWidth(crop: currentCrop, canvas: currentCrop)
            )
        }
        let currentEdge = session.recipe.renderedFilmEdgeLayout
        if let edgeImage = state.edgeImage,
           let edgeKey = state.edgeImageKey,
           edgeKey.geometry == session.recipe.geometry,
           edgeKey.crop == session.recipe.crop,
           edgeKey.processingRecipe == renderKey.processingRecipe,
           let edgeLayout = edgeKey.renderedFilmEdgeLayout,
           let currentEdge,
           canReuseEdgePreview(edgeLayout, for: currentEdge)
        {
            let edgeCrop = cropSize(for: edgeKey)
            if let geo = FilmEdgeGeometry(imageSize: edgeCrop, layout: edgeLayout, longEdge: 1000) {
                let canvasSize = CGSize(width: geo.width, height: geo.height)
                return PresentedCanvas(
                    image: edgeImage,
                    imageReady: matchesAspect(edgeImage.size, canvasSize, tolerance: 0.03),
                    sourceSize: canvasSize,
                    imageSubRect: Self.unitSquare,
                    canvasFill: nil,
                    canvasFillRect: Self.unitSquare,
                    renderedEdge: edgeLayout,
                    visibleKey: edgeKey,
                    loupeWidth: loupePixelWidth(crop: edgeCrop, canvas: canvasSize)
                )
            }
        }
        let edgeLayout = currentEdge
        if let edgeLayout,
           let geo = FilmEdgeGeometry(imageSize: currentCrop, layout: edgeLayout, longEdge: 1000)
        {
            let canvasSize = CGSize(width: geo.width, height: geo.height)
            let w = CGFloat(max(geo.width, 1)), h = CGFloat(max(geo.height, 1))
            let subRect = CGRect(
                x: geo.gate.minX / w,
                y: geo.gate.minY / h,
                width: geo.gate.width / w,
                height: geo.gate.height / h
            )
            let fill = edgeLayout.distress.invertedScan ? Color(white: 0.94) : Color(white: 0.06)
            let fillRect = edgeLayout.distress.enlargerPrint
                ? edgeLayout.easelFrame(canvas: canvasSize)
                : Self.unitSquare
            return PresentedCanvas(
                image: session.displayImage,
                imageReady: matchesAspect(session.displayImage.size, currentCrop),
                sourceSize: canvasSize,
                imageSubRect: subRect,
                canvasFill: fill,
                canvasFillRect: fillRect,
                renderedEdge: edgeLayout,
                visibleKey: renderKey,
                loupeWidth: loupePixelWidth(crop: currentCrop, canvas: canvasSize)
            )
        }
        return PresentedCanvas(
            image: session.displayImage,
            imageReady: matchesAspect(session.displayImage.size, currentCrop),
            sourceSize: currentCrop,
            imageSubRect: Self.unitSquare,
            canvasFill: nil,
            canvasFillRect: Self.unitSquare,
            renderedEdge: edgeLayout,
            visibleKey: renderKey,
            loupeWidth: loupePixelWidth(crop: currentCrop, canvas: currentCrop)
        )
    }
    var body: some View {
        let canvas = presented
        DarkroomView(image: canvas.image, workspace: layout,
            layout: session.binding(\.printLayout, key: "darkroom.layout"),
            edge: Binding(get: { session.recipe.filmEdgeLayout }, set: { layout in
                if session.updateFilmEdgeFromInspector(layout) { adjustCrop(true) }
            }),
            edgeSelection: session.binding(\.filmEdgeSelection, key: "darkroom.edge.selection"),
            cleanDistress: session.binding(\.distress, key: "darkroom.distress"),
            renderedEdge: canvas.renderedEdge,
            resolvedType: session.recipe.resolvedFilmEdgeType,
            adjustCrop: { adjustCrop(false) },
            printSourceSize: canvas.sourceSize,
            imageReady: canvas.imageReady,
            imageSubRect: canvas.imageSubRect,
            canvasFill: canvas.canvasFill,
            canvasFillRect: canvas.canvasFillRect,
            onEditingChanged: { session.setPresentationInteraction(key: "darkroom.layout", active: $0) },
            onEdgeEditingChanged: { active in
                session.setPresentationInteraction(key: "darkroom.edge.layout", active: active)
                interacting = active
            },
            onDiscreteLayoutChange: { next in
                session.performDiscrete(key: "darkroom.layout") { $0.printLayout = next }
            },
            onDiscreteEdgeChange: { next in
                session.performDiscrete(key: "darkroom.edge.layout") { $0.filmEdgeLayout = next }
            },
            onDiscreteCleanDistressChange: { next in
                session.performDiscrete(key: "darkroom.distress") { $0.distress = next }
            },
            onSwitchPresentation: { wantsEdge in
                if session.setFilmEdgePresentation(wantsEdge) { adjustCrop(true) }
            },
            onDistressEdited: { session.markSurfaceDistressEdited($0) },
            loupeImage: state.loupeKey == canvas.visibleKey && canvas.canvasFill == nil ? state.loupeImage : nil,
            loupeRefining: loupeRefining || pending || canvas.visibleKey != renderKey || canvas.canvasFill != nil,
            loupeWidth: canvas.loupeWidth,
            loupePatch: state.loupePatchKey == canvas.visibleKey && canvas.canvasFill == nil ? state.loupePatch : nil,
            onLoupeInspect: { loupeRect = $0 },
            showLoupe: $showLoupe,
            loupeAnchor: $state.loupeAnchor)
        .overlay(alignment: .top) {
            VStack(spacing: 6) {
                if pending { ProgressView().padding(12).adaptiveGlassDefault().accessibilityIdentifier("darkroom.edge.rendering") }
                if let failure {
                    VStack(spacing: 6) {
                        Text(failure).font(.caption)
                        Button(String(localized: "common.retry", defaultValue: "Retry")) { retry += 1 }
                    }.padding(12).adaptiveGlassDefault().accessibilityIdentifier("darkroom.edge.failure")
                }
            }
            .padding(.top, 20)
        }
        .background {
            GeometryReader { proxy in
                Color.clear.task(id: proxy.size) {
                    viewportLongEdge = max(proxy.size.width, proxy.size.height)
                }
            }
        }
        .onAppear { kickEdgeRender() }
        .onDisappear {
            edgeRenderTask?.cancel()
            edgeRenderTask = nil
            edgeInFlightSettled = false
            pending = false
        }
        .onChange(of: currentRequest) { _, _ in kickEdgeRender() }
        .task(id: PatchRequest(recipe: renderKey, rect: loupeRect, active: showLoupe && !suspended && !interacting)) {
            guard showLoupe, !suspended, !interacting, let rect = loupeRect, state.wholeFrameKey != renderKey else { return }
            if state.loupePatchKey == renderKey, let loupePatch = state.loupePatch,
               loupePatch.rect.contains(rect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))) { return }
            let recipe = renderKey
            do {
                // Follow the lens once it rests; a wider patch then covers small moves.
                try await Task.sleep(for: .milliseconds(120))
                while pending { try await Task.sleep(for: .milliseconds(100)) }
                loupeRefining = true
                defer { loupeRefining = false }
                let wide = rect.insetBy(dx: -0.6 * rect.width, dy: -0.6 * rect.height)
                if let patch = await session.loupePatch(recipe, visible: wide) {
                    try Task.checkCancellation()
                    state.loupePatch = patch
                    state.loupePatchKey = recipe
                } else if !Task.isCancelled {
                    state.wholeFrameKey = recipe
                }
            } catch {}
        }
        .task(id: LoupeRequest(recipe: renderKey, active: showLoupe && !suspended && !interacting && state.wholeFrameKey == renderKey)) {
            guard showLoupe, !suspended, !interacting, state.wholeFrameKey == renderKey, state.loupeKey != renderKey else { return }
            let recipe = renderKey
            do {
                // Let the regular preview finish first; the loupe is a refinement, never a race.
                try await Task.sleep(for: .milliseconds(350))
                while pending { try await Task.sleep(for: .milliseconds(150)) }
                loupeRefining = true
                defer { loupeRefining = false }
                let frame = try await session.darkroomLoupe(recipe, maximum: Self.loupeMaximum)
                try Task.checkCancellation()
                state.loupeImage = UIImage(cgImage: frame)
                state.loupeKey = recipe
            } catch {
                // Cancelled or over the memory budget: the loupe keeps magnifying the preview.
            }
        }
    }
    private var settledMaximum: Int {
        let thermalCap =
            ProcessInfo.processInfo.thermalState.rawValue
            >= ProcessInfo.ThermalState.serious.rawValue
            ? min(PreviewQuality.editorMaximum, 1080)
            : PreviewQuality.editorMaximum
        let target = viewportLongEdge > 0
            ? Int(ceil(viewportLongEdge * displayScale * 1.15))
            : PreviewQuality.editorMaximum
        return min(thermalCap, max(1080, min(PreviewQuality.editorMaximum, target)))
    }
    private var currentRequest: Request {
        Request(
            recipe: renderKey, suspended: suspended, retry: retry,
            interacting: interacting, settledMaximum: settledMaximum)
    }
    /// Single-in-flight coalescing preview loop: never cancels an active 540 px drag frame, while
    /// cancelling a slow settled pass immediately if the user resumes dragging.
    private func kickEdgeRender() {
        let req = currentRequest
        edgeDesiredRevision &+= 1
        failure = nil
        if !req.recipe.needsDarkroomRender {
            state.edgeImage = nil
            state.edgeImageKey = nil
            state.edgeImageMaximum = 0
        }
        if req.suspended || !req.recipe.needsDarkroomRender {
            edgeRenderTask?.cancel()
            edgeRenderTask = nil
            edgeInFlightSettled = false
            pending = false
            return
        }
        let shown = state.edgeImageKey == req.recipe ? state.edgeImageMaximum : 0
        let targetMax = req.interacting ? 540 : req.settledMaximum
        if edgeRenderTask != nil {
            if edgeInFlightSettled && (req.interacting || state.edgeImageKey != req.recipe) {
                edgeRenderTask?.cancel()
                edgeRenderTask = nil
                edgeInFlightSettled = false
            } else {
                return
            }
        } else if shown >= targetMax {
            pending = false
            return
        }
        startEdgeRenderLoop()
    }
    private func startEdgeRenderLoop() {
        pending = true
        edgeRenderTask = Task {
            while !Task.isCancelled {
                let revision = edgeDesiredRevision
                let req = currentRequest
                guard !req.suspended, req.recipe.needsDarkroomRender else {
                    edgeInFlightSettled = false
                    edgeRenderTask = nil
                    pending = false
                    return
                }
                let shown = state.edgeImageKey == req.recipe ? state.edgeImageMaximum : 0
                let targetMax = req.interacting ? 540 : req.settledMaximum
                guard shown < targetMax else {
                    edgeInFlightSettled = false
                    edgeRenderTask = nil
                    pending = false
                    return
                }
                let nextMax = shown < 540 || req.interacting ? 540 : targetMax
                let use: RenderPrecision.Use = nextMax <= 540 ? .interactive : .output
                edgeInFlightSettled = nextMax > 540
                do {
                    let frame = try await session.filmEdgePreview(req.recipe, maximum: nextMax, use: use)
                    try Task.checkCancellation()
                    state.edgeImage = UIImage(cgImage: frame)
                    state.edgeImageKey = req.recipe
                    state.edgeImageMaximum = nextMax
                } catch is CancellationError {
                    edgeInFlightSettled = false
                    if Task.isCancelled {
                        if edgeDesiredRevision == revision { pending = false }
                        return
                    }
                } catch {
                    edgeInFlightSettled = false
                    if revision != edgeDesiredRevision { continue }
                    failure = error.localizedDescription
                    edgeRenderTask = nil
                    pending = false
                    return
                }
                let done = edgeDesiredRevision == revision
                    && state.edgeImageKey == currentRequest.recipe
                    && state.edgeImageMaximum >= (currentRequest.interacting ? 540 : currentRequest.settledMaximum)
                if done {
                    edgeInFlightSettled = false
                    edgeRenderTask = nil
                    pending = false
                    return
                }
                await Task.yield()
            }
        }
    }
    private struct Request: Equatable {
        let recipe: EditRecipe
        let suspended: Bool
        let retry: Int
        let interacting: Bool
        let settledMaximum: Int
    }
    private struct LoupeRequest: Equatable { let recipe: EditRecipe; let active: Bool }
    private struct PatchRequest: Equatable { let recipe: EditRecipe; let rect: CGRect?; let active: Bool }
}
