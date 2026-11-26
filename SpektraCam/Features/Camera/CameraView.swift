import AVKit
import SwiftUI
import UIKit

/// Camera workspace. Standard iPhones lock the display to portrait and rotate glyphs in place;
/// iPad and iPhone Duo rotate freely and apply a physical quarter-turn of the portrait arrangement
/// when wide so the finder keeps its height and every control keeps its thumb-reach anchor.
struct CameraView: View {
    @State private var model: CameraModel
    let onLibrary: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isLandscape = false
    @State private var verticalBarEdge: HorizontalEdge? = nil
    @State private var locksPortrait = AppDelegate.defaultLocksCameraToPortrait
    @State private var interfaceOrientation: UIInterfaceOrientation = .portrait
    @State private var portraitFinderWidth: CGFloat = 340
    @State private var glyphs = CameraGlyphRotation()
    private var systemVerticalBar: Bool { verticalBarEdge != nil }
    private var wide: Bool { !locksPortrait && isLandscape }
    private var shutterOnRight: Bool {
        if let verticalBarEdge {
            return verticalBarEdge == .trailing
        }
        return interfaceOrientation != .landscapeLeft
    }
    private var glyphDegrees: Double { locksPortrait ? glyphs.degrees : 0 }
    private var turn: Angle { .degrees(glyphDegrees) }

