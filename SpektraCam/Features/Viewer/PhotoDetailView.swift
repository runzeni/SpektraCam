import CoreLocation
import MapKit
import SwiftUI

/// Browse the album without loading full-resolution data for each thumbnail.
struct PhotoDetailView: View {
    @AppStorage(PreviewQuality.libraryKey) private var previewMaximum = PreviewQuality.defaultMaximum
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let library: PhotoLibrary
    let filter: LibraryFilter
    var isPresentingEditor = false
    var openEditor: (EditorSession, UUID, String?) -> Void = { _, _, _ in }
    @State private var selectedID: UUID
    @State private var sourceLens: String?
    private var displayMetadata: PhotoMetadata {
        var result = photo?.metadata ?? PhotoMetadata()
        if result.lens == nil { result.lens = sourceLens }
        return result
    }
    @State private var histogram = PhotoHistogram.empty
    @State private var image: UIImage?
    @State private var imageIdentity: String?
    @State private var rawTemperature: Double?
    @State private var export: ExportRequest?
    @State private var working = false
    @State private var failure: String?
    @State private var layout = WorkspaceLayout.stacked
    @State private var viewportSize = CGSize(width: 393, height: 800)
    @State private var systemVerticalBar = false
    @State private var confirmDelete = false
    @State private var confirmSystemDelete = false
    @State private var showPasteLook = false
    @State private var showSaveFormula = false
    @State private var formulaImporter = FormulaImportController()
    private struct ExportRequest: Identifiable {
        let id = UUID()
        let session: EditorSession?
        let originalURL: URL
        let sourceFilename: String
    }
    private var photo: LibraryPhoto? { library.photo(selectedID) }
    private var photos: [LibraryPhoto] { library.filteredPhotos(filter) }
    private var viewerBottomInset: CGFloat {
        (systemVerticalBar || layout == .sideBySide) ? 80 : 124
    }
    private var deleteMessage: String {
        library.applePhotosIDs.contains(selectedID)
            ? String(
                localized: "photo.delete_message",
                defaultValue:
                    "This moves the app copy and its edits to Recently Deleted for 30 days. Your source photo in Apple Photos stays unchanged.")
            : String(
                localized: "photo.delete_app_only_message",
                defaultValue:
                    "This moves the photo and its edits to Recently Deleted for 30 days before permanent removal from SpektraCam.")
    }
    private var usesPortraitReference: Bool {
        layout == .stacked && !systemVerticalBar
    }

