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
    private(set) var savedCount = 0
    private(set) var writeFailure: String?
    private(set) var importFailure: String?
    private(set) var transientFailure: String?
    private(set) var resolutionNotice: String?
    private(set) var pendingCount = 0
    private(set) var provisionalThumbnail: UIImage?
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
    private var starting = false
    private var closed = false
    @ObservationIgnored private let saveAssertion = BackgroundSaveAssertion()

    init(library: PhotoLibrary) {
        self.library = library
        if UserDefaults.standard.bool(forKey: Self.rememberFlashKey) {
            applyingConfiguration = true
            flashOn = UserDefaults.standard.bool(forKey: Self.flashKey)
            applyingConfiguration = false
        }
    }
    /// Shutter unlocks as soon as exposure completes; background ISP fusion and library import
    /// continue behind the next shot while `outputReady` reflects AVFoundation's readiness.
    /// Inbox import failures never disable the shutter; only an unrecoverable write error does.
    var canCapture: Bool {
        !closed && wantsActive && !held && state == .ready && outputReady && !busy
            && writeFailure == nil
    }
    var canFlip: Bool {
        guard let selectedLens else { return false }
        return lenses.contains { $0.front != selectedLens.front }
    }
    func toggleHold() async {
        guard !closed, wantsActive, !busy, state == .ready || held else { return }
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        if held {
            held = false
            await setActive(true)
        } else {
            held = true
            pauseReason = nil
            location.setActive(false)
            state = .paused
            await service.stop()
        }
    }
    func setActive(_ active: Bool) async {
        guard !closed else { return }
        wantsActive = active
        // Returning to the app does not undo a hold; the user asked for the camera to stay off.
        if active && held {
            state = .paused
            return
        }
        #if DEBUG && targetEnvironment(simulator)
            if active && Self.demo {
                applyDemo()
                return
            }
        #endif
        if !active {
            location.setActive(false)
            state = .paused
            await service.stop()
            return
        }
        guard !starting else { return }
        starting = true
        defer { starting = false }
        location.setActive(true)
        state = .starting
        do {
            let configuration = try await service.start()
            guard !closed else {
                location.setActive(false)
                return
            }
            apply(configuration)
            if wantsActive && !held {
                state = .ready
                pauseReason = nil
                location.setActive(true)
            } else {
                location.setActive(false)
                await service.stop()
            }
        } catch {
            location.setActive(false)
            guard wantsActive else {
                state = .paused
                return
            }
            switch error {
            case CameraFailure.denied: state = .denied
            case CameraFailure.unavailable: state = .unavailable
            case CameraFailure.rawUnavailable: state = .rawUnsupported
            default: state = .failed(error.localizedDescription)
            }
        }
    }
    func monitor() async {
        for await event in service.events {
            guard !Task.isCancelled, !closed else { return }
            switch event {
            case .readings(let value):
                readings = value
                // Camera Control changes the device directly; follow it once our own change settles.
                if Date().timeIntervalSince(biasSetAt) > 0.6,
                    abs(Double(value.bias) - exposureBias) > 0.02
                {
                    exposureBias = min(
                        max(Double(value.bias), exposureRange.lowerBound), exposureRange.upperBound)
                }
            case .ready(let ready): outputReady = ready
            case .interrupted(let reason):
                pauseReason = reason
                if wantsActive { state = .paused }
            case .resumed: if wantsActive && !held { await setActive(true) }
            case .failed(let message): if wantsActive { state = .failed(message) }
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
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #if DEBUG && targetEnvironment(simulator)
            if Self.demo {
                try? await Task.sleep(for: .milliseconds(80))
                savedCount += 1
                busy = false
                return
            }
        #endif
        let assertion = saveAssertion
        assertion.begin()
        do {
            let ready = try await service.takePhoto(
                format: format, rotation: source?.captureRotation ?? 90,
                inbox: CameraInbox(root: library.files.root), location: location.captureLocation,
                flash: flashOn && flashAvailable
            ) { [weak self, library] outcome in
                if let self {
                    self.handleStoredCapture(outcome, assertion: assertion)
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
            outputReady = ready
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            busy = false
        } catch CameraFailure.notReady {
            outputReady = false
            busy = false
            assertion.end()
        } catch {
            writeFailure = error.localizedDescription
            busy = false
            assertion.end()
        }
    }
    private func handleStoredCapture(
        _ outcome: Result<CameraService.CaptureStoredResult, Error>, assertion: BackgroundSaveAssertion
    ) {
        switch outcome {
        case .success(let stored):
            writeFailure = nil
            if let thumbnail = stored.thumbnail {
                provisionalThumbnail = UIImage(cgImage: thumbnail)
            }
            let requestedMP = CameraService.nominalMegapixels(stored.requestedDimensions)
            let deliveredMP = CameraService.nominalMegapixels(
                CMVideoDimensions(
                    width: Int32(stored.deliveredWidth), height: Int32(stored.deliveredHeight)))
            if format.supportsResolutionChoice, highResolution,
                requestedMP > standardMegapixels, stored.deliveredWidth > 0,
                deliveredMP < requestedMP - 4
            {
                showResolutionNotice(deliveredMP)
            }
            scheduleImport(assertion: assertion)
        case .failure(let error):
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
            if let self {
                self.savedCount += report.imported
                self.applyRecoveryReport(report)
                if report.imported > 0, let latest = library.photos.last {
                    _ = await library.images.cachedThumbnail(latest)
                    self.provisionalThumbnail = nil
                }
            }
        }
    }
    func retryImport(includeQuarantined: Bool = false) async {
        let report = await library.recoverCaptureBatch(includeQuarantined: includeQuarantined)
        savedCount += report.imported
        applyRecoveryReport(report)
        if report.imported > 0, let latest = library.photos.last {
            _ = await library.images.cachedThumbnail(latest)
            provisionalThumbnail = nil
        }
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
        /// A stand-in camera for layout checks: every control is live, the viewfinder is empty.
        static let demo = ProcessInfo.processInfo.arguments.contains("--ui-test-camera-demo")
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