    init(library: PhotoLibrary, onLibrary: @escaping () -> Void) {
        _model = State(initialValue: CameraModel(library: library))
        self.onLibrary = onLibrary
    }
    private var ready: Bool { model.state == .ready }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if wide {
                    wideWorkspace
                } else {
                    viewfinder
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(wide || systemVerticalBar ? .hidden : .visible, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                if !wide && systemVerticalBar {
                    let railWidth = max(240, portraitFinderWidth)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            roundCloseButton
                            verticalBarFormatPill
                            Spacer(minLength: 6)
                            CameraHistogram(model: model)
                                .frame(width: 76, height: 28)
                                .opacity(ready ? 1 : 0)
                            Spacer(minLength: 6)
                            verticalBarExposurePill
                        }
                        HStack(spacing: 8) {
                            roundCloseButton
                            verticalBarFormatPill
                            Spacer(minLength: 8)
                            verticalBarExposurePill
                        }
                    }
                    .frame(maxWidth: railWidth)
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    .padding(.bottom, 2)
                    .frame(maxWidth: .infinity)
                }
            }
            .toolbar {
                if !wide && !systemVerticalBar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(
                            String(localized: "camera.close_camera", defaultValue: "Close Camera"),
                            systemImage: "xmark"
                        ) { dismiss() }
                        .labelStyle(.iconOnly).buttonBorderShape(.circle)
                        .disabled(model.busy).accessibilityIdentifier("camera.close")
                    }
                    AdaptiveToolbarSpacer(.fixed, placement: .topBarLeading)
                    AdaptiveToolbarItem(placement: .topBarLeading, background: .visible) {
                        formatControl().frame(width: 84, height: 32)
                    }
                    ToolbarItem(placement: .principal) {
                        CameraHistogram(model: model).frame(width: 100, height: 32)
                            .opacity(ready ? 1 : 0)
                    }
                    AdaptiveToolbarItem(placement: .topBarTrailing, background: .visible) {
                        CameraExposureReadout(model: model).frame(width: 84, height: 32)
                            .accessibilityIdentifier("camera.exposureInfo")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !wide {
                    let railWidth: CGFloat = systemVerticalBar ? max(240, portraitFinderWidth) : 380
                    VStack(spacing: systemVerticalBar ? 8 : 14) {
                        importFailure
                        Group {
                            // Keep exposure adjustment centered with the shutter at portrait length.
                            exposureControl.frame(maxWidth: 360)
                            ZStack {
                                HStack {
                                    flashButton
                                    Spacer()
                                    flipButton
                                }
                                if !model.lenses.isEmpty {
                                    lensPicker(vertical: false, macroFirst: true)
                                }
                            }
                        }
                        .disabled(!ready)
                        ZStack {
                            HStack {
                                libraryButton
                                Spacer()
                                holdButton
                            }
                            shutterButton
                        }
                    }
                    .frame(maxWidth: railWidth)
                    .padding(.horizontal, systemVerticalBar ? 16 : 20)
                    .padding(.bottom, systemVerticalBar ? 4 : 12)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .background(
            CameraOrientationBridge(
                locksPortrait: $locksPortrait,
                interfaceOrientation: $interfaceOrientation
            ).allowsHitTesting(false))
        .onGeometryChange(for: Bool.self) { $0.size.width > $0.size.height } action: { isLandscape = $0 }
        .onSystemVerticalBarEdge { verticalBarEdge = $0 }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(model.busy)
        .task {
            let recovery = Task { await model.retryImport(includeQuarantined: false) }
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await model.monitor() }
                group.addTask { await model.monitorReadings() }
                group.addTask { await model.setActive(scenePhase != .background) }
            }
            recovery.cancel()
        }
        .onChange(of: scenePhase) { _, phase in
            // Permission prompts and transient overlays make the scene inactive. Only background
            // transitions stop capture; AVFoundation reports hardware interruptions separately.
            if phase != .inactive { Task { await model.setActive(phase == .active) } }
        }
        .onAppear {
            AppDelegate.setCameraActive(true)
            model.refreshLibraryThumbnail()
            glyphs.start()
        }
        .onDisappear {
            let lastOrientation = glyphs.lastDeviceOrientation
            AppDelegate.setCameraActive(false, preferredDeviceOrientation: lastOrientation)
            glyphs.stop()
            Task { await model.close() }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: glyphDegrees)
    }

    // MARK: Wide Layout

    private var wideWorkspace: some View {
        GeometryReader { proxy in
            let compact = proxy.size.width < 940
            let spacing: CGFloat = compact ? 8 : 12
            let edgePad: CGFloat = systemVerticalBar ? 16 : (compact ? 12 : 16)
            let vPad: CGFloat = compact ? 8 : 12
            let sideColumnsWidth: CGFloat = 44 + 46 + 46 + 78
            let availW = max(160, proxy.size.width - 2 * edgePad - 4 * spacing - sideColumnsWidth)
            let availH = max(160, proxy.size.height - 2 * vPad)
            let finderHeight = min(availH, availW * 3.0 / 4.0)
            let columnHeight = min(availH, max(finderHeight, 300))
            let controlColumnHeight = min(columnHeight, 480)
            let trackLength = min(184, max(104, controlColumnHeight - 130))
            let infoAngle: Double = shutterOnRight ? -90 : 90
            let infoColumn = wideInfoColumn(angle: infoAngle, height: columnHeight)
            let evColumn = wideExposureColumn(trackLength: trackLength, height: controlColumnHeight)
            let lensColumn = wideLensColumn(height: controlColumnHeight)
            let releaseColumn = wideReleaseColumn(height: controlColumnHeight)

            HStack(spacing: spacing) {
                if shutterOnRight {
                    infoColumn
                    wideViewfinder(verticalPadding: vPad)
                    evColumn
                    lensColumn
                    releaseColumn
                } else {
                    releaseColumn
                    lensColumn
                    evColumn
                    wideViewfinder(verticalPadding: vPad)
                    infoColumn
                }
            }
            .padding(.horizontal, edgePad)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func wideViewfinder(verticalPadding: CGFloat) -> some View {
        CameraViewfinder(model: model, landscape: true) {
            if !ready { status }
        }
        .padding(.vertical, verticalPadding)
        .overlay(alignment: .bottom) {
            importFailure
                .padding(.horizontal, 12)
                .padding(.bottom, verticalPadding + 10)
        }
        .adaptiveCameraCaptureEvent(isEnabled: scenePhase == .active && model.canCapture) {
            Task { await model.takePhoto() }
        }
    }

    private func wideInfoColumn(angle: Double, height: CGFloat) -> some View {
        let showsHistogram = height >= 352
        return VStack(spacing: 0) {
            if shutterOnRight {
                wideExposureReadout(angle: angle)
                Spacer(minLength: 8)
                if showsHistogram {
                    wideHistogram(angle: angle)
                    Spacer(minLength: 8)
                }
                formatControl(rotatedBy: angle)
                Color.clear.frame(height: 10)
                roundCloseButton
            } else {
                roundCloseButton
                Color.clear.frame(height: 10)
                formatControl(rotatedBy: angle)
                Spacer(minLength: 8)
                if showsHistogram {
                    wideHistogram(angle: angle)
                    Spacer(minLength: 8)
                }
                wideExposureReadout(angle: angle)
            }
        }
        .frame(width: 44, height: height)
    }

    private func wideHistogram(angle: Double) -> some View {
        CameraHistogram(model: model)
            .frame(width: 96, height: 30)
            .rotationEffect(.degrees(angle))
            .frame(width: 30, height: 96)
            .opacity(ready ? 1 : 0)
    }

    private func wideExposureReadout(angle: Double) -> some View {
        CameraExposureReadout(model: model)
            .minimumScaleFactor(0.85)
            .padding(.horizontal, 8)
            .frame(width: 98, height: 36)
            .rotationEffect(.degrees(angle))
            .frame(width: 36, height: 98)
            .adaptiveGlassCapsule()
            .accessibilityIdentifier("camera.exposureInfo")
    }

    private func wideExposureColumn(trackLength: CGFloat, height: CGFloat) -> some View {
        CameraExposureControl(
            value: Binding(get: { model.exposureBias }, set: model.setExposureBias),
            range: model.exposureRange,
            glyphTurn: 0,
            layout: .vertical(valueAtTop: shutterOnRight),
            trackLength: trackLength
        )
        .disabled(!ready || model.busy)
        .frame(height: height)
    }

    private func wideLensColumn(height: CGFloat) -> some View {
        VStack(spacing: 0) {
            Group {
                if shutterOnRight { flipButton } else { flashButton }
            }
            .disabled(!ready)
            Spacer(minLength: 6)
            if !model.lenses.isEmpty {
                lensPicker(vertical: true, macroFirst: !shutterOnRight)
                    .disabled(!ready)
            }
            Spacer(minLength: 6)
            Group {
                if shutterOnRight { flashButton } else { flipButton }
            }
            .disabled(!ready)
        }
        .frame(width: 46, height: height)
    }

    private func wideReleaseColumn(height: CGFloat) -> some View {
        VStack(spacing: 0) {
            if shutterOnRight { holdButton } else { libraryButton }
            Spacer(minLength: 8)
            shutterButton
            Spacer(minLength: 8)
            if shutterOnRight { libraryButton } else { holdButton }
        }
        .frame(width: 78, height: height)
    }

    // MARK: Viewfinder

    private var viewfinder: some View {
        CameraViewfinder(model: model, landscape: false) {
            if !ready { status }
        }
            .padding(.top, 2)
            .padding(.horizontal, 6)
            .onGeometryChange(for: CGFloat.self) { proxy in
                let w = max(proxy.size.width - 12, 0)
                let h = max(proxy.size.height - 2, 0)
                return min(w, h * 3.0 / 4.0)
            } action: { width in
                if width > 120 { portraitFinderWidth = width }
            }
            // Hardware capture follows the same readiness as the shutter. A held camera has
            // no running session, so volume buttons retain their system behavior until resumed.
            .adaptiveCameraCaptureEvent(isEnabled: scenePhase == .active && model.canCapture) {
                Task { await model.takePhoto() }
            }
    }

    @ViewBuilder private var status: some View {
        switch model.state {
        case .ready: EmptyView()
        case .starting:
            ProgressView().controlSize(.large)
                .accessibilityLabel(
                    String(localized: "camera.starting_camera", defaultValue: "Starting camera…"))
        case .paused:
            CameraHoldScreen(held: model.held, reason: model.pauseReason, turn: turn) {
                Task { await model.toggleHold() }
            }
        case .unavailable:
            ContentUnavailableView(
                String(localized: "camera.camera_unavailable", defaultValue: "Camera Unavailable"),
                systemImage: "camera",
                description: Text(
                    String(
                        localized: "camera.error.needs_device",
                        defaultValue: "Camera capture needs a physical device."))
            )
            .accessibilityIdentifier("camera.unavailable")
        case .rawUnsupported:
            ContentUnavailableView(
                String(localized: "camera.raw_unavailable", defaultValue: "RAW Capture Unavailable"),
                systemImage: "camera",
                description: Text(
                    String(
                        localized: "camera.raw_unsupported_note",
                        defaultValue: "This device’s cameras do not provide a supported RAW format. You can still import and edit photos."))
            )
            .accessibilityIdentifier("camera.rawUnsupported")
        case .denied:
            ContentUnavailableView {
                Label(
                    String(localized: "camera.camera_access", defaultValue: "Camera Access"),
                    systemImage: "camera")
            } description: {
                Text(
                    String(
                        localized: "camera.access_denied",
                        defaultValue: "Allow camera access in Settings to take photos."))
            } actions: {
                Button(String(localized: "camera.open_settings", defaultValue: "Open Settings")) {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }.adaptiveGlassButton()
            }
        case .failed(let message):
            ContentUnavailableView {
                Label(
                    String(localized: "camera.camera_stopped", defaultValue: "Camera Stopped"),
                    systemImage: "camera")
            } description: {
                Text(message)
            } actions: {
                Button(String(localized: "common.retry", defaultValue: "Retry")) {
                    Task { await model.setActive(true) }
                }.adaptiveGlassButton()
            }
        }
    }

    // MARK: Controls

    private var exposureControl: some View {
        CameraExposureControl(
            value: Binding(get: { model.exposureBias }, set: model.setExposureBias),
            range: model.exposureRange, glyphTurn: glyphDegrees
        ).disabled(model.busy)
    }

    @ViewBuilder private var importFailure: some View {
        if let resolutionNotice = model.resolutionNotice {
            Text(resolutionNotice)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .adaptiveGlassCapsule()
                .accessibilityIdentifier("camera.resolutionNotice")
        }
        if let failure = model.writeFailure ?? model.transientFailure {
            Text(failure)
                .font(.footnote)
                .padding().adaptiveGlassRect(cornerRadius: 20)
        }
        if let failure = model.importFailure {
            VStack(spacing: 8) {
                Text(failure).font(.footnote)
                if model.pendingCount > 0 {
                    Text(
                        String(
                            localized: "camera.capture_kept",
                            defaultValue: "The capture is kept on this device.")
                    ).font(.footnote)
                    Button(String(localized: "camera.retry_import", defaultValue: "Retry Import")) {
                        Task { await model.retryImport(includeQuarantined: true) }
                    }
                    .adaptiveGlassButton().disabled(model.busy)
                    .accessibilityIdentifier("camera.retryImport")
                }
            }.padding().adaptiveGlassRect(cornerRadius: 20)
        }
    }

    private var roundCloseButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 16, weight: .medium))
                .modifier(CameraRoundControl())
        }
        .buttonStyle(.plain)
        .disabled(model.busy)
        .accessibilityLabel(String(localized: "camera.close_camera", defaultValue: "Close Camera"))
        .accessibilityIdentifier("camera.close")
    }

    /// One capsule for the rear lenses, with macro beside them when the device has it.
    private func lensPicker(vertical: Bool, macroFirst: Bool) -> some View {
        let content = lensSegments(vertical: vertical, macroFirst: macroFirst)
        return Group {
            if vertical {
                VStack(spacing: 2) { content }
            } else {
                HStack(spacing: 2) { content }
            }
        }
        .buttonStyle(.plain).padding(4)
        .adaptiveGlassCapsule()
        .disabled(model.busy).dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    @ViewBuilder private func lensSegments(vertical: Bool, macroFirst: Bool) -> some View {
        let compact = !vertical && systemVerticalBar
        let rear = model.lenses.filter { !$0.front && model.selectedLens?.front != true }
        let ordered = vertical && !macroFirst ? Array(rear.reversed()) : rear
        let showsMacro = model.selectedLens?.front != true && model.lenses.contains(where: \.macro)
        if showsMacro && macroFirst { macroSegment(vertical: vertical, compact: compact) }
        ForEach(ordered) { lens in lensSegment(lens, vertical: vertical, compact: compact) }
        if showsMacro && !macroFirst { macroSegment(vertical: vertical, compact: compact) }
        if model.selectedLens?.front == true {
            Text(String(localized: "camera.front", defaultValue: "Front"))
                .font(.system(size: 13, weight: .semibold)).fixedSize().rotationEffect(turn)
                .modifier(LensSegment(selected: true, vertical: vertical, compact: compact))
                .accessibilityLabel(
                    String(localized: "camera.front_camera", defaultValue: "Front camera"))
        }
    }

    private func macroSegment(vertical: Bool, compact: Bool = false) -> some View {
        Button {
            Task { await model.toggleMacro() }
        } label: {
            Image(systemName: "camera.macro").font(.system(size: compact ? 14 : 15, weight: .medium))
                .rotationEffect(turn).modifier(LensSegment(selected: model.macro, vertical: vertical, compact: compact))
        }
        .accessibilityLabel(String(localized: "camera.macro", defaultValue: "Macro"))
        .accessibilityAddTraits(model.macro ? .isSelected : [])
        .accessibilityIdentifier("camera.macro")
    }

    private func lensSegment(_ lens: CameraLens, vertical: Bool, compact: Bool = false) -> some View {
        let selected = lens.id == model.selectedLens?.id
        return Button {
            Task { await model.selectLens(lens) }
        } label: {
            Text(lens.title).font(.system(size: compact ? 12 : 13, weight: .semibold)).monospacedDigit()
                .fixedSize().rotationEffect(turn).modifier(LensSegment(selected: selected, vertical: vertical, compact: compact))
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("camera.lens.\(lens.millimeters)")
        .accessibilityLabel(
            String(
                localized: "camera.millimeter_lens",
                defaultValue: "\(lens.millimeters) millimeter lens"))
    }

    private var flashButton: some View {
        Button {
            model.flashOn.toggle()
        } label: {
            Image(systemName: model.flashOn ? "bolt.fill" : "bolt.slash.fill")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(model.flashOn ? Color.yellow : Color.primary)
                .rotationEffect(turn).modifier(CameraRoundControl())
        }
        .buttonStyle(.plain)
        .disabled(!model.flashAvailable || model.busy)
        .opacity(model.flashAvailable ? 1 : 0.35)
        .accessibilityLabel(String(localized: "camera.flash", defaultValue: "Flash"))
        .accessibilityValue(
            model.flashOn
                ? String(localized: "common.on", defaultValue: "On")
                : String(localized: "common.off", defaultValue: "Off")
        )
        .accessibilityIdentifier("camera.flash")
    }

    private var flipButton: some View {
        Button {
            Task { await model.flip() }
        } label: {
            Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 16, weight: .medium))
                .rotationEffect(turn).modifier(CameraRoundControl())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "camera.flip_camera", defaultValue: "Flip Camera"))
        .disabled(model.busy || !model.canFlip)
        .accessibilityIdentifier("camera.flip")
    }

    /// LVF, as on a camera body: switches the live view off and on. Off stops the sensor and
    /// the preview, which is what drains the battery between shots.
    private var holdButton: some View {
        Button {
            Task { await model.toggleHold() }
        } label: {
            Text(verbatim: "LVF").font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(model.held ? Color.black : Color.primary)
                .fixedSize().rotationEffect(turn).frame(width: 52, height: 52)
                .background { if model.held { Circle().fill(Color.accentColor) } }
                .adaptiveGlassCircle(interactive: true)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .disabled(model.busy || !(ready || model.held))
        .accessibilityLabel(
            model.held
                ? String(localized: "camera.resume", defaultValue: "Resume Camera")
                : String(localized: "camera.hold", defaultValue: "Hold Camera")
        )
        .accessibilityAddTraits(model.held ? .isSelected : [])
        .accessibilityIdentifier("camera.hold")
    }

    @ViewBuilder private var libraryThumbnailContent: some View {
        switch model.activeButtonCapture {
        case .pending(_, let image, let isProvisional):
            ZStack(alignment: .bottomTrailing) {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Color.black.overlay {
                        ProgressView().controlSize(.small).tint(.white.opacity(0.85))
                    }
                }
                if isProvisional {
                    Circle().fill(Color.accentColor)
                        .frame(width: 7, height: 7)
                        .overlay { Circle().strokeBorder(.black.opacity(0.45), lineWidth: 0.75) }
                        .padding(5)
                }
            }
        case .committed(_, let photo, let image):
            PhotoThumbnail(
                photo: photo, images: model.library.images, showsBadges: false,
                bypassesPause: true, placeholder: image)
        case .library(let photo):
            if let photo {
                PhotoThumbnail(
                    photo: photo, images: model.library.images, showsBadges: false,
                    bypassesPause: true)
            } else {
                Image(systemName: "photo.on.rectangle")
                    .font(.system(size: 18, weight: .medium)).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.white.opacity(0.12))
            }
        }
    }

    private var libraryButton: some View {
        Button(action: onLibrary) {
            libraryThumbnailContent
            .rotationEffect(turn).frame(width: 52, height: 52).clipShape(.rect(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.3), lineWidth: 1) }
            // Failed-save indicator stays visible even when earlier captures already saved.
            .overlay(alignment: .topLeading) {
                if model.hasFailedSave {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white, .red)
                        .offset(x: -5, y: -5)
                        .accessibilityLabel(
                            String(
                                localized: "camera.failed_save",
                                defaultValue: "Capture could not be saved"))
                        .accessibilityIdentifier("camera.failedSave")
                }
            }
            // How many captures this session has added to the library.
            .overlay(alignment: .topTrailing) {
                if model.savedCount > 0 {
                    Text(verbatim: "\(model.savedCount)")
                        .font(.caption2.weight(.bold)).monospacedDigit().foregroundStyle(.black)
                        .padding(.horizontal, 6).frame(minWidth: 20, minHeight: 20)
                        .background(Color.accentColor, in: .capsule).offset(x: 7, y: -7)
                        .accessibilityLabel(
                            String(
                                localized: "camera.saved_to_library",
                                defaultValue: "Saved to Library: \(model.savedCount)")
                        )
                        .accessibilityIdentifier("camera.saved")
                }
            }
        }
        .buttonStyle(.plain).disabled(model.busy)
        .accessibilityLabel(String(localized: "camera.open_library", defaultValue: "Open Library"))
        .accessibilityIdentifier("camera.library")
    }

    private var shutterButton: some View {
        Button {
            Task { await model.takePhoto() }
        } label: {
            Color.clear.frame(width: 78, height: 78)
        }
        .buttonStyle(
            ShutterStyle(
                busy: model.busy,
                waitingForProcessing: model.isWaitingForProcessing,
                dimsWhenDisabled: model.dimsDisabledShutter || model.held,
                animates: !reduceMotion)
        )
        // On hold, the shutter wakes the camera.
        .disabled(!(model.canCapture || model.held))
        .accessibilityLabel(
            model.format.isRAW
                ? String(localized: "camera.take_raw_photo", defaultValue: "Take RAW Photo")
                : String(localized: "camera.take_photo", defaultValue: "Take Photo")
        )
        .accessibilityIdentifier("camera.shutter")
    }

    private var verticalBarFormatPill: some View {
        formatControl(pill: true)
    }

    private var verticalBarExposurePill: some View {
        CameraExposureReadout(model: model)
            .padding(.horizontal, 10)
            .frame(minWidth: 82, minHeight: 36)
            .adaptiveGlassCapsule()
            .accessibilityIdentifier("camera.exposureInfo")
    }

    private var megapixels: Int {
        model.format.supportsResolutionChoice && model.highResolution
            ? model.maximumMegapixels : model.standardMegapixels
    }
    // Bayer RAW dimensions come from the sensor, not a universal 12 MP promise.
    private var formatSummary: String {
        model.format.badge(
            megapixels: megapixels, highResolution: model.highResolution,
            maximumMegapixels: model.maximumMegapixels,
            standardMegapixels: model.standardMegapixels)
    }
    @ViewBuilder private func formatControl(rotatedBy angle: Double? = nil, pill: Bool = false) -> some View {
        if !model.formats.isEmpty {
            Menu {
                if model.formats.count > 1 {
                    Picker(
                        model.formats.allSatisfy(\.isRAW)
                            ? String(localized: "camera.raw_format", defaultValue: "RAW Format")
                            : String(localized: "camera.capture_format", defaultValue: "Format"),
                        selection: $model.format
                    ) {
                        ForEach(model.formats) { Text($0.title).tag($0) }
                    }
                }
                if model.maximumMegapixels > model.standardMegapixels
                    && model.format.supportsResolutionChoice
                {
                    Picker(
                        String(localized: "camera.resolution", defaultValue: "Resolution"),
                        selection: Binding(
                            get: { model.highResolution },
                            set: { value in Task { await model.setHighResolution(value) } }
                        )
                    ) {
                        Text(
                            String(
                                localized: "camera.up_to_mp",
                                defaultValue: "Up to \(model.maximumMegapixels) MP")
                        ).tag(true)
                        Text(
                            String(
                                localized: "camera.standard_mp",
                                defaultValue: "\(model.standardMegapixels) MP")
                        ).tag(false)
                    }
                }
            } label: {
                if let angle {
                    Text(verbatim: formatSummary)
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                        .frame(width: 84, height: 36)
                        .rotationEffect(.degrees(angle))
                        .frame(width: 36, height: 84)
                        .adaptiveGlassCapsule(interactive: true)
                        .contentShape(.capsule)
                } else if pill {
                    Text(verbatim: formatSummary)
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .frame(minWidth: 74, minHeight: 36)
                        .adaptiveGlassCapsule(interactive: true)
                        .contentShape(.capsule)
                } else {
                    Text(verbatim: formatSummary).font(.caption.weight(.semibold)).monospacedDigit()
                }
            }
            .disabled(model.busy).accessibilityIdentifier("camera.format")
            .accessibilityLabel(
                model.format.supportsResolutionChoice
                    && (model.format == .proRAW || model.highResolution)
                    ? model.format.title + ", \(megapixels) MP" : model.format.title)
        } else if angle == nil && !pill {
            Text(verbatim: "—")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("camera.format")
                .accessibilityLabel(
                    String(localized: "camera.capture_format", defaultValue: "Format"))
        }
    }
}

