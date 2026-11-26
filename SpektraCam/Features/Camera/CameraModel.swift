@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import Observation
import UIKit

@MainActor @Observable final class CameraModel {
    enum State: Equatable {
        case starting, ready, paused, denied, unavailable, rawUnsupported
        case failed(String)
    }
    private(set) var state = State.starting
    private(set) var source: CameraPreviewSource?
    private(set) var formats: [CameraFormat] = []
    @ObservationIgnored private var applyingConfiguration = false
    @ObservationIgnored private var preferredFormat: CameraFormat?
    var format = CameraFormat.proRAW {
        didSet {
            guard !applyingConfiguration, format != oldValue else { return }
            preferredFormat = format
            let selected = format
            let flash = flashOn && flashAvailable
            Task { await service.prepare(format: selected, flash: flash) }
        }
    }
    private(set) var busy = false
    private(set) var outputReady = false
    private(set) var captureReadiness: AVCapturePhotoOutput.CaptureReadiness = .sessionNotRunning
    private var inFlightSaturated = false
    @ObservationIgnored private var readinessBridge: CameraReadinessBridge?
    private(set) var savedCount = 0
    private(set) var writeFailure: String?
    private(set) var importFailure: String?
    private(set) var transientFailure: String?
    private(set) var resolutionNotice: String?
    private(set) var pendingCount = 0
    enum ButtonCapture {
        case library(photo: LibraryPhoto?)
        case pending(token: CameraService.CaptureToken, image: UIImage?, isProvisional: Bool)
        case committed(token: CameraService.CaptureToken, photo: LibraryPhoto, image: UIImage?)
    }
    @ObservationIgnored private var thumbnailCoordinator = CameraThumbnailCoordinator()
    private(set) var buttonCapture = ButtonCapture.library(photo: nil)
    var activeButtonCapture: ButtonCapture {
        switch buttonCapture {
        case .committed(_, let photo, _) where library.photo(photo.id) == nil:
            return .library(photo: library.latestAddedPhoto)
        case .library(let photo) where photo.map({ library.photo($0.id) == nil }) ?? false:
            return .library(photo: library.latestAddedPhoto)
        default:
            return buttonCapture
        }
    }
    func refreshLibraryThumbnail() { syncButtonCapture() }
    private(set) var hasFailedSave = false
    private let service = CameraService()
    let library: PhotoLibrary
    private(set) var readings = CameraReadings()
    private(set) var lenses: [CameraLens] = []
    private(set) var selectedLens: CameraLens?
    private(set) var macro = false
    private(set) var highResolution = false
    private(set) var standardMegapixels = 12
    private(set) var maximumMegapixels = 12
    private(set) var pauseReason: String?
    private(set) var exposureBias = 0.0
    private(set) var exposureRange: ClosedRange<Double> = -3...3
    /// LVF hold: the user switched the camera off to save power. Only the user ends it.
    private(set) var held = false
    private(set) var flashAvailable = false
    static let rememberFlashKey = "camera.rememberFlash"
    private static let flashKey = "camera.flashOn"
    var flashOn = false {
        didSet {
            if UserDefaults.standard.bool(forKey: Self.rememberFlashKey) {
                UserDefaults.standard.set(flashOn, forKey: Self.flashKey)
            }
            guard !applyingConfiguration, flashOn != oldValue else { return }
            let selected = format
            let flash = flashOn && flashAvailable
            Task { await service.prepare(format: selected, flash: flash) }
        }
    }
    @ObservationIgnored private var importTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var biasSetAt = Date.distantPast
    private let location = CameraLocation()
    private var beforeMacro: String?
    private var backLens: String?
    private var wantsActive = false
    private var reconciling = false
    private var closed = false
    @ObservationIgnored private let saveAssertion = BackgroundSaveAssertion()