    init(
        library: PhotoLibrary, id: UUID, filter: LibraryFilter = .all,
        isPresentingEditor: Bool = false,
        openEditor: @escaping (EditorSession, UUID, String?) -> Void = { _, _, _ in }
    ) {
        self.library = library
        self.filter = filter
        self.isPresentingEditor = isPresentingEditor
        self.openEditor = openEditor
        _selectedID = State(initialValue: id)
    }
    var body: some View {
        ZStack {
            AlbumPager(
                photos: photos, images: library.images, selection: $selectedID,
                bottomInset: viewerBottomInset, usePortraitReference: usesPortraitReference)
            if working { ProgressView().padding().background(.regularMaterial, in: .capsule) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PhotoTheme.canvas)
        .overlay(alignment: .bottom) {
            PhotoViewerControls(
                photos: photos, images: library.images, selection: $selectedID,
                working: working, develop: { prepareEditor(exporting: false) },
                export: { prepareEditor(exporting: true) }, revert: revertPhoto,
                canRevert: photo?.hasEdits == true,
                confirmDelete: $confirmDelete,
                deleteMessage: deleteMessage,
                performDelete: deletePhoto,
                layout: layout,
                showsActions: !systemVerticalBar
            )
            .padding(.horizontal, 16).padding(.bottom, 2)
        }
        .onSystemVerticalBar { vertical in
            systemVerticalBar = vertical
            if vertical { confirmDelete = false }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            layout = WorkspaceLayout(size)
            viewportSize = size
        }
        .overlay(alignment: .top) {
            if let photo {
                let recipe = savedRecipe
                let titles = EditRecipe.infoTitles(
                    recipe, luts: library.luts, isRAW: photo.isRAW,
                    formatLabel: photo.metadata.formatLabel)
                PhotoInfoPanel(
                    title: titles.title, subtitle: titles.subtitle, metadata: displayMetadata,
                    location: photo.locationName, histogram: histogram, identifier: "photo",
                    maxExpandedHeight: max(
                        200,
                        viewportSize.height - PhotoInfoPanel.collapsedHeight - 76
                    ),
                    look: LookActions(
                        canCopy: photo.hasEdits && !working,
                        canPaste: library.copiedLook != nil && !working,
                        canUndo: library.pasteUndo?.contains(photo.id) == true && !working,
                        copy: {
                            do { try library.copyLook(from: photo.id) } catch {
                                failure = error.localizedDescription
                            }
                        },
                        paste: { showPasteLook = true }, undo: undoPaste),
                    formulae: FormulaStrip(
                        library: library, photo: photo, canSave: photo.hasEdits && !working,
                        canImport: !working, identifier: "photo", importer: $formulaImporter,
                        apply: applyFormula, save: { showSaveFormula = true })
                )
                .frame(maxWidth: layout == .sideBySide ? 680 : .infinity)
                .padding(.horizontal, 12).padding(.top, 4)
            }
        }
        .navigationTitle(String(localized: "photo.photo", defaultValue: "Photo"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarRole(.navigationStack)
        .toolbar {
            ToolbarItem(placement: .principal) {
                if let photo { PhotoBanner(photo: photo) }
            }
            PhotoWorkspaceCameraToolbar()
            // Where the system keeps a bar on the side, the actions live in it.
            if systemVerticalBar { sideBarActions }
        }
        .formulaImportHost(library: library, controller: $formulaImporter)
        .confirmationDialog(
            String(localized: "photo.delete_confirm", defaultValue: "Delete Photo?"),
            isPresented: $confirmSystemDelete, titleVisibility: .visible
        ) {
            Button(
                String(localized: "photo.delete_app_copy", defaultValue: "Delete App Copy"),
                role: .destructive, action: deletePhoto)
        } message: {
            Text(deleteMessage)
        }
        .task(id: "\(selectedID)-\(photo?.renderKey ?? "")-\(previewMaximum)") {
            await loadPreview()
        }
        .task(id: selectedID) {
            sourceLens = nil
            if let photo {
                let lens = await library.files.lensName(photo)
                guard !Task.isCancelled, photo.id == selectedID else { return }
                sourceLens = lens
            }
            await resolveLocation()
        }
        .onChange(of: selectedID) { _, _ in
            confirmDelete = false
            image = nil
            histogram = .empty
            rawTemperature = nil
        }
        .onDisappear {
            if !isPresentingEditor && export == nil {
                Task { await library.files.discardPreparedPhoto() }
            }
        }
        .sheet(item: $export) { request in
            if let session = request.session {
                ExportPanel(session: session)
            } else {
                ExportPanel(originalURL: request.originalURL, sourceFilename: request.sourceFilename)
            }
        }
        .sheet(isPresented: $showPasteLook) {
            if let clip = library.copiedLook {
                PasteLookSheet(library: library, clip: clip, paste: pasteLook)
            }
        }
        .sheet(isPresented: $showSaveFormula) {
            if let recipe = savedRecipe {
                SaveFormulaSheet(library: library, recipe: recipe, neutralTemperature: rawTemperature)
            }
        }
        .failureAlert(String(localized: "photo.photo", defaultValue: "Photo"), message: $failure)
    }
    private func pasteLook(_ parts: Set<EditRecipe.Part>) {
        let id = selectedID
        working = true
        Task {
            defer { working = false }
            do {
                if try await library.pasteLook(parts, to: [id]).skipped > 0 {
                    failure = String(
                        localized: "look.paste.skipped",
                        defaultValue: "Photos edited with an older film model were skipped.")
                }
            } catch { failure = error.localizedDescription }
        }
    }
    private func applyFormula(_ formula: Formula) {
        let id = selectedID
        guard !working else { return }
        working = true
        Task {
            defer { working = false }
            do {
                if try await library.applyFormula(formula, to: [id]).skipped > 0 {
                    failure = String(
                        localized: "look.paste.skipped",
                        defaultValue: "Photos edited with an older film model were skipped.")
                }
            } catch { failure = error.localizedDescription }
        }
    }
    private func undoPaste() {
        working = true
        Task {
            defer { working = false }
            do { try await library.undoPaste() } catch { failure = error.localizedDescription }
        }
    }
    @ToolbarContentBuilder private var sideBarActions: some ToolbarContent {
        ToolbarItem(placement: .bottomBar) {
            Button(String(localized: "editor.develop", defaultValue: "Develop"), systemImage: "camera.filters") {
                prepareEditor(exporting: false)
            }
            .tint(Color.accentColor).disabled(working).accessibilityIdentifier("photo.develop")
        }
        AdaptiveToolbarSpacer(.fixed, placement: .bottomBar)
        ToolbarItemGroup(placement: .bottomBar) {
            Button(String(localized: "common.export", defaultValue: "Export"), systemImage: "square.and.arrow.up") {
                prepareEditor(exporting: true)
            }
            .disabled(working).accessibilityIdentifier("photo.export")
            PhotoRevertMenu(
                canRevert: !working && photo?.hasEdits == true,
                inSystemToolbar: true,
                action: revertPhoto
            )
            Button(String(localized: "common.delete", defaultValue: "Delete"), systemImage: "trash", role: .destructive) {
                confirmSystemDelete = true
            }
            .disabled(working).accessibilityIdentifier("photo.delete")
        }
    }
    private var savedRecipe: EditRecipe? {
        photo?.recipeData.flatMap { try? JSONDecoder().decode(EditRecipe.self, from: $0) }
    }
    private func loadPreview() async {
        guard let photo else { return }
        do {
            let frame = try await library.images.image(photo, thumbnail: false)
            try Task.checkCancellation()
            image = UIImage(cgImage: frame)
            imageIdentity = "\(photo.id)-\(photo.renderKey)"
            let stats = await HistogramWorker.shared.make(frame)
            if !Task.isCancelled { histogram = stats }
            // The precise viewer is already visible. Prepare one neutral source after
            // a short pause; fast paging cancels this before another RAW decode starts.
            if photo.hasEdits {
                try await Task.sleep(for: .milliseconds(150))
                if let decoded = try? await library.files.decodedPhoto(photo),
                    !Task.isCancelled, photo.id == selectedID
                {
                    rawTemperature = decoded.rawTemperature
                }
            }
        } catch { if !Task.isCancelled { histogram = .empty } }
    }
    private func revertPhoto() {
        working = true
        Task {
            defer { working = false }
            do { try await library.revert([selectedID]) } catch {
                failure = error.localizedDescription
            }
        }
    }
    private func deletePhoto() {
        guard !working else { return }
        let id = selectedID
        let album = photos.map(\.id)
        let index = album.firstIndex(of: id) ?? 0
        let next = album.dropFirst(index + 1).first ?? album.prefix(index).last
        working = true
        Task {
            defer { working = false }
            do {
                try await library.delete([id])
                if let next { selectedID = next } else { dismiss() }
            } catch { failure = error.localizedDescription }
        }
    }
    private func prepareEditor(exporting: Bool) {
        guard !working, let photo else { return }
        do {
            let recipe = try library.recipe(photo.id)
            if exporting && recipe == nil {
                export = ExportRequest(session: nil, originalURL: library.files.sourceURL(photo), sourceFilename: photo.filename)
                return
            }
            if let recipe, recipe.upstreamRevision != EditRecipe().upstreamRevision {
                throw LibraryFiles.Failure.image
            }
            working = true
            Task {
                do {
                    let neutral = !photo.hasEdits && imageIdentity == "\(photo.id)-\(photo.renderKey)"
                        ? image?.cgImage : nil
                    let imported = try await library.files.decodedPhoto(photo, neutralPreview: neutral)
                    guard selectedID == photo.id else {
                        working = false
                        return
                    }
                    rawTemperature = imported.rawTemperature
                    let session = EditorSession(
                        photo: imported, recipe: recipe, luts: library.luts,
                        resources: library.images.resources, sourceFilename: photo.filename)
                    if let image, photo.hasEdits, recipe?.filmEdgeLayout == nil, recipe?.printLayout == nil,
                        recipe?.activeCleanPrintDistress == nil {
                        session.displayImage = image
                    }
                    if exporting {
                        working = false
                        export = ExportRequest(
                            session: session, originalURL: library.files.sourceURL(photo), sourceFilename: photo.filename)
                    } else {
                        session.recipeDidChange = { recipe, immediate in
                            library.queueRecipe(recipe, for: photo.id, immediate: immediate)
                        }
                        working = false
                        openEditor(session, photo.id, photo.locationName)
                    }
                } catch {
                    working = false
                    failure = error.localizedDescription
                }
            }
        } catch { failure = error.localizedDescription }
    }
    private func resolveLocation() async {
        guard let photo, photo.locationName == nil,
            let latitude = photo.metadata.latitude, let longitude = photo.metadata.longitude
        else { return }
        let coordinate = CLLocation(latitude: latitude, longitude: longitude)
        do {
            if #available(iOS 26.0, *) {
                guard let request = MKReverseGeocodingRequest(location: coordinate) else { return }
                let items = try await withTaskCancellationHandler {
                    try await request.mapItems
                } onCancel: {
                    request.cancel()
                }
                try Task.checkCancellation()
                if let item = items.first,
                    let name = item.addressRepresentations?.cityWithContext ?? item.name
                {
                    try library.setLocationName(name, for: photo.id)
                }
            } else {
                let geocoder = CLGeocoder()
                let placemarks = try await withTaskCancellationHandler {
                    try await geocoder.reverseGeocodeLocation(coordinate)
                } onCancel: {
                    geocoder.cancelGeocode()
                }
                try Task.checkCancellation()
                if let placemark = placemarks.first {
                    let parts = [
                        placemark.locality,
                        placemark.administrativeArea ?? placemark.country,
                    ].compactMap { $0 }.filter { !$0.isEmpty }
                    let name = parts.isEmpty ? placemark.name : parts.joined(separator: ", ")
                    if let name, !name.isEmpty {
                        try library.setLocationName(name, for: photo.id)
                    }
                }
            }
        } catch { /* Keep the capture date when the optional lookup is unavailable. */  }
    }
}

/// Capture details stay visible without opening the information panel.
private struct PhotoBanner: View {
    let photo: LibraryPhoto
    private var title: String {
        photo.locationName ?? photo.date.formatted(date: .long, time: .omitted)
    }
    private var detail: String {
        photo.date.formatted(
            date: photo.locationName == nil ? .omitted : .abbreviated, time: .shortened)
    }
    var body: some View {
        VStack(spacing: 2) {
            Text(title).font(.subheadline.weight(.semibold)).accessibilityIdentifier(
                "photo.banner.title")
            HStack(spacing: 5) {
                Text(detail).font(.caption2).foregroundStyle(.secondary).accessibilityIdentifier(
                    "photo.banner.date")
                if photo.isRAW { PhotoBadge(text: "RAW", compact: true) }
                if photo.hasEdits { PhotoBadge(symbol: PhotoBadge.editedSymbol, compact: true) }
            }
        }.lineLimit(1).dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }
}

/// Controls float over the image. Native popovers anchor to their source button.
private struct PhotoViewerControls: View {
    let photos: [LibraryPhoto]
    let images: LibraryImages
    @Binding var selection: UUID
    let working: Bool
    let develop: () -> Void
    let export: () -> Void
    let revert: () -> Void
    let canRevert: Bool
    @Binding var confirmDelete: Bool
    let deleteMessage: String
    let performDelete: () -> Void
    var layout = WorkspaceLayout.stacked
    /// False where the system's side bar already carries the actions.
    var showsActions = true
    var body: some View {
        if !showsActions {
            PhotoFilmstrip(photos: photos, images: images, selection: $selection).disabled(working)
        } else if layout == .sideBySide {
            sideBySide
        } else {
            stacked
        }
    }
    /// With width to spare, the actions run down the trailing edge and leave the photo its height.
    private var sideBySide: some View {
        HStack(alignment: .bottom, spacing: 12) {
            Color.clear.frame(width: 100, height: 1)
            PhotoFilmstrip(photos: photos, images: images, selection: $selection)
                .frame(maxWidth: .infinity)
            VStack(spacing: 10) {
                exportButton
                Button(String(localized: "editor.develop", defaultValue: "Develop"),
                       systemImage: "camera.filters", action: develop)
                    .photoActionStyle(prominent: true)
                    .accessibilityIdentifier("photo.develop")
                PhotoRevertMenu(canRevert: canRevert, action: revert)
                deleteButton
            }
            .frame(width: 100, alignment: .trailing)
        }
        .disabled(working)
    }
    private var stacked: some View {
        VStack(spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    HStack(spacing: 0) {
                        exportButton
                        Spacer(minLength: 0)
                    }.frame(width: 100)
                    Spacer(minLength: 0)
                    developButton
                    Spacer(minLength: 0)
                    trailingButtons.frame(width: 100, alignment: .trailing)
                }
                VStack(spacing: 10) {
                    developButton
                    HStack {
                        exportButton
                        Spacer()
                        trailingButtons
                    }
                }
            }
            PhotoFilmstrip(photos: photos, images: images, selection: $selection)
        }
        .disabled(working)
    }
    private var trailingButtons: some View {
        HStack(spacing: 12) {
            PhotoRevertMenu(canRevert: canRevert, action: revert)
            deleteButton
        }
    }
    private var developButton: some View {
        Button(action: develop) {
            Text(String(localized: "editor.develop", defaultValue: "Develop"))
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 22)
        }
        .buttonStyle(DevelopActionButtonStyle())
        .accessibilityIdentifier("photo.develop")
    }
    private var exportButton: some View {
        Button(action: export) {
            Label(String(localized: "common.export", defaultValue: "Export"), systemImage: "square.and.arrow.up")
        }
        .accessibilityLabel(String(localized: "common.export", defaultValue: "Export")).photoActionStyle().accessibilityIdentifier(
            "photo.export")
    }
    private var deleteButton: some View {
        Button(role: .destructive) {
            confirmDelete = true
        } label: {
            Label(String(localized: "common.delete", defaultValue: "Delete"), systemImage: "trash")
        }
        .accessibilityLabel(String(localized: "common.delete", defaultValue: "Delete"))
        .photoActionStyle()
        .accessibilityIdentifier("photo.delete")
        .confirmationDialog(
            String(localized: "photo.delete_confirm", defaultValue: "Delete Photo?"),
            isPresented: $confirmDelete,
            titleVisibility: .hidden
        ) {
            Button(
                String(localized: "photo.delete_app_copy", defaultValue: "Delete App Copy"),
                role: .destructive,
                action: performDelete
            )
        } message: {
            Text(deleteMessage)
        }
    }
}