/// Observes window traits, interface orientation, and hinge hardware so standard iPhones enforce
/// portrait orientation throughout modal presentation while iPad and iPhone Duo remain unlocked
/// and receive the active quarter-turn direction.
private struct CameraOrientationBridge: UIViewControllerRepresentable {
    @Binding var locksPortrait: Bool
    @Binding var interfaceOrientation: UIInterfaceOrientation

    func makeUIViewController(context: Context) -> Controller {
        Controller(
            onUpdate: { if locksPortrait != $0 { locksPortrait = $0 } },
            onOrientation: { if interfaceOrientation != $0 { interfaceOrientation = $0 } })
    }
    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.onUpdate = { if locksPortrait != $0 { locksPortrait = $0 } }
        controller.onOrientation = { if interfaceOrientation != $0 { interfaceOrientation = $0 } }
    }

    final class Controller: UIViewController {
        var onUpdate: (Bool) -> Void
        var onOrientation: (UIInterfaceOrientation) -> Void
        private var lastLocked: Bool?
        private var lastOrientation: UIInterfaceOrientation?

        init(onUpdate: @escaping (Bool) -> Void, onOrientation: @escaping (UIInterfaceOrientation) -> Void) {
            self.onUpdate = onUpdate
            self.onOrientation = onOrientation
            super.init(nibName: nil, bundle: nil)
        }
        @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

        override func loadView() {
            let view = HostingView()
            view.isUserInteractionEnabled = false
            view.onWindowChange = { [weak self] window in
                if let window, AppDelegate.cameraActive {
                    AppDelegate.applyOrientationPolicy(in: window)
                }
                self?.refresh()
            }
            if #available(iOS 27.1, *) {
                let hinge = UIHingeInteraction { [weak self] _, update in
                    guard let self else { return }
                    if update.hinge != nil {
                        AppDelegate.setHasHinge(true, in: self.view.window)
                    }
                    self.refresh()
                }
                view.addInteraction(hinge)
            }
            self.view = view
        }

        override func viewDidLoad() {
            super.viewDidLoad()
            registerForTraitChanges([UITraitHorizontalSizeClass.self, UITraitVerticalSizeClass.self]) {
                (self: Self, _) in self.refresh()
            }
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            AppDelegate.setCameraActive(true, in: view.window)
            refresh()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            AppDelegate.applyOrientationPolicy(in: view.window)
            refresh()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            refresh()
        }

        override func viewWillTransition(
            to size: CGSize, with coordinator: any UIViewControllerTransitionCoordinator
        ) {
            super.viewWillTransition(to: size, with: coordinator)
            coordinator.animate(alongsideTransition: nil) { [weak self] _ in
                self?.refresh()
            }
        }

        func refresh() {
            guard let window = viewIfLoaded?.window else { return }
            let locked = AppDelegate.locksCameraToPortrait(in: window)
            let orientation = window.windowScene?.interfaceOrientation ?? .unknown
            let lockChanged = lastLocked != locked
            let orientationChanged = orientation != .unknown && lastOrientation != orientation
            guard lockChanged || orientationChanged else { return }
            if lockChanged { lastLocked = locked }
            if orientationChanged { lastOrientation = orientation }
            Task { @MainActor [weak self] in
                if lockChanged { self?.onUpdate(locked) }
                if orientationChanged { self?.onOrientation(orientation) }
            }
        }
    }

    private final class HostingView: UIView {
        var onWindowChange: ((UIWindow?) -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            onWindowChange?(window)
        }
    }
}