    init(library: PhotoLibrary) {
        self.library = library
        if UserDefaults.standard.bool(forKey: Self.rememberFlashKey) {
            applyingConfiguration = true
            flashOn = UserDefaults.standard.bool(forKey: Self.flashKey)
            applyingConfiguration = false
        }
        syncButtonCapture()
    }
    private func syncButtonCapture() {
        thumbnailCoordinator.pruneInactivePhotos { [library] id in library.photo(id) != nil }
        hasFailedSave = thumbnailCoordinator.hasFailedSave
        switch thumbnailCoordinator.buttonState {
        case .library:
            buttonCapture = .library(photo: library.latestAddedPhoto)
        case .pending(let token, let image, let isProvisional):
            buttonCapture = .pending(token: token, image: image.map(UIImage.init(cgImage:)), isProvisional: isProvisional)
        case .committed(let token, let photo, let image):
            buttonCapture = .committed(token: token, photo: photo, image: image.map(UIImage.init(cgImage:)))
        }
    }
    /// Shutter unlocks as soon as exposure completes; background ISP fusion and library import
    /// continue behind the next shot while `outputReady` reflects AVFoundation's readiness.
    /// Capture or write errors surface as notices without permanently bricking future shots.
    var canCapture: Bool {
        !closed && wantsActive && !held && state == .ready && outputReady && !busy
    }
    /// True while system ISP (`cameracaptured`) is still processing prior high-resolution captures.
    var isWaitingForProcessing: Bool {
        !closed && wantsActive && !held && state == .ready
            && captureReadiness == .notReadyWaitingForProcessing
    }
    /// Per Apple's `AVCapturePhotoOutput.captureReadiness` guidance, `.notReadyMomentarily`
    /// prevents rapid double-taps without flashing the shutter dimmed.
    var dimsDisabledShutter: Bool {
        if !closed && wantsActive && !held && state == .ready
            && captureReadiness == .notReadyMomentarily && !inFlightSaturated
        {
            return false
        }
        return true
    }
    private func syncOutputReady() {
        if let readinessBridge {
            captureReadiness = readinessBridge.currentReadiness
            outputReady = !closed && wantsActive && !held && !inFlightSaturated
                && captureReadiness == .ready
        }
    }
    var canFlip: Bool {
        guard let selectedLens else { return false }
        return lenses.contains { $0.front != selectedLens.front }
    }
    func toggleHold() async {
        guard !closed, wantsActive, !busy, state == .ready || held else { return }
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        held.toggle()
        if !held {
            writeFailure = nil
            transientFailure = nil
        } else {
            pauseReason = nil
        }
        await reconcileActiveState()
    }
    func setActive(_ active: Bool) async {
        guard !closed else { return }
        wantsActive = active
        if active && !held {
            writeFailure = nil
            transientFailure = nil
        }
        await reconcileActiveState()
    }
    private func reconcileActiveState() async {
        guard !reconciling, !closed else { return }
        reconciling = true
        defer { reconciling = false }

        while !closed {
            let shouldRun = wantsActive && !held
            if !shouldRun {
                location.setActive(false)
                outputReady = false
                state = .paused
                await service.stop()
                if !(wantsActive && !held) { return }
                continue
            }
            #if DEBUG && targetEnvironment(simulator)
                if Self.demo {
                    applyDemo()
                    if wantsActive && !held { return }
                    continue
                }
            #endif
            if state != .ready { state = .starting }
            do {
                let configuration = try await service.start()
                guard !closed else {
                    location.setActive(false)
                    return
                }
                if !(wantsActive && !held) { continue }
                apply(configuration)
                if configuration.interrupted {
                    pauseReason = configuration.interruptionReason
                    outputReady = false
                    location.setActive(false)
                    state = .paused
                } else {
                    state = .ready
                    pauseReason = nil
                    location.setActive(true)
                    syncOutputReady()
                }
                if wantsActive && !held { return }
            } catch {
                location.setActive(false)
                outputReady = false
                if !(wantsActive && !held) {
                    state = .paused
                    return
                }
                switch error {
                case CameraFailure.denied: state = .denied
                case CameraFailure.unavailable: state = .unavailable
                case CameraFailure.rawUnavailable: state = .rawUnsupported
                default: state = .failed(error.localizedDescription)
                }
                return
            }
        }
    }
    func monitor() async {
        for await event in service.events {
            guard !Task.isCancelled, !closed else { return }
            switch event {
            case .ready(let ready):
                if readinessBridge == nil {
                    outputReady = ready
                } else {
                    syncOutputReady()
                }
            case .inFlight(let count, let max):
                inFlightSaturated = count >= max
                syncOutputReady()
            case .interrupted(let reason):
                pauseReason = reason
                outputReady = false
                if wantsActive { state = .paused }
            case .resumed:
                if wantsActive && !held { await setActive(true) }
            case .failed(let message):
                outputReady = false
                if wantsActive { state = .failed(message) }
            }
        }
    }
    func monitorReadings() async {
        for await value in service.readingsStream {
            guard !Task.isCancelled, !closed else { return }
            readings = value
            // Camera Control changes the device directly; follow it once our own change settles.
            if Date().timeIntervalSince(biasSetAt) > 0.6,
                abs(Double(value.bias) - exposureBias) > 0.02
            {
                exposureBias = min(
                    max(Double(value.bias), exposureRange.lowerBound), exposureRange.upperBound)
            }
        }
    }
    func takePhoto() async {
        guard !closed, wantsActive else { return }
        // The shutter wakes a held camera instead of failing silently.
        if held {
            await toggleHold()
            return
        }
        guard canCapture else { return }
        busy = true
        writeFailure = nil
        transientFailure = nil
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #if DEBUG && targetEnvironment(simulator)
            if Self.demo {
                let demoToken = thumbnailCoordinator.issueToken(
                    format: format, highResolution: highResolution,
                    standardMegapixels: standardMegapixels, flash: flashOn && flashAvailable)
                thumbnailCoordinator.didExpose(token: demoToken, provisionalFrame: nil)
                syncButtonCapture()
                try? await Task.sleep(for: .milliseconds(80))
                savedCount += 1
                thumbnailCoordinator.completeDemoCapture(
                    token: demoToken, latest: library.latestAddedPhoto)
                syncButtonCapture()
                busy = false
                return
            }
        #endif
        let assertion = saveAssertion
        assertion.begin()
        let token = thumbnailCoordinator.issueToken(
            format: format, highResolution: highResolution,
            standardMegapixels: standardMegapixels, flash: flashOn && flashAvailable)
        do {
            let ready = try await service.takePhoto(
                token: token, rotation: source?.captureRotation ?? 90,
                inbox: CameraInbox(root: library.files.root), location: location.captureLocation,
                flash: token.flash,
                onExposure: { [weak self] exposedToken, snapshot in
                    self?.thumbnailCoordinator.didExpose(token: exposedToken, provisionalFrame: snapshot)
                    self?.syncButtonCapture()
                },
                onStillPreview: { [weak self] previewToken, preview in
                    self?.thumbnailCoordinator.didReceiveStillPreview(token: previewToken, image: preview)
                    self?.syncButtonCapture()
                }
            ) { [weak self, library] outcome in
                if let self {
                    self.handleStoredCapture(outcome, fallbackToken: token, assertion: assertion)
                } else if case .success = outcome {
                    // Camera closed while ISP was finishing: import the durable inbox file anyway.
                    Task { @MainActor in
                        defer { assertion.end() }
                        _ = await library.recoverCaptureBatch()
                    }
                } else {
                    assertion.end()
                }
            }
            writeFailure = nil
            transientFailure = nil
            if readinessBridge == nil { outputReady = ready } else { syncOutputReady() }
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            busy = false
        } catch CameraFailure.notReady {
            thumbnailCoordinator.didFailWrite(for: token)
            syncButtonCapture()
            if readinessBridge == nil { outputReady = false } else { syncOutputReady() }
            busy = false
            assertion.end()
        } catch {
            thumbnailCoordinator.didFailWrite(for: token)
            syncButtonCapture()
            transientFailure = error.localizedDescription
            syncOutputReady()
            busy = false
            assertion.end()
        }
    }
    private func handleStoredCapture(
        _ outcome: Result<CameraService.CaptureStoredResult, Error>,
        fallbackToken: CameraService.CaptureToken,
        assertion: BackgroundSaveAssertion
    ) {
        switch outcome {
        case .success(let stored):
            writeFailure = nil
            thumbnailCoordinator.didStoreToInbox(result: stored)
            syncButtonCapture()
            let token = stored.token
            let requestedMP = CameraService.nominalMegapixels(stored.requestedDimensions)
            let deliveredMP = CameraService.nominalMegapixels(
                CMVideoDimensions(
                    width: Int32(stored.deliveredWidth), height: Int32(stored.deliveredHeight)))
            if token.format.supportsResolutionChoice, token.highResolution,
                requestedMP > token.standardMegapixels, stored.deliveredWidth > 0,
                deliveredMP < requestedMP - 4
            {
                showResolutionNotice(deliveredMP)
            }
            scheduleImport(assertion: assertion)
        case .failure(let error):
            thumbnailCoordinator.didFailWrite(for: fallbackToken)
            syncButtonCapture()
            writeFailure = error.localizedDescription
            assertion.end()
        }
    }
    private func showResolutionNotice(_ deliveredMP: Int) {
        noticeTask?.cancel()
        resolutionNotice = String(
            localized: "camera.notice.saved_at_mp",
            defaultValue: "Saved at \(deliveredMP) MP")
        noticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled else { return }
            self?.resolutionNotice = nil
        }
    }
    /// The capture is already safe in the inbox. Import it behind the next shot, one at a time.
    private func scheduleImport(assertion: BackgroundSaveAssertion) {
        let previous = importTask
        let library = self.library
        importTask = Task { @MainActor [weak self] in
            defer { assertion.end() }
            await previous?.value
            let report = await library.recoverCaptureBatch(includeQuarantined: false)
            var preloaded: [UUID: CGImage?] = [:]
            for photo in report.importedByURL.values {
                preloaded[photo.id] = await library.images.cachedThumbnail(photo)
            }
            if let self {
                self.savedCount += report.imported
                self.applyRecoveryReport(report)
                self.thumbnailCoordinator.didRecoverImports(
                    report.importedByURL, cachedThumbnails: preloaded)
                self.syncButtonCapture()
            }
        }
    }
    func retryImport(includeQuarantined: Bool = false) async {
        let report = await library.recoverCaptureBatch(includeQuarantined: includeQuarantined)
        var preloaded: [UUID: CGImage?] = [:]
        for photo in report.importedByURL.values {
            preloaded[photo.id] = await library.images.cachedThumbnail(photo)
        }
        savedCount += report.imported
        applyRecoveryReport(report)
        thumbnailCoordinator.didRecoverImports(report.importedByURL, cachedThumbnails: preloaded)
        syncButtonCapture()
    }
    private func applyRecoveryReport(_ report: PhotoLibrary.CaptureRecoveryReport) {
        let pending = (try? CameraInbox(root: library.files.root).pending().count) ?? 0
        pendingCount = pending + report.totalQuarantined.count
        if let transient = report.transientError {
            importFailure = transient
        } else if !report.totalQuarantined.isEmpty {
            let count = report.totalQuarantined.count
            importFailure =
                count == 1
                ? String(
                    localized: "camera.import_quarantined_one",
                    defaultValue: "One earlier capture couldn’t be imported and was kept safely.")
                : String(
                    localized: "camera.import_quarantined_many",
                    defaultValue: "\(count) earlier captures couldn’t be imported and were kept safely.")
        } else {
            importFailure = nil
        }
    }
    private func resolveFormatSelection() {
        if preferredFormat == nil {
            preferredFormat = formats.first
        }
        if let preferredFormat, formats.contains(preferredFormat) {
            format = preferredFormat
        } else if let first = formats.first {
            format = first
        }
    }
    private func apply(_ configuration: CameraService.Configuration) {
        applyingConfiguration = true
        defer { applyingConfiguration = false }
        source = configuration.source
        if readinessBridge !== configuration.readinessBridge {
            readinessBridge?.disconnect()
            readinessBridge = configuration.readinessBridge
            configuration.readinessBridge.connect { [weak self] readiness in
                guard let self else { return }
                self.captureReadiness = readiness
                self.syncOutputReady()
            }
        }
        if readinessBridge == nil {
            outputReady = configuration.outputReady
        } else {
            syncOutputReady()
        }
        formats = configuration.formats
        lenses = configuration.lenses
        selectedLens = configuration.selectedLens
        macro = configuration.macro
        highResolution = configuration.highResolution
        standardMegapixels = configuration.standardMegapixels
        maximumMegapixels = configuration.maximumMegapixels
        exposureBias = configuration.exposureBias
        exposureRange = configuration.exposureRange
        flashAvailable = configuration.flashAvailable
        resolveFormatSelection()
        let selected = format
        let flash = flashOn && flashAvailable
        Task { await service.prepare(format: selected, flash: flash) }
    }
    func selectLens(_ lens: CameraLens, macro: Bool = false) async {
        guard !busy, state == .ready else { return }
        #if DEBUG && targetEnvironment(simulator)
            if Self.demo {
                selectedLens = lens
                self.macro = macro
                flashAvailable = !lens.front
                applyDemoFormats(for: lens)
                return
            }
        #endif
        busy = true
        defer { busy = false }
        do {
            apply(try await service.selectLens(lens.id, macro: macro))
            transientFailure = nil
            UISelectionFeedbackGenerator().selectionChanged()
        } catch CameraFailure.notReady {
        } catch { transientFailure = error.localizedDescription }
    }
    func setHighResolution(_ enabled: Bool) async {
        guard !busy, state == .ready else { return }
        #if DEBUG && targetEnvironment(simulator)
            if Self.demo {
                highResolution = enabled
                return
            }
        #endif
        busy = true
        defer { busy = false }
        do {
            apply(try await service.setHighResolution(enabled))
            transientFailure = nil
        } catch CameraFailure.notReady {
        } catch {
            transientFailure = error.localizedDescription
        }
    }
    func focus(at point: CGPoint) async {
        guard state == .ready, !busy else { return }
        do {
            try await service.focus(at: point)
            transientFailure = nil
            UISelectionFeedbackGenerator().selectionChanged()
        } catch CameraFailure.notReady {
        } catch { transientFailure = error.localizedDescription }
    }
    func setExposureBias(_ value: Double) {
        guard state == .ready, !busy else { return }
        biasSetAt = Date()
        exposureBias = min(max(value, exposureRange.lowerBound), exposureRange.upperBound)
        #if DEBUG && targetEnvironment(simulator)
            if Self.demo { return }
        #endif
        let target = exposureBias
        Task {
            do {
                try await service.setExposureBias(target)
                transientFailure = nil
            } catch CameraFailure.notReady {
            } catch {
                transientFailure = error.localizedDescription
            }
        }
    }
    func toggleMacro() async {
        if macro {
            if let lens = lenses.first(where: { $0.id == beforeMacro }) { await selectLens(lens) }
        } else if let lens = lenses.first(where: \.macro) {
            beforeMacro = selectedLens?.id
            await selectLens(lens, macro: true)
        }
    }
    func flip() async {
        if selectedLens?.front == true {
            if let lens = lenses.first(where: { $0.id == backLens })
                ?? lenses.first(where: { !$0.front && $0.primary })
            {
                await selectLens(lens)
            }
        } else if let lens = lenses.first(where: \.front) {
            backLens = selectedLens?.id
            await selectLens(lens)
        }
    }
    #if DEBUG && targetEnvironment(simulator)
        /// A stand-in camera for layout checks: every control is live, the viewfinder stays black
        /// unless `--ui-test-camera-scene` or `SPEKTRACAM_CAMERA_SCENE_IMAGE` is set.
        static let demo = ProcessInfo.processInfo.arguments.contains("--ui-test-camera-demo")
        static let demoScene = ProcessInfo.processInfo.arguments.contains("--ui-test-camera-scene")
        static var demoSceneImagePath: String? {
            ProcessInfo.processInfo.environment["SPEKTRACAM_CAMERA_SCENE_IMAGE"]
        }
        private func applyDemo() {
            let args = ProcessInfo.processInfo.arguments
            if args.contains("--ui-test-camera-no-raw") {
                lenses = []
                formats = []
                outputReady = false
                state = .rawUnsupported
                return
            }
            let bayerOnly = args.contains("--ui-test-camera-bayer-only")
            let bayerHybrid = args.contains("--ui-test-camera-bayer-hybrid")
            let regularOnly = args.contains("--ui-test-camera-regular-only")
            lenses = [
                CameraLens(id: "13", millimeters: 13, front: false, macro: !regularOnly, primary: false),
                CameraLens(id: "24", millimeters: 24, front: false, macro: false, primary: true),
                CameraLens(id: "120", millimeters: 120, front: false, macro: false, primary: false),
                CameraLens(id: "front", millimeters: 23, front: true, macro: false, primary: false),
            ]
            if bayerOnly {
                lenses = lenses.filter { $0.primary || $0.id == "120" }
            } else if regularOnly || bayerHybrid {
                lenses = lenses.filter { $0.id != "120" }
            }
            if selectedLens == nil { selectedLens = lenses.first(where: \.primary) }
            applyDemoFormats(for: selectedLens)
            standardMegapixels = 12
            maximumMegapixels = (regularOnly || bayerHybrid) ? 12 : 48
            flashAvailable = selectedLens?.front != true
            outputReady = true
            readings = CameraReadings(
                histogram: (0..<64).map { exp(-pow(Double($0) - 26, 2) / 180) }, seconds: 1.0 / 250,
                aperture: 1.8, iso: 64, bias: Float(exposureBias))
            state = .ready
        }
        private func applyDemoFormats(for lens: CameraLens?) {
            let args = ProcessInfo.processInfo.arguments
            let bayerOnly = args.contains("--ui-test-camera-bayer-only")
            let bayerHybrid = args.contains("--ui-test-camera-bayer-hybrid")
            let regularOnly = args.contains("--ui-test-camera-regular-only")
            applyingConfiguration = true
            defer { applyingConfiguration = false }
            if lens?.front == true || regularOnly || (bayerHybrid && lens?.primary != true) {
                formats = [.heic]
            } else if bayerOnly {
                formats = [.bayerRAW]
            } else if bayerHybrid {
                formats = [.bayerRAW, .heic]
            } else {
                formats = [.proRAW, .bayerRAW, .heic]
            }
            resolveFormatSelection()
        }
    #endif
    func close() async {
        if !UserDefaults.standard.bool(forKey: Self.rememberFlashKey) {
            applyingConfiguration = true
            flashOn = false
            applyingConfiguration = false
            UserDefaults.standard.removeObject(forKey: Self.flashKey)
        }
        closed = true
        wantsActive = false
        outputReady = false
        captureReadiness = .sessionNotRunning
        readinessBridge?.disconnect()
        readinessBridge = nil
        state = .paused
        location.setActive(false)
        await service.shutdown()
    }
}

