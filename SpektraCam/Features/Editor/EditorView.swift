import Combine
import SwiftUI
import UIKit

/// The photograph stays visible while contextual controls edit one shared recipe.
struct EditorView: View {
    let session: EditorSession
    var locationName: String? = nil
    /// The library photo being edited, so a copied look can show where it came from.
    var photoID: UUID? = nil
    let library: PhotoLibrary
    let onFinish: () async throws -> Void
    @State private var closing = false
    @State private var closeFailure: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appAccent) private var accent
    @State private var activeTool: EditorTool? = .develop
    @State private var panelExpanded = false
    @State private var infoExpanded = false
    @State private var inspectorMinY: Int? = nil
    @State private var adjustSection = AdjustPanel.Section.exposure
    @State private var effectsSection = EffectsPanel.Section.grain
    @ScaledMetric(relativeTo: .footnote) private var collapsedLiftGainHeight: CGFloat = 156
    @ScaledMetric(relativeTo: .footnote) private var collapsedColorHeight: CGFloat = 196
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var workspaceHeight: CGFloat = 680
    @State private var showExport = false
    @State private var showDarkroom = false
    @State private var darkroomState = DarkroomWorkspaceState()
    @State private var cropReturnsToDarkroom = false
    @State private var toolBeforeDarkroomCrop: EditorTool?
    @State private var filmCropSession: FilmFrameCropSession?
    @State private var cropUndoGroupOpen = false
    @State private var lastCropEditedRecipe: EditRecipe?
    @State private var showOriginal = false
    @State private var showPasteLook = false
    @State private var showSaveFormula = false
    @State private var formulaImporter = FormulaImportController()
    @State private var showResetConfirmation = false
    @State private var showRenderProgress = false
    @State private var layout = WorkspaceLayout.stacked
    @State private var systemVerticalBar = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Group {
                    if showDarkroom {
                        DarkroomWorkspace(
                            session: session, state: $darkroomState, suspended: showExport,
                            layout: layout, adjustCrop: { openDarkroomCrop(groupingStarted: $0) })
                    } else {
                        editorWorkspace
                    }
                }
                if layout == .sideBySide && !systemVerticalBar {
                    EditorToolRail(
                        activeTool: toolSelection, darkroomActive: showDarkroom,
                        openDarkroom: openDarkroom, export: { showExport = true }
                    )
                    .padding(.horizontal, 8)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if layout == .stacked && !systemVerticalBar {
                EditorBottomBar(
                    activeTool: toolSelection, darkroomActive: showDarkroom,
                    openDarkroom: openDarkroom, export: { showExport = true })
            }
        }
        .onGeometryChange(for: WorkspaceLayout.self) { WorkspaceLayout($0.size) } action: { layout = $0 }
        .ignoresSafeArea(.keyboard)
        .background(PhotoTheme.canvas)
        .onSystemVerticalBar { systemVerticalBar = $0 }
        .background(EditorNavigationGuard().allowsHitTesting(false))
        .formulaImportHost(library: library, controller: $formulaImporter)
        .sheet(isPresented: $showSaveFormula) {
            SaveFormulaSheet(
                library: library, recipe: session.recipe,
                neutralTemperature: session.photo.rawTemperature)
        }
        .sheet(isPresented: $showPasteLook) {
            if let clip = library.copiedLook {
                PasteLookSheet(library: library, clip: clip) { parts in
                    // One history step: the editor's own Undo takes the paste back.
                    session.update(key: "look.paste") {
                        $0 = $0.taking(
                            parts, from: clip.recipe, rawTarget: session.photo.rawTemperature != nil)
                    }
                }
            }
        }
        .navigationTitle(
            showDarkroom
                ? String(localized: "darkroom.title", defaultValue: "Darkroom")
                : activeTool?.title ?? String(localized: "editor.editor", defaultValue: "Editor")
        )
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            // System vertical bars (iPhone Duo) host plain title+symbol items directly;
            // stacked and wide spaces without a system bar use EditorBottomBar / EditorToolRail.
            if systemVerticalBar {
                EditorToolbar(
                    activeTool: toolSelection, darkroomActive: showDarkroom,
                    openDarkroom: openDarkroom, export: { showExport = true })
            }
            AdaptiveToolbarItem(placement: .topBarLeading, background: .hidden) {
                Button(closeTitle, systemImage: "chevron.left", action: finish)
                    .photoActionStyle()
                    .accessibilityLabel(closeTitle)
                    .accessibilityIdentifier(showDarkroom ? "darkroom.back" : "editor.back")
            }
            AdaptiveToolbarItem(placement: .topBarLeading, background: .hidden) {
                WorkspaceHistoryMenu(
                    title: String(localized: "editor.history", defaultValue: "History"),
                    identifier: "editor.history",
                    placement: .navigationBar,
                    sections: historySections
                )
            }
            PhotoWorkspaceCameraToolbar()
        }
        .task(id: session.isBusy) {
            showRenderProgress = false
            guard session.isBusy else { return }
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            if !Task.isCancelled { showRenderProgress = true }
        }
        .disabled(closing)
        .overlay {
            if closing {
                ProgressView(
                    String(localized: "editor.saving_edits", defaultValue: "Saving edits…"))
            }
        }
        .failureAlert(
            String(localized: "editor.couldn_t_save_edits", defaultValue: "Couldn’t save edits"),
            message: $closeFailure)
        .task {
            await library.images.beginEditing(owner: session.id)
            guard !Task.isCancelled else {
                await library.images.endEditing(owner: session.id)
                return
            }
            session.resumeRendering()
        }
        .onDisappear {
            session.cancelRendering()
            Task { await library.images.endEditing(owner: session.id) }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            session.cancelRendering()
            darkroomState.releaseTransientImages(keepEdgePreview: showDarkroom)
        }
        .onChange(of: activeTool) { _, _ in
            showOriginal = false
            panelExpanded = false
        }
        .onChange(of: session.recipe) { _, updated in
            syncFilmCropSessionIfNeeded(updated)
        }
        .alert(
            String(localized: "editor.reset_all_edits_confirm", defaultValue: "Reset all edits?"),
            isPresented: $showResetConfirmation
        ) {
            Button(
                String(localized: "editor.reset_all_edits", defaultValue: "Reset All Edits"),
                role: .destructive
            ) {
                session.resetAll()
            }
        }
        .sheet(isPresented: $showExport, onDismiss: { session.resumeAfterExport() }) {
            ExportPanel(session: session)
        }
        .alert(
            String(
                localized: "editor.couldn_t_render_preview", defaultValue: "Couldn’t render preview"
            ),
            isPresented: Binding(get: { session.renderFailed }, set: { session.renderFailed = $0 })
        ) {
            Button(
                String(localized: "common.retry", defaultValue: "Retry"),
                action: session.renderGeometry)
            Button(
                String(localized: "editor.reset_rotation", defaultValue: "Reset Rotation"),
                role: .cancel
            ) {
                session.update(key: "geometry.reset") { $0.geometry = ImageGeometry() }
            }
        }
    }
    private var closeTitle: String {
        String(localized: "darkroom.back_to_photo", defaultValue: "Back to photo")
    }
    private var compareTitle: String {
        showOriginal
            ? String(localized: "editor.show_edited", defaultValue: "Show Edited")
            : String(localized: "editor.show_original", defaultValue: "Show Original")
    }
    private var historySections: [[WorkspaceHistoryItem]] {
        var resetItems: [WorkspaceHistoryItem] = []
        if showDarkroom {
            resetItems.append(
                WorkspaceHistoryItem(
                    title: String(
                        localized: "darkroom.reset_edits",
                        defaultValue: "Reset Darkroom Edits"),
                    identifier: "darkroom.reset",
                    isEnabled: session.hasDarkroomEdits,
                    action: session.resetDarkroom
                ))
        }
        resetItems.append(
            WorkspaceHistoryItem(
                title: String(
                    localized: "editor.reset_all_edits",
                    defaultValue: "Reset All Edits"),
                isEnabled: session.hasEdits,
                isDestructive: true
            ) { showResetConfirmation = true })
        return [
            [
                WorkspaceHistoryItem(
                    title: String(localized: "editor.undo", defaultValue: "Undo"),
                    systemImage: "arrow.uturn.backward",
                    isEnabled: session.canUndo,
                    action: session.undo
                ),
                WorkspaceHistoryItem(
                    title: String(localized: "editor.redo", defaultValue: "Redo"),
                    systemImage: "arrow.uturn.forward",
                    isEnabled: session.canRedo,
                    action: session.redo
                ),
            ],
            resetItems,
        ]
    }
    private var transitionAnimation: Animation? {
        reduceMotion ? nil : .snappy(duration: 0.22)
    }
    private func dismissActiveInput() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
    /// Choosing a tool leaves Darkroom; choosing Crop from a film edge returns there afterwards.
    private var toolSelection: Binding<EditorTool?> {
        Binding(
            get: { showDarkroom ? nil : activeTool },
            set: { tool in
                dismissActiveInput()
                withAnimation(transitionAnimation) {
                    if activeTool == .crop && tool != .crop {
                        endCropEditingIfNeeded()
                    }
                    cropReturnsToDarkroom = tool == .crop && showDarkroom && session.recipe.filmEdgeLayout != nil
                    if cropReturnsToDarkroom { toolBeforeDarkroomCrop = activeTool }
                    if tool == .crop && (activeTool != .crop || showDarkroom) {
                        beginCropEditing(groupingAlreadyStarted: false)
                    }
                    if activeTool != tool {
                        showOriginal = false
                        panelExpanded = false
                    }
                    activeTool = tool
                    showDarkroom = false
                }
            })
    }
    private func openDarkroom() {
        dismissActiveInput()
        withAnimation(transitionAnimation) {
            endCropEditingIfNeeded()
            panelExpanded = false
            cropReturnsToDarkroom = false
            showDarkroom = true
        }
    }
    @ViewBuilder private var editorWorkspace: some View {
        if layout == .sideBySide { sideBySideWorkspace } else { stackedWorkspace }
    }
    /// The photo keeps the leading side; the open tool's controls fill a column beside it.
    private var sideBySideWorkspace: some View {
        GeometryReader { workspace in
            HStack(spacing: 0) {
                canvas
                    .overlay(alignment: .top) {
                        if activeTool != .crop {
                            editorInfoOverlay(
                                maxHeight: max(
                                    200,
                                    workspace.size.height - PhotoInfoPanel.collapsedHeight - 24
                                ))
                        }
                    }
                if activeTool == .crop {
                    toolPanel
                        .padding(.top, 12)
                        .frame(maxHeight: .infinity)
                        .clipShape(.rect(cornerRadius: 24))
                        .adaptiveGlassRect(cornerRadius: 24)
                        .frame(width: WorkspaceLayout.panelWidth(in: workspace.size.width))
                        .padding(.leading, 8).padding(.vertical, 8)
                } else if activeTool != nil {
                    inspector(height: nil)
                        .frame(width: WorkspaceLayout.panelWidth(in: workspace.size.width))
                        .padding(.leading, 8).padding(.vertical, 8)
                }
            }
        }
    }
    private var stackedWorkspace: some View {
        VStack(spacing: 0) {
            GeometryReader { workspace in
                canvas
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        if height > 0 { workspaceHeight = height }
                    }
                    .overlay(alignment: .bottom) {
                        if activeTool != nil && activeTool != .crop {
                            let maximum = maximumPanelHeight(in: workspace.size.height)
                            inspector(height: panelExpanded ? maximum : min(maximum, collapsedPanelHeight))
                                .padding(.horizontal, 12).padding(.bottom, 6)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                                .onGeometryChange(for: Int?.self) {
                                    let frame = $0.frame(in: .global)
                                    return frame.width > 0 ? Int(frame.minY.rounded()) : nil
                                } action: {
                                    inspectorMinY = $0
                                }
                        }
                    }
                    .overlay(alignment: .top) {
                        if activeTool != .crop {
                            editorInfoOverlay(
                                maxHeight: max(
                                    200,
                                    workspace.size.height - PhotoInfoPanel.collapsedHeight - 20
                                ))
                        }
                    }
            }
            if activeTool == .crop { toolPanel }
        }
    }
    private func editorInfoOverlay(maxHeight: CGFloat) -> some View {
        EditorInfoBar(
            session: session, showingOriginal: showOriginal, location: locationName,
            onInteraction: { if panelExpanded { setExpanded(false) } },
            onExpandedChange: { expanded in
                infoExpanded = expanded
                if expanded && panelExpanded { setExpanded(false) }
            },
            maxExpandedHeight: maxHeight,
            look: LookActions(
                canCopy: session.hasEdits, canPaste: library.copiedLook != nil,
                copy: { library.copyLook(session.recipe, from: photoID) },
                paste: { showPasteLook = true }),
            formulae: FormulaStrip(
                library: library, canSave: session.hasEdits, identifier: "editor",
                importer: $formulaImporter,
                apply: { formula in
                    session.update(key: "formula.apply") {
                        $0 = formula.applied(
                            to: $0, rawTarget: session.photo.rawTemperature != nil)
                    }
                },
                save: { showSaveFormula = true })
        )
        .frame(maxWidth: layout == .sideBySide ? 680 : .infinity)
        .padding(.horizontal, 12).padding(.top, 4)
    }
    private func finish() {
        guard !closing else { return }
        dismissActiveInput()
        endCropEditingIfNeeded()
        closing = true
        Task {
            do {
                try await onFinish()
                dismiss()
            } catch { closeFailure = error.localizedDescription }
            closing = false
        }
    }
    private var darkroomGateIndicatorRect: CGRect? {
        guard let layout = session.recipe.renderedFilmEdgeLayout else { return nil }
        let upright = session.recipe.geometry.quarterTurns % 2 == 0
            ? CGSize(width: session.photo.width, height: session.photo.height)
            : CGSize(width: session.photo.height, height: session.photo.width)
        let support = layout.sourceSupport(for: session.recipe.crop, imageSize: upright)
        return support.coverScale > 1.0005 ? support.visibleCropRect : nil
    }
    private func beginCropEditing(groupingAlreadyStarted: Bool = false) {
        if session.recipe.filmEdgeLayout != nil {
            if !groupingAlreadyStarted && !cropUndoGroupOpen {
                session.beginUndoGroup()
                cropUndoGroupOpen = true
            } else if groupingAlreadyStarted {
                cropUndoGroupOpen = true
            }
            if let preGate = session.preFilmEdgeCrop {
                filmCropSession = FilmFrameCropSession(baseCrop: preGate, isPreGateBase: true)
            } else {
                filmCropSession = FilmFrameCropSession(baseCrop: session.recipe.crop, isPreGateBase: false)
            }
            lastCropEditedRecipe = session.recipe
        } else {
            filmCropSession = nil
            lastCropEditedRecipe = nil
        }
    }
    private func endCropEditingIfNeeded() {
        if cropUndoGroupOpen {
            session.endUndoGroup()
            cropUndoGroupOpen = false
        }
        filmCropSession = nil
        lastCropEditedRecipe = nil
    }
    private func syncFilmCropSessionIfNeeded(_ updated: EditRecipe) {
        guard activeTool == .crop, updated != lastCropEditedRecipe else { return }
        lastCropEditedRecipe = updated
        if updated.filmEdgeLayout != nil {
            if let preGate = session.preFilmEdgeCrop {
                filmCropSession = FilmFrameCropSession(baseCrop: preGate, isPreGateBase: true)
            } else {
                filmCropSession = FilmFrameCropSession(baseCrop: updated.crop, isPreGateBase: false)
            }
        } else {
            filmCropSession = nil
        }
    }
    private var filmCropSelectionBinding: Binding<CropSelection> {
        Binding(
            get: { session.recipe.crop },
            set: { next in
                filmCropSession?.recordManualCrop(next)
                session.recordManualCrop(next)
                session.update(key: "crop") { $0.crop = next }
                lastCropEditedRecipe = session.recipe
            })
    }
    private func selectFilmFrame(_ choice: FilmEdgeLayout.FrameChoice) {
        guard var edge = session.recipe.filmEdgeLayout else { return }
        edge.setFrameChoice(choice)
        let size = session.uprightSize
        if filmCropSession == nil {
            if let preGate = session.preFilmEdgeCrop {
                filmCropSession = FilmFrameCropSession(baseCrop: preGate, isPreGateBase: true)
            } else {
                filmCropSession = FilmFrameCropSession(baseCrop: session.recipe.crop, isPreGateBase: false)
            }
        }
        let nextCrop = filmCropSession?.crop(for: edge, imageSize: size)
            ?? edge.constrainedCrop(session.recipe.crop, imageSize: size)
        session.applyFilmFrameInCrop(edge, crop: nextCrop)
        lastCropEditedRecipe = session.recipe
    }
    private func setFilmOrientation(_ orientation: CropOrientation) {
        guard let edge = session.recipe.filmEdgeLayout else { return }
        let size = session.uprightSize
        let nextCrop: CropSelection
        if var cropSession = filmCropSession {
            nextCrop = cropSession.setOrientation(
                orientation, currentCrop: session.recipe.crop,
                layout: edge, imageSize: size)
            filmCropSession = cropSession
            if cropSession.hasManualAdjustment {
                session.recordManualCrop(nextCrop)
            }
        } else {
            var updated = session.recipe.crop
            updated.aspect = edge.cropAspect
            updated.setOrientation(orientation, imageAspect: size.width / size.height)
            nextCrop = edge.constrainedCrop(updated, imageSize: size)
        }
        session.update(key: "crop") { $0.crop = nextCrop }
        lastCropEditedRecipe = session.recipe
    }
    private func resetCropSelection() {
        let size = session.uprightSize
        if let edge = session.recipe.filmEdgeLayout {
            var cropSession = filmCropSession ?? FilmFrameCropSession(baseCrop: CropSelection(), isPreGateBase: true)
            let resetCrop = cropSession.reset(layout: edge, imageSize: size)
            filmCropSession = cropSession
            session.resetFilmCrop(to: resetCrop)
        } else {
            session.update(key: "crop.reset") {
                $0.crop = CropSelection()
                $0.geometry = ImageGeometry()
            }
        }
        lastCropEditedRecipe = session.recipe
    }
    private var canResetCrop: Bool {
        let defaultCrop = session.recipe.filmEdgeLayout?.constrainedCrop(CropSelection(), imageSize: session.uprightSize)
            ?? CropSelection()
        return session.recipe.crop != defaultCrop || !session.recipe.geometry.isIdentity
    }
    private func openDarkroomCrop(groupingStarted: Bool) {
        dismissActiveInput()
        withAnimation(transitionAnimation) {
            panelExpanded = false
            toolBeforeDarkroomCrop = activeTool
            cropReturnsToDarkroom = true
            beginCropEditing(groupingAlreadyStarted: groupingStarted)
            activeTool = .crop
            showDarkroom = false
        }
    }
    private func finishDarkroomCrop() {
        dismissActiveInput()
        withAnimation(transitionAnimation) {
            endCropEditingIfNeeded()
            activeTool = toolBeforeDarkroomCrop
            cropReturnsToDarkroom = false
            showDarkroom = true
        }
    }
    private var zoomedInspectorReserve: CGFloat {
        guard layout == .stacked, activeTool != nil, activeTool != .crop else { return 0 }
        let maximum = maximumPanelHeight(in: workspaceHeight)
        let card = panelExpanded ? maximum : min(maximum, collapsedPanelHeight)
        return card + 54
    }
    private var canvas: some View {
        ZStack {
            if activeTool == .crop {
                CropCanvas(
                    image: session.geometryImage, selection: filmCropSelectionBinding,
                    geometry: session.binding(\.geometry, key: "crop.framing"),
                    filmGateNormalizedRect: darkroomGateIndicatorRect
                )
                .allowsHitTesting(!session.isRendering)
            } else {
                PhotoViewport(
                    image: showOriginal
                        ? UIImage(cgImage: session.photo.preview) : session.displayImage,
                    zoomedBottomInset: zoomedInspectorReserve,
                    // Beside its controls the photo has the full height, so it sits in the middle.
                    topAligned: layout == .stacked,
                    onTap: { point in
                        if panelExpanded, let minY = inspectorMinY, point.y < CGFloat(minY) - 44 {
                            setExpanded(false)
                        }
                    },
                    detail: showOriginal ? nil : session.detailProvider
                )
                .overlay(alignment: .topTrailing) {
                    Button(compareTitle, systemImage: "square.on.square") {
                        showOriginal.toggle()
                        if panelExpanded { setExpanded(false) }
                    }
                    .accessibilityAddTraits(showOriginal ? .isSelected : [])
                    .photoActionStyle(selected: showOriginal)
                    .accessibilityLabel(compareTitle)
                    .accessibilityIdentifier("editor.compare")
                    .padding(.top, 4 + PhotoInfoPanel.collapsedHeight + 8)
                    .padding(.trailing, 12)
                    .opacity(infoExpanded ? 0 : 1)
                    .allowsHitTesting(!infoExpanded)
                    .accessibilityHidden(infoExpanded)
                }
            }
            if showRenderProgress {
                ProgressView().accessibilityLabel(
                    String(localized: "editor.rendering_preview", defaultValue: "Rendering preview")
                )
            }
            if session.filmRenderFailed {
                VStack {
                    Spacer()
                    HStack {
                        Label(
                            String(
                                localized: "editor.couldn_t_update_preview",
                                defaultValue: "Couldn’t update preview"),
                            systemImage: "exclamationmark.triangle")
                        Button(
                            String(localized: "common.retry", defaultValue: "Retry"),
                            action: session.renderFilm)
                    }
                    .font(.footnote).padding(12)
                    .background(.regularMaterial, in: .capsule)
                }.padding()
            }
        }
        .background(PhotoTheme.canvas)
    }

    @ViewBuilder private var toolPanel: some View {
        switch activeTool {
        case .crop:
            CropControls(
                crop: filmCropSelectionBinding,
                geometry: session.binding(\.geometry, key: "straighten"),
                imageAspect: imageAspect,
                filmGate: session.recipe.filmEdgeLayout,
                rotateLeft: {
                    let aspect = imageAspect
                    session.update(key: "rotate") {
                        $0.crop.rotateLeft(imageAspect: aspect)
                        $0.geometry.rotateLeft()
                    }
                    filmCropSession?.rotateLeft(imageAspect: aspect)
                    lastCropEditedRecipe = session.recipe
                },
                flipHorizontal: {
                    session.update(key: "flip") {
                        $0.crop.flipHorizontal()
                        $0.geometry.flipHorizontal()
                    }
                    filmCropSession?.flipHorizontal()
                    lastCropEditedRecipe = session.recipe
                },
                flipVertical: {
                    session.update(key: "flip") {
                        $0.crop.flipVertical()
                        $0.geometry.flipVertical()
                    }
                    filmCropSession?.flipVertical()
                    lastCropEditedRecipe = session.recipe
                },
                reset: resetCropSelection,
                done: {
                    if cropReturnsToDarkroom {
                        finishDarkroomCrop()
                    } else {
                        withAnimation(transitionAnimation) {
                            endCropEditingIfNeeded()
                            activeTool = nil
                        }
                    }
                },
                canReset: canResetCrop,
                showsBackground: layout == .stacked,
                onSelectFilmFrame: selectFilmFrame,
                onSetFilmOrientation: setFilmOrientation,
                onStraightenEditingChanged: {
                    session.setInteraction(key: "straighten", active: $0)
                })
        case .develop:
            if session.recipe.look.mode == .spektrafilm {
                DevelopPanel(session: session)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .disabled(!session.recipe.look.enabled)
                    .transition(.opacity)
            } else {
                LUTPanel(session: session, library: library)
                    .transition(.opacity)
            }
        case .adjust:
            scrollingPanel(id: adjustSection.rawValue) {
                AdjustPanel(session: session, section: adjustSection)
            }
            .transition(.opacity)
        case .effects:
            scrollingPanel(id: effectsSection.rawValue) {
                EffectsPanel(session: session, section: effectsSection)
                    .disabled(!session.recipe.look.enabled)
            }
            .transition(.opacity)
        case nil: EmptyView()
        }
    }
    /// A new section starts scrolled to the top: its identity changes with the section.
    private func scrollingPanel(id: String, @ViewBuilder content: () -> some View) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10, content: content)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
        .id(id).accessibilityIdentifier("editor.controls")
    }

    private func maximumPanelHeight(in height: CGFloat) -> CGFloat {
        max(120, height - PhotoInfoPanel.collapsedHeight - 4 - 44 - 50 - 8)
    }

    // Collapsed content heights, in points. The category buttons sit above this area.
    private var collapsedPanelHeight: CGFloat {
        switch (activeTool, adjustSection) {
        case (.develop, _): 228
        case (.adjust, .liftGain): collapsedLiftGainHeight
        case (.adjust, .color): collapsedColorHeight
        default: 184
        }
    }

    private func setExpanded(_ expanded: Bool) {
        withAnimation(transitionAnimation) { panelExpanded = expanded }
    }
    /// `height` is nil when the panel fills its column and has nothing to expand into.
    private func inspector(height: CGFloat?) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Group {
                    switch activeTool {
                    case .develop:
                        PanelTabs(
                            options: EditRecipe.LookMode.allCases.map { ($0, $0.title) },
                            selection: Binding(
                                get: { session.recipe.look.mode },
                                set: { mode in
                                    withAnimation(transitionAnimation) {
                                        session.update(key: "look.mode") {
                                            $0.look.mode = mode
                                            $0.look.enabled = true
                                        }
                                    }
                                }),
                            prefix: "develop.mode.", isSelectionActive: session.recipe.look.enabled)
                        .transition(.opacity)
                    case .adjust:
                        PanelTabs(
                            options: AdjustPanel.Section.allCases.map { ($0, $0.title) },
                            selection: $adjustSection.animation(transitionAnimation),
                            prefix: "adjust.section.")
                        .transition(.opacity)
                    case .effects:
                        PanelTabs(
                            options: EffectsPanel.Section.allCases.map { ($0, $0.title) },
                            selection: $effectsSection.animation(transitionAnimation),
                            prefix: "effects.section.")
                        .transition(.opacity)
                    case .crop, nil: Spacer()
                    }
                }
                if height != nil {
                    PanelExpansionButton(expanded: $panelExpanded, identifier: "editor.expand")
                }
            }
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            toolPanel.font(.footnote)
                .frame(maxWidth: .infinity, maxHeight: height == nil ? .infinity : nil, alignment: .top)
                .frame(height: height, alignment: .top)
                .clipped()
                .adaptiveGlassRect(cornerRadius: 22)
        }
    }

    private var imageAspect: CGFloat {
        let source = session.photo.preview
        let aspect = CGFloat(source.width) / CGFloat(source.height)
        return session.recipe.geometry.quarterTurns % 2 == 0 ? aspect : 1 / aspect
    }

}

/// Scope UIKit's two public pop recognizers to this editor; restore on exit.
private struct EditorNavigationGuard: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) { controller.lock() }

    final class Controller: UIViewController {
        private var saved: [(UIGestureRecognizer, Bool)] = []

        override func loadView() {
            let view = UIView()
            view.isUserInteractionEnabled = false
            self.view = view
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            lock()
        }

        override func viewWillDisappear(_ animated: Bool) {
            saved.forEach { $0.0.isEnabled = $0.1 }
            saved.removeAll()
            super.viewWillDisappear(animated)
        }

        func lock() {
            guard let navigationController else { return }
            var recognizers = [navigationController.interactivePopGestureRecognizer]
            if #available(iOS 26.0, *) {
                recognizers.append(navigationController.interactiveContentPopGestureRecognizer)
            }
            for recognizer in recognizers.compactMap({ $0 }) {
                if !saved.contains(where: { $0.0 === recognizer }) {
                    saved.append((recognizer, recognizer.isEnabled))
                }
                if recognizer.isEnabled { recognizer.isEnabled = false }
            }
        }
    }
}