/// What the viewfinder shows while the camera is off: one screen for a user hold and for every
/// system interruption. Only a hold can be ended by tapping.
private struct CameraHoldScreen: View {
    let held: Bool
    let reason: String?
    var turn = Angle.zero
    let resume: () -> Void
    var body: some View {
        Button(action: resume) {
            ZStack {
                // A flat, dim surface: no live pixels, and little for the display to light.
                Color(white: 0.13)
                VStack(spacing: 14) {
                    Image(systemName: "viewfinder").font(.system(size: 44, weight: .ultraLight))
                        .overlay {
                            Rectangle().fill(.secondary).frame(width: 60, height: 1.5)
                                .rotationEffect(.degrees(-45))
                        }
                        .foregroundStyle(.secondary).accessibilityHidden(true)
                    VStack(spacing: 5) {
                        Text(String(localized: "camera.on_hold", defaultValue: "Camera on Hold"))
                            .font(.headline)
                        Text(
                            held
                                ? String(
                                    localized: "camera.hold_power_note",
                                    defaultValue: "The sensor and preview are off to save power.")
                                : reason
                                    ?? String(
                                        localized: "camera.interrupted.generic",
                                        defaultValue: "The camera will resume when it is available.")
                        )
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    if held {
                        Text(String(localized: "camera.hold_hint", defaultValue: "Tap to resume"))
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(.white.opacity(0.1), in: .capsule)
                    }
                }
                .frame(maxWidth: 260).rotationEffect(turn)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain).disabled(!held)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("camera.hold.screen")
    }
}

/// A round glass control around the viewfinder.
private struct CameraRoundControl: ViewModifier {
    func body(content: Content) -> some View {
        content.frame(width: 44, height: 44)
            .adaptiveGlassCircle(interactive: true).contentShape(.circle)
    }
}

private extension View {
    @ViewBuilder func adaptiveCameraCaptureEvent(
        isEnabled: Bool, action: @escaping () -> Void
    ) -> some View {
        if #available(iOS 18.0, *) {
            onCameraCaptureEvent(isEnabled: isEnabled) { event in
                if event.phase == .ended { action() }
            }
        } else {
            self
        }
    }
}

private struct LensSegment: ViewModifier {
    let selected: Bool
    var vertical = false
    var compact = false
    @Environment(\.appAccent) private var accent
    func body(content: Content) -> some View {
        content
            .foregroundStyle(
                accent == .mono
                    ? (selected ? Color.white : Color.white.opacity(0.65))
                    : (selected ? Color.accentColor : Color.primary)
            )
            .frame(minWidth: vertical ? 38 : (compact ? 34 : 40), minHeight: compact ? 36 : 40)
            .padding(.horizontal, (vertical || compact) ? 0 : 2)
            .background {
                if selected {
                    if accent == .mono {
                        Capsule()
                            .fill(.white.opacity(0.24))
                            .overlay { Capsule().strokeBorder(.white.opacity(0.4), lineWidth: 0.75) }
                    } else {
                        Capsule().fill(.white.opacity(0.18))
                    }
                }
            }
            .contentShape(.capsule)
    }
}

/// A ring with a disc that gives under the finger, dims while a capture is in flight,
/// and surfaces system ISP backlog without flickering on momentary readiness transitions.
private struct ShutterStyle: ButtonStyle {
    let busy: Bool
    var waitingForProcessing = false
    var dimsWhenDisabled = true
    let animates: Bool
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay {
                ZStack {
                    ZStack {
                        Circle().strokeBorder(.white, lineWidth: 4)
                        Circle().fill(.white).padding(7)
                            .scaleEffect(configuration.isPressed ? 0.86 : 1)
                            .opacity(busy ? 0.45 : 1)
                    }
                    .opacity((enabled || !dimsWhenDisabled) ? 1 : 0.35)
                    if waitingForProcessing {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    }
                }
            }
            .animation(animates ? .snappy(duration: 0.15) : nil, value: configuration.isPressed)
            .contentShape(.circle)
    }
}