/// Reference-counted background save assertion retained across capture and inbox recovery so
/// dismissing `CameraView` mid-save never leaks or prematurely ends `UIBackgroundTaskIdentifier`.
@MainActor private final class BackgroundSaveAssertion {
    private var activeCount = 0
    private var task = UIBackgroundTaskIdentifier.invalid

    func begin() {
        activeCount += 1
        guard task == .invalid else { return }
        task = UIApplication.shared.beginBackgroundTask(withName: "Save Camera Photo") { [weak self] in
            Task { @MainActor in self?.forceEnd() }
        }
    }

    func end() {
        activeCount = max(0, activeCount - 1)
        if activeCount == 0 { forceEnd() }
    }

    private func forceEnd() {
        guard task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task)
        task = .invalid
    }

    deinit {
        let remaining = task
        if remaining != .invalid {
            Task { @MainActor in UIApplication.shared.endBackgroundTask(remaining) }
        }
    }
}

/// Ordered capture-to-thumbnail state machine. Only the latest exposure owns the camera
/// library button, independent of EXIF capture-date sorting or async ISP completion order.
nonisolated struct CameraThumbnailCoordinator: @unchecked Sendable {
    enum ButtonState: @unchecked Sendable {
        case library
        case pending(token: CameraService.CaptureToken, image: CGImage?, isProvisional: Bool)
        case committed(token: CameraService.CaptureToken, photo: LibraryPhoto, image: CGImage?)
    }

    private(set) var nextSequence: UInt64 = 1
    private(set) var latestExposedSequence: UInt64 = 0
    private(set) var buttonState: ButtonState = .library
    private(set) var lastCommitted: (token: CameraService.CaptureToken, photo: LibraryPhoto, image: CGImage?)?
    private(set) var hasFailedSave = false
    private var hasExactStillForSequence: Set<UInt64> = []
    private var inboxTokens: [URL: CameraService.CaptureToken] = [:]

    mutating func issueToken(
        format: CameraFormat, highResolution: Bool, standardMegapixels: Int, flash: Bool
    ) -> CameraService.CaptureToken {
        let sequence = nextSequence
        nextSequence &+= 1
        return CameraService.CaptureToken(
            id: UUID(), sequence: sequence, format: format,
            highResolution: highResolution, standardMegapixels: standardMegapixels, flash: flash)
    }

    mutating func pruneInactivePhotos(isActive: (UUID) -> Bool) {
        if let last = lastCommitted, !isActive(last.photo.id) {
            lastCommitted = nil
        }
        if case .committed(_, let photo, _) = buttonState, !isActive(photo.id) {
            buttonState = lastCommitted.map {
                .committed(token: $0.token, photo: $0.photo, image: $0.image)
            } ?? .library
        }
    }

    mutating func didExpose(token: CameraService.CaptureToken, provisionalFrame: CGImage?) {
        guard token.sequence >= latestExposedSequence else { return }
        let isNewExposure = token.sequence > latestExposedSequence
        latestExposedSequence = token.sequence
        hasFailedSave = false
        if isNewExposure {
            hasExactStillForSequence = hasExactStillForSequence.filter { $0 >= token.sequence }
            buttonState = .pending(token: token, image: provisionalFrame, isProvisional: true)
            return
        }
        guard !hasExactStillForSequence.contains(token.sequence), let provisionalFrame else { return }
        if case .pending(let current, _, _) = buttonState, current.id == token.id {
            buttonState = .pending(token: token, image: provisionalFrame, isProvisional: true)
        }
    }

    mutating func didReceiveStillPreview(token: CameraService.CaptureToken, image: CGImage) {
        hasExactStillForSequence.insert(token.sequence)
        guard token.sequence >= latestExposedSequence else { return }
        latestExposedSequence = token.sequence
        if case .committed(let committedToken, let photo, _) = buttonState,
            committedToken.id == token.id
        {
            buttonState = .committed(token: token, photo: photo, image: image)
            lastCommitted = (token, photo, image)
        } else {
            buttonState = .pending(token: token, image: image, isProvisional: false)
        }
    }

    mutating func didStoreToInbox(result: CameraService.CaptureStoredResult) {
        inboxTokens[result.url.standardizedFileURL] = result.token
        if let thumb = result.thumbnail {
            didReceiveStillPreview(token: result.token, image: thumb)
        }
    }

    mutating func didFailWrite(for token: CameraService.CaptureToken?) {
        hasFailedSave = true
        if let token { hasExactStillForSequence.remove(token.sequence) }
        if case .pending(let current, _, _) = buttonState, token == nil || current.id == token?.id {
            if let last = lastCommitted {
                buttonState = .committed(token: last.token, photo: last.photo, image: last.image)
            } else {
                buttonState = .library
            }
        }
    }

    @discardableResult
    mutating func didRecoverImports(
        _ importedByURL: [URL: LibraryPhoto], cachedThumbnails: [UUID: CGImage?] = [:]
    ) -> LibraryPhoto? {
        var promoted: LibraryPhoto?
        for (url, photo) in importedByURL {
            guard let token = inboxTokens.removeValue(forKey: url.standardizedFileURL) else {
                continue
            }
            guard token.sequence >= latestExposedSequence else { continue }
            latestExposedSequence = token.sequence
            let carriedImage: CGImage?
            if let hit = cachedThumbnails[photo.id] ?? nil {
                carriedImage = hit
            } else {
                switch buttonState {
                case .pending(let cur, let img, _) where cur.id == token.id: carriedImage = img
                case .committed(let cur, _, let img) where cur.id == token.id: carriedImage = img
                default: carriedImage = nil
                }
            }
            buttonState = .committed(token: token, photo: photo, image: carriedImage)
            lastCommitted = (token, photo, carriedImage)
            promoted = photo
        }
        return promoted
    }

    mutating func completeDemoCapture(token: CameraService.CaptureToken, latest: LibraryPhoto?) {
        guard token.sequence >= latestExposedSequence else { return }
        if let latest {
            buttonState = .committed(token: token, photo: latest, image: nil)
            lastCommitted = (token, latest, nil)
        } else if case .pending(let cur, _, _) = buttonState, cur.id == token.id {
            buttonState = .library
        }
    }
}