private struct DevelopActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? AnyShapeStyle(.onAccent) : AnyShapeStyle(Color.secondary))
            .frame(height: 44)
            .modifier(DevelopCapsuleSurfaceModifier(isEnabled: isEnabled))
            .opacity(configuration.isPressed ? 0.84 : 1)
            .contentShape(.capsule)
    }
}

private struct DevelopCapsuleSurfaceModifier: ViewModifier {
    let isEnabled: Bool
    func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            if isEnabled {
                content
                    .background(Color.accentColor, in: .capsule)
                    .glassEffect(.regular.tint(Color.accentColor).interactive(), in: .capsule)
            } else {
                content
                    .glassEffect(.regular, in: .capsule)
            }
        } else {
            content
                .background(
                    isEnabled ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.regularMaterial),
                    in: .capsule
                )
        }
    }
}

private struct PhotoRevertMenu: View {
    let canRevert: Bool
    var inSystemToolbar = false
    let action: () -> Void
    @State private var confirmRevert = false

    var body: some View {
        WorkspaceHistoryMenu(
            title: String(localized: "common.revert", defaultValue: "Revert"),
            identifier: "photo.revert",
            placement: inSystemToolbar ? .systemBar : .floating,
            sections: [[
                WorkspaceHistoryItem(
                    title: String(localized: "photo.revert_menu", defaultValue: "Revert to Original…"),
                    systemImage: "arrow.uturn.backward",
                    identifier: "photo.revert.menuAction",
                    isDestructive: true
                ) {
                    confirmRevert = true
                }
            ]]
        )
        .disabled(!canRevert)
        .confirmationDialog(
            String(localized: "photo.revert_confirm", defaultValue: "Revert to original?"),
            isPresented: $confirmRevert,
            titleVisibility: .visible
        ) {
            Button(
                String(localized: "library.revert_to_original", defaultValue: "Revert to Original"),
                role: .destructive,
                action: action
            )
        }
    }
}

