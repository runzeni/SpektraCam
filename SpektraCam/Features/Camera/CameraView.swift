import AVKit
import SwiftUI
import UIKit

/// Camera workspace. Standard iPhones lock the display to portrait and rotate glyphs in place;
/// iPad and iPhone Duo rotate freely while keeping the same bottom control layout and compact
/// shutter-centered exposure slider.
struct CameraView: View {
    @State private var model: CameraModel
    let onLibrary: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isLandscape = false
    @State private var systemVerticalBar = false
    @State private var locksPortrait = AppDelegate.defaultLocksCameraToPortrait
    @State private var glyphs = CameraGlyphRotation()
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
                viewfinder
            }
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top, spacing: 0) {
                if systemVerticalBar {
                    HStack(spacing: 12) {
                        formatControl.frame(width: 84, height: 32)
                            .adaptiveGlassCapsule()
                            .accessibilityIdentifier("camera.format")
                        Spacer(minLength: 8)
                        CameraHistogram(model: model).frame(width: 100, height: 32)
                            .opacity(ready ? 1 : 0)
                        Spacer(minLength: 8)
                        CameraExposureReadout(model: model).frame(width: 84, height: 32)
                            .adaptiveGlassCapsule()
                            .accessibilityIdentifier("camera.exposureInfo")
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(
                        String(localized: "camera.close_camera", defaultValue: "Close Camera"),
                        systemImage: "xmark"
                    ) { dismiss() }
                    .labelStyle(.iconOnly).buttonBorderShape(.circle)
                    .disabled(model.busy).accessibilityIdentifier("camera.close")
                }
                if !systemVerticalBar {
                    AdaptiveToolbarSpacer(.fixed, placement: .topBarLeading)
                    AdaptiveToolbarItem(placement: .topBarLeading, background: .visible) {
                        formatControl.frame(width: 84, height: 32).accessibilityIdentifier(
                            "camera.format")
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
                let wide = !locksPortrait && isLandscape
                VStack(spacing: wide ? 8 : 14) {
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
                            lensPicker
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
                .frame(maxWidth: 420)
                .padding(.horizontal, 20).padding(.bottom, wide ? 6 : 12)
                .frame(maxWidth: .infinity)
            }
        }
        .background(CameraOrientationBridge(locksPortrait: $locksPortrait).allowsHitTesting(false))
        .onGeometryChange(for: Bool.self) { $0.size.width > $0.size.height } action: { isLandscape = $0 }
        .onSystemVerticalBar { systemVerticalBar = $0 }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(model.busy)
        .task {
            let recovery = Task { await model.retryImport(includeQuarantined: false) }
            await model.setActive(scenePhase != .background)
            _ = await recovery.value
            await model.monitor()
        }
        .onChange(of: scenePhase) { _, phase in
            // Permission prompts and transient overlays make the scene inactive. Only background
            // transitions stop capture; AVFoundation reports hardware interruptions separately.
            if phase != .inactive { Task { await model.setActive(phase == .active) } }
        }
        .onAppear {
            AppDelegate.setCameraActive(true)
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

    // MARK: Viewfinder

    private var viewfinder: some View {
        let wide = !locksPortrait && isLandscape
        return CameraViewfinder(model: model, landscape: wide) {
            if !ready { status }
        }
            .padding(.top, wide ? 8 : 2)
            .padding(.horizontal, wide ? 12 : 6)
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

    /// One capsule for the rear lenses, with macro beside them when the device has it.
    private var lensPicker: some View {
        HStack(spacing: 2) {
            if model.selectedLens?.front != true && model.lenses.contains(where: \.macro) {
                Button {
                    Task { await model.toggleMacro() }
                } label: {
                    Image(systemName: "camera.macro").font(.system(size: 15, weight: .medium))
                        .rotationEffect(turn).modifier(LensSegment(selected: model.macro))
                }
                .accessibilityLabel(String(localized: "camera.macro", defaultValue: "Macro"))
                .accessibilityAddTraits(model.macro ? .isSelected : [])
                .accessibilityIdentifier("camera.macro")
            }
            ForEach(model.lenses.filter { !$0.front && model.selectedLens?.front != true }) { lens in
                let selected = lens.id == model.selectedLens?.id
                Button {
                    Task { await model.selectLens(lens) }
                } label: {
                    Text(lens.title).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                        .fixedSize().rotationEffect(turn).modifier(LensSegment(selected: selected))
                }
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("camera.lens.\(lens.millimeters)")
                .accessibilityLabel(
                    String(
                        localized: "camera.millimeter_lens",
                        defaultValue: "\(lens.millimeters) millimeter lens"))
            }
            if model.selectedLens?.front == true {
                Text(String(localized: "camera.front", defaultValue: "Front"))
                    .font(.system(size: 13, weight: .semibold)).fixedSize().rotationEffect(turn)
                    .modifier(LensSegment(selected: true))
                    .accessibilityLabel(
                        String(localized: "camera.front_camera", defaultValue: "Front camera"))
            }
        }
        .buttonStyle(.plain).padding(4)
        .adaptiveGlassCapsule()
        .disabled(model.busy).dynamicTypeSize(...DynamicTypeSize.xxxLarge)
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

    private var libraryButton: some View {
        Button(action: onLibrary) {
            Group {
                if let photo = model.library.photos.last {
                    PhotoThumbnail(
                        photo: photo, images: model.library.images, showsBadges: false,
                        placeholder: model.provisionalThumbnail)
                } else if let provisional = model.provisionalThumbnail {
                    Image(uiImage: provisional).resizable().scaledToFill()
                } else {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 18, weight: .medium)).frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.white.opacity(0.12))
                }
            }
            .rotationEffect(turn).frame(width: 52, height: 52).clipShape(.rect(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.3), lineWidth: 1) }
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
        .buttonStyle(ShutterStyle(busy: model.busy, animates: !reduceMotion))
        // On hold, the shutter wakes the camera.
        .disabled(!(model.canCapture || model.held))
        .accessibilityLabel(
            model.format.isRAW
                ? String(localized: "camera.take_raw_photo", defaultValue: "Take RAW Photo")
                : String(localized: "camera.take_photo", defaultValue: "Take Photo")
        )
        .accessibilityIdentifier("camera.shutter")
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
    @ViewBuilder private var formatControl: some View {
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
                Text(verbatim: formatSummary).font(.caption.weight(.semibold)).monospacedDigit()
            }
            .disabled(model.busy).accessibilityIdentifier("camera.format")
            .accessibilityLabel(
                model.format.supportsResolutionChoice
                    && (model.format == .proRAW || model.highResolution)
                    ? model.format.title + ", \(megapixels) MP" : model.format.title)
        } else {
            Text(verbatim: "—").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .accessibilityLabel(
                    String(localized: "camera.capture_format", defaultValue: "Format"))
        }
    }
}

/// Observes window traits and hinge hardware so standard iPhones enforce portrait orientation
/// throughout modal presentation while iPad and iPhone Duo remain unlocked.
private struct CameraOrientationBridge: UIViewControllerRepresentable {
    @Binding var locksPortrait: Bool

    func makeUIViewController(context: Context) -> Controller {
        Controller(onUpdate: { if locksPortrait != $0 { locksPortrait = $0 } })
    }
    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.onUpdate = { if locksPortrait != $0 { locksPortrait = $0 } }
    }

    final class Controller: UIViewController {
        var onUpdate: (Bool) -> Void
        private var lastLocked: Bool?

        init(onUpdate: @escaping (Bool) -> Void) {
            self.onUpdate = onUpdate
            super.init(nibName: nil, bundle: nil)
        }
        @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

        override func loadView() {
            let view = HostingView()
            view.isUserInteractionEnabled = false
            view.onWindowChange = { [weak self] in self?.refresh() }
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

        func refresh() {
            guard let window = viewIfLoaded?.window else { return }
            let locked = AppDelegate.locksCameraToPortrait(in: window)
            guard lastLocked != locked else { return }
            lastLocked = locked
            Task { @MainActor [weak self] in self?.onUpdate(locked) }
        }
    }

    private final class HostingView: UIView {
        var onWindowChange: (() -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            onWindowChange?()
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
    func body(content: Content) -> some View {
        content
            .foregroundStyle(selected ? Color.accentColor : Color.primary)
            .frame(minWidth: 40, minHeight: 36).padding(.horizontal, 2)
            .background { if selected { Capsule().fill(.white.opacity(0.16)) } }
            .contentShape(.capsule)
    }
}

/// A ring with a disc that gives under the finger and dims while a capture is in flight.
private struct ShutterStyle: ButtonStyle {
    let busy: Bool
    let animates: Bool
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay {
                ZStack {
                    Circle().strokeBorder(.white, lineWidth: 4)
                    Circle().fill(.white).padding(7)
                        .scaleEffect(configuration.isPressed ? 0.86 : 1)
                        .opacity(busy ? 0.45 : 1)
                }
            }
            .opacity(enabled ? 1 : 0.35)
            .animation(animates ? .snappy(duration: 0.15) : nil, value: configuration.isPressed)
            .contentShape(.circle)
    }
}