/// Each page loads a cached preview; full originals stay outside the paging view.
struct AlbumPhotoPage: View {
    @AppStorage(PreviewQuality.libraryKey) private var previewMaximum = PreviewQuality.defaultMaximum
    let photo: LibraryPhoto
    let images: LibraryImages
    var bottomInset: CGFloat = 132
    var usePortraitReference = true
    var onTap: (() -> Void)? = nil
    @State private var image: UIImage?
    @State private var failure: String?
    @State private var retry = 0
    var body: some View {
        Group {
            if let image {
                PhotoViewport(
                    image: image, topInset: PhotoInfoPanel.collapsedHeight + 4,
                    bottomInset: bottomInset, edited: photo.hasEdits, topAligned: false,
                    usePortraitReference: usePortraitReference, onTap: { _ in onTap?() })
            } else if let failure {
                ContentUnavailableView {
                    Label(
                        String(
                            localized: "photo.load_failed",
                            defaultValue: "Couldn’t show photo"),
                        systemImage: "exclamationmark.triangle")
                } description: {
                    Text(failure)
                } actions: {
                    Button(String(localized: "common.retry", defaultValue: "Retry")) { retry += 1 }
                }
            } else {
                ProgressView(
                    String(localized: "photo.loading", defaultValue: "Loading photo…"))
            }
        }
        .task(id: "\(photo.renderKey)-\(retry)-\(previewMaximum)") {
            do {
                if image == nil, let thumbnail = await images.cachedThumbnail(photo) {
                    try Task.checkCancellation()
                    image = UIImage(cgImage: thumbnail)
                }
                let frame = try await images.image(photo, thumbnail: false)
                try Task.checkCancellation()
                image = UIImage(cgImage: frame)
                failure = nil
            } catch {
                if !Task.isCancelled { image = nil; failure = error.localizedDescription }
            }
        }
    }
}
