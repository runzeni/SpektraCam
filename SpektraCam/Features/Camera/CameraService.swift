@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import ImageIO
import OSLog

nonisolated enum CameraFormat: String, CaseIterable, Identifiable, Sendable {
    case proRAW, bayerRAW, heic, jpeg
    var id: Self { self }
    var isRAW: Bool { self == .proRAW || self == .bayerRAW }
    var supportsResolutionChoice: Bool { self != .bayerRAW }
    var fileExtension: String {
        switch self {
        case .proRAW, .bayerRAW: "dng"
        case .heic: "heic"
        case .jpeg: "jpg"
        }
    }
    var title: String {
        switch self {
        case .proRAW:
            "Apple ProRAW"
        case .bayerRAW:
            String(localized: "camera.format_bayer_raw", defaultValue: "Bayer RAW")
        case .heic:
            "HEIC"
        case .jpeg:
            "JPEG"
        }
    }
    func badge(megapixels: Int, highResolution: Bool, maximumMegapixels: Int) -> String {
        switch self {
        case .proRAW:
            "PRO \(megapixels)"
        case .bayerRAW:
            "RAW"
        case .heic:
            highResolution && maximumMegapixels > 12 ? "HEIC \(megapixels)" : "HEIC"
        case .jpeg:
            highResolution && maximumMegapixels > 12 ? "JPEG \(megapixels)" : "JPEG"
        }
    }
}

nonisolated enum CameraFailure: LocalizedError {
    case unavailable, denied, configuration, rawUnavailable, notReady, noData, noPhotoData
    var errorDescription: String? {
        switch self {
        case .unavailable:
            String(
                localized: "camera.error.needs_device",
                defaultValue: "Camera capture needs a physical device.")
        case .denied:
            String(
                localized: "camera.access_denied",
                defaultValue: "Allow camera access in Settings to take photos.")
        case .configuration:
            String(
                localized: "camera.error.start_failed",
                defaultValue: "The camera could not start.")
        case .rawUnavailable:
            String(
                localized: "camera.error.raw_unsupported",
                defaultValue: "This camera does not support RAW capture.")
        case .notReady:
            String(
                localized: "camera.error.not_ready",
                defaultValue: "The camera is not ready. Try again.")
        case .noData:
            String(
                localized: "camera.error.no_raw_data",
                defaultValue: "The camera did not return a RAW photo.")
        case .noPhotoData:
            String(
                localized: "camera.error.no_photo_data",
                defaultValue: "The camera did not return a photo.")
        }
    }
}

/// Session configuration, capture and file writing run away from the main actor.
actor CameraService {
    nonisolated enum Event: Sendable {
        case ready(Bool)
        case interrupted(String)
        case resumed
        case failed(String)
        case readings(CameraReadings)
    }
    private enum FormatSpec: Sendable {
        case raw(OSType)
        case processed(AVVideoCodecType, AVFileType?)
    }
    private struct PreparedKey: Equatable {
        let deviceID: String
        let format: CameraFormat
        let flash: Bool
        let highResolution: Bool
    }
    private static var maxInFlightCaptures: Int {
        #if os(iOS) && !targetEnvironment(simulator)
            return ProcessInfo.processInfo.physicalMemory < 4_500_000_000 ? 2 : 3
        #else
            return 3
        #endif
    }
    nonisolated let events: AsyncStream<Event>
    private let sink: AsyncStream<Event>.Continuation
    private let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let video = AVCaptureVideoDataOutput()
    private let meterQueue = DispatchQueue(label: "SpektraCam.CameraMeter", qos: .utility)
    private let writeQueue = DispatchQueue(label: "SpektraCam.CameraWrite", qos: .userInitiated)
    private var meter: CameraMeter?
    private var devices: [String: AVCaptureDevice] = [:]
    private var inputs: [String: AVCaptureDeviceInput] = [:]
    private var lenses: [CameraLens] = []
    private var activeLens: CameraLens?
    private var macro = false
    private var highResolution = false
    private var source: CameraPreviewSource?
    private var sourceDeviceID: String?
    private var formats: [CameraFormat: FormatSpec] = [:]
    private var preferredFormat: CameraFormat?
    private var preparedFlash = false
    private var preparedKey: PreparedKey?
    private var captures: [Int64: PhotoCapture] = [:]
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    private var stopRequested = false
    private var closed = false
    private var observations: [NSObjectProtocol] = []
    private var readiness: NSKeyValueObservation?
    private var controlsDelegateStorage: NSObject?

    init() {
        let channel = AsyncStream<Event>.makeStream(bufferingPolicy: .bufferingNewest(8))
        events = channel.stream
        sink = channel.continuation
    }
    struct Configuration: Sendable {
        let source: CameraPreviewSource
        let formats: [CameraFormat]
        let lenses: [CameraLens]
        let selectedLens: CameraLens
        let macro: Bool
        let highResolution: Bool
        let maximumMegapixels: Int
        let exposureBias: Double
        let exposureRange: ClosedRange<Double>
        let flashAvailable: Bool
    }
    func start() async throws -> Configuration {
        guard !closed else { throw CancellationError() }
        #if targetEnvironment(simulator)
            throw CameraFailure.unavailable
        #else
            let status = AVCaptureDevice.authorizationStatus(for: .video)
            var allowed = status == .authorized
            if status == .notDetermined {
                allowed = await AVCaptureDevice.requestAccess(for: .video)
            }
            guard !closed else { throw CancellationError() }
            guard allowed else { throw CameraFailure.denied }
            if source == nil { try configure() }
            stopRequested = false
            if !session.isRunning { session.startRunning() }
            guard session.isRunning, source != nil else { throw CameraFailure.configuration }
            publishReadiness()
            return try configuration()
        #endif
    }
    private func configuration() throws -> Configuration {
        guard let source, let activeLens, let device = devices[activeLens.id] else {
            throw CameraFailure.configuration
        }
        return Configuration(
            source: source, formats: CameraFormat.allCases.filter { formats[$0] != nil },
            lenses: lenses, selectedLens: activeLens, macro: macro, highResolution: highResolution,
            maximumMegapixels: Int(
                (Double(maximumDimensions().width) * Double(maximumDimensions().height) / 1_000_000)
                    .rounded()
            ), exposureBias: Double(device.exposureTargetBias),
            exposureRange: max(
                -3, Double(device.minExposureTargetBias))...min(
                    3, Double(device.maxExposureTargetBias)),
            flashAvailable: device.hasFlash && output.supportedFlashModes.contains(.on))
    }
    private static func focalLength35mm(for device: AVCaptureDevice) -> Int {
        if #available(iOS 26.0, *) {
            let nominal = device.nominalFocalLengthIn35mmFilm
            if nominal > 0, nominal.isFinite {
                return Int(nominal.rounded())
            }
        }
        let photoFormat =
            device.formats.last(where: \.isHighestPhotoQualitySupported) ?? device.activeFormat
        let fov = Double(photoFormat.videoFieldOfView)
        if fov > 1, fov < 175 {
            let dims = CMVideoFormatDescriptionGetDimensions(photoFormat.formatDescription)
            let w = Double(max(dims.width, 4)), h = Double(max(dims.height, 3))
            let halfHorizontal35mm = 0.5 * hypot(36.0, 24.0) * w / hypot(w, h)
            let millimeters = halfHorizontal35mm / tan(fov * .pi / 360.0)
            if millimeters.isFinite, millimeters >= 8, millimeters <= 600 {
                return Int(millimeters.rounded())
            }
        }
        switch device.deviceType {
        case .builtInUltraWideCamera: return 13
        case .builtInTelephotoCamera: return 52
        default: return 26
        }
    }
    private func configure() throws {
        // Keep rear sensors explicit for Bayer RAW. The system front-camera proxy follows
        // folding automatically on Duo; non-RAW lenses and devices fall back to HEIC/JPEG.
        let discovered = AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera,
            ],
            mediaType: .video, position: .unspecified
        ).devices.filter { !$0.isVirtualDevice || $0.position == .front }
        guard !discovered.isEmpty else { throw CameraFailure.unavailable }
        devices = Dictionary(uniqueKeysWithValues: discovered.map { ($0.uniqueID, $0) })
        let candidates = discovered.map {
            CameraLens(
                id: $0.uniqueID, millimeters: Self.focalLength35mm(for: $0),
                front: $0.position == .front,
                macro: $0.deviceType == .builtInUltraWideCamera
                    && $0.isFocusModeSupported(.continuousAutoFocus),
                primary: $0.deviceType == .builtInWideAngleCamera)
        }.sorted { $0.front == $1.front ? $0.millimeters < $1.millimeters : !$0.front }
        guard
            let selected = candidates.first(where: { !$0.front && $0.primary })
                ?? candidates.first(where: { !$0.front }) ?? candidates.first,
            let selectedDevice = devices[selected.id]
        else { throw CameraFailure.unavailable }
        // Attach only the initial active camera on startup instead of cycling every sensor.
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        for old in session.inputs { session.removeInput(old) }
        for old in session.outputs { session.removeOutput(old) }
        session.sessionPreset = .photo
        let selectedInput = try AVCaptureDeviceInput(device: selectedDevice)
        inputs[selected.id] = selectedInput
        guard session.canAddInput(selectedInput) else { throw CameraFailure.configuration }
        session.addInput(selectedInput)
        guard session.canAddOutput(output) else { throw CameraFailure.configuration }
        session.addOutput(output)
        if session.canAddOutput(video) {
            session.addOutput(video)
            video.alwaysDiscardsLateVideoFrames = true
            video.automaticallyConfiguresOutputBufferDimensions = false
            video.deliversPreviewSizedOutputBuffers = true
        }
        lenses = candidates
        try configureOutput(device: selectedDevice, macro: false)
        activeLens = selected
        observeSession()
    }
    private func configureOutput(device: AVCaptureDevice, macro: Bool) throws {
        try device.lockForConfiguration()
        device.videoZoomFactor = 1
        if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        }
        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }
        if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
            device.whiteBalanceMode = .continuousAutoWhiteBalance
        }
        if device.isAutoFocusRangeRestrictionSupported {
            device.autoFocusRangeRestriction = macro ? .near : .none
        }
        device.unlockForConfiguration()
        output.maxPhotoQualityPrioritization = .quality
        let supportsProRAW = output.isAppleProRAWSupported
        if output.isAppleProRAWEnabled != supportsProRAW {
            output.isAppleProRAWEnabled = supportsProRAW
        }
        let dimensions = device.activeFormat.supportedMaxPhotoDimensions.sorted(by: {
            Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height)
        })
        if let selected = highResolution ? dimensions.last : dimensions.first,
            output.maxPhotoDimensions.width != selected.width
                || output.maxPhotoDimensions.height != selected.height
        {
            output.maxPhotoDimensions = selected
        }
        formats = availableFormats()
        guard !formats.isEmpty else { throw CameraFailure.configuration }
        if preferredFormat == nil {
            preferredFormat = CameraFormat.allCases.first { formats[$0] != nil }
        }
        // Enable ZSL and responsive capture after maxPhotoDimensions/ProRAW settle so AVFoundation
        // does not reset them during output format reconfiguration.
        if output.isZeroShutterLagSupported { output.isZeroShutterLagEnabled = true }
        if output.isResponsiveCaptureSupported { output.isResponsiveCaptureEnabled = true }
        if output.isFastCapturePrioritizationSupported {
            output.isFastCapturePrioritizationEnabled = true
        }
        configureControls(device: device)
        let deviceChanged = sourceDeviceID != device.uniqueID || source == nil
        if session.outputs.contains(video) {
            guard
                let type = [
                    kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                ].first(where: { video.availableVideoPixelFormatTypes.contains($0) })
            else {
                video.setSampleBufferDelegate(nil, queue: nil)
                meter = nil
                if deviceChanged {
                    source = CameraPreviewSource(session: session, device: device)
                    sourceDeviceID = device.uniqueID
                }
                prepareCapture(deviceID: device.uniqueID, format: preferredFormat, flash: preparedFlash, force: true)
                return
            }
            if (video.videoSettings[kCVPixelBufferPixelFormatTypeKey as String] as? OSType) != type
            {
                video.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: type]
            }
            if deviceChanged || meter == nil {
                let sink = sink
                let nextMeter = CameraMeter(device: device) { sink.yield(.readings($0)) }
                meter = nextMeter
                video.setSampleBufferDelegate(nextMeter, queue: meterQueue)
            }
        }
        if deviceChanged {
            source = CameraPreviewSource(session: session, device: device)
            sourceDeviceID = device.uniqueID
        }
        prepareCapture(deviceID: device.uniqueID, format: preferredFormat, flash: preparedFlash, force: true)
        Log.camera.debug(
            "Photo size: \(self.output.maxPhotoDimensions.width)×\(self.output.maxPhotoDimensions.height)")
    }
    /// Query only after attaching a video input and the photo output to the session.
    private func availableFormats() -> [CameraFormat: FormatSpec] {
        var result: [CameraFormat: FormatSpec] = [:]
        // Keep the first matching entry; AVFoundation orders preferred pixel formats first.
        for value in output.availableRawPhotoPixelFormatTypes {
            if result[.proRAW] == nil, AVCapturePhotoOutput.isAppleProRAWPixelFormat(value) {
                result[.proRAW] = .raw(value)
            }
            if result[.bayerRAW] == nil, AVCapturePhotoOutput.isBayerRAWPixelFormat(value) {
                result[.bayerRAW] = .raw(value)
            }
        }
        let fileTypes = output.availablePhotoFileTypes
        if fileTypes.contains(.heic), output.supportedPhotoCodecTypes(for: .heic).contains(.hevc) {
            result[.heic] = .processed(.hevc, .heic)
        } else if fileTypes.contains(.jpg), output.supportedPhotoCodecTypes(for: .jpg).contains(.jpeg) {
            result[.jpeg] = .processed(.jpeg, .jpg)
        } else if output.availablePhotoCodecTypes.contains(.jpeg) {
            result[.jpeg] = .processed(.jpeg, nil)
        }
        return result
    }
    /// Camera Control: a light press and slide adjusts exposure for the active lens.
    private func configureControls(device: AVCaptureDevice) {
        guard #available(iOS 18.0, *) else { return }
        guard session.supportsControls else { return }
        for control in session.controls { session.removeControl(control) }
        let exposure = AVCaptureSystemExposureBiasSlider(device: device)
        if session.canAddControl(exposure) { session.addControl(exposure) }
        let delegate = (controlsDelegateStorage as? CameraControlsDelegate) ?? CameraControlsDelegate()
        controlsDelegateStorage = delegate
        session.setControlsDelegate(delegate, queue: meterQueue)
    }
    private func maximumDimensions() -> CMVideoDimensions {
        (session.inputs.first as? AVCaptureDeviceInput)?.device.activeFormat
            .supportedMaxPhotoDimensions.max {
                Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height)
            } ?? output.maxPhotoDimensions
    }
    private var isReadyToCapture: Bool {
        !closed && !stopRequested && captures.count < Self.maxInFlightCaptures
            && output.captureReadiness == .ready
    }
    private func publishReadiness() {
        sink.yield(.ready(isReadyToCapture))
    }
    private func resolvedFormat(_ requested: CameraFormat?) -> CameraFormat? {
        if let requested, formats[requested] != nil { return requested }
        return CameraFormat.allCases.first { formats[$0] != nil }
    }
    private func photoSettings(format: CameraFormat, flash: Bool = false) throws -> AVCapturePhotoSettings {
        guard let spec = formats[format] else {
            throw format.isRAW ? CameraFailure.rawUnavailable : CameraFailure.configuration
        }
        let settings: AVCapturePhotoSettings
        switch spec {
        case .raw(let pixelFormat):
            let rawFileType: AVFileType? =
                output.availableRawPhotoFileTypes.contains(.dng) ? .dng : nil
            settings = AVCapturePhotoSettings(
                rawPixelFormatType: pixelFormat, rawFileType: rawFileType,
                processedFormat: nil, processedFileType: nil)
            if #available(iOS 18.0, *), format == .proRAW, rawFileType == .dng,
                output.availableRawPhotoCodecTypes.contains(.JPEGXL)
            {
                let rawCodecs = output.supportedRawPhotoCodecTypes(
                    forRawPhotoPixelFormatType: pixelFormat, fileType: .dng)
                if rawCodecs.contains(.JPEGXL) {
                    // Lossless JPEG-XL ProRAW halves file size and write time with identical pixels.
                    settings.rawFileFormat = [
                        AVVideoCodecKey: AVVideoCodecType.JPEGXL,
                        AVVideoQualityKey: 1.0,
                    ]
                }
            }
            if let codec = settings.availableRawEmbeddedThumbnailPhotoCodecTypes.first {
                let size = output.maxPhotoDimensions
                let scale = min(1, 1080.0 / Double(max(size.width, size.height)))
                settings.rawEmbeddedThumbnailPhotoFormat = [
                    AVVideoCodecKey: codec,
                    AVVideoWidthKey: max(2, Int(Double(size.width) * scale) & ~1),
                    AVVideoHeightKey: max(2, Int(Double(size.height) * scale) & ~1),
                ]
            }
        case .processed(let codec, let fileType):
            settings = AVCapturePhotoSettings(
                rawPixelFormatType: 0, rawFileType: nil,
                processedFormat: [AVVideoCodecKey: codec], processedFileType: fileType)
        }
        settings.maxPhotoDimensions = output.maxPhotoDimensions
        let desired: AVCapturePhotoOutput.QualityPrioritization =
            format == .bayerRAW ? .speed : (highResolution ? .quality : .balanced)
        settings.photoQualityPrioritization =
            desired.rawValue <= output.maxPhotoQualityPrioritization.rawValue
            ? desired : output.maxPhotoQualityPrioritization
        if flash, output.supportedFlashModes.contains(.on) { settings.flashMode = .on }
        return settings
    }
    func prepare(format: CameraFormat, flash: Bool) {
        preferredFormat = format
        preparedFlash = flash
        guard !closed, let device = (session.inputs.first as? AVCaptureDeviceInput)?.device else {
            return
        }
        prepareCapture(deviceID: device.uniqueID, format: format, flash: flash, force: false)
    }
    private func prepareCapture(
        deviceID: String, format: CameraFormat?, flash: Bool, force: Bool
    ) {
        guard let active = resolvedFormat(format) else { return }
        let key = PreparedKey(
            deviceID: deviceID, format: active, flash: flash, highResolution: highResolution)
        guard force || preparedKey != key,
            let settings = try? photoSettings(format: active, flash: flash)
        else { return }
        preparedKey = key
        output.setPreparedPhotoSettingsArray([settings], completionHandler: nil)
    }
    private func waitForCaptures() async {
        guard !captures.isEmpty else { return }
        await withCheckedContinuation { drainWaiters.append($0) }
    }
    func setHighResolution(_ enabled: Bool) async throws -> Configuration {
        await waitForCaptures()
        guard !closed, !stopRequested,
            let device = (session.inputs.first as? AVCaptureDeviceInput)?.device
        else {
            throw CameraFailure.notReady
        }
        highResolution = enabled
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        try configureOutput(device: device, macro: macro)
        return try configuration()
    }
    func selectLens(_ id: String, macro: Bool = false) async throws -> Configuration {
        await waitForCaptures()
        guard !closed, !stopRequested, let device = devices[id],
            let lens = lenses.first(where: { $0.id == id }),
            let previous = session.inputs.first as? AVCaptureDeviceInput
        else { throw CameraFailure.notReady }
        let started = ProcessInfo.processInfo.systemUptime
        // Macro on the current ultra-wide lens changes only its focus range.
        if previous.device.uniqueID == id {
            try device.lockForConfiguration()
            if device.isAutoFocusRangeRestrictionSupported {
                device.autoFocusRangeRestriction = macro && lens.macro ? .near : .none
            }
            device.unlockForConfiguration()
            self.macro = macro && lens.macro
            return try configuration()
        }
        let input = try inputs[id] ?? AVCaptureDeviceInput(device: device)
        inputs[id] = input
        session.beginConfiguration()
        defer {
            session.commitConfiguration()
            Log.camera.debug(
                "Lens \(lens.millimeters): \(ProcessInfo.processInfo.systemUptime - started) s")
        }
        session.removeInput(previous)
        do {
            guard session.canAddInput(input) else { throw CameraFailure.configuration }
            session.addInput(input)
            try configureOutput(device: device, macro: macro && lens.macro)
            activeLens = lens
            self.macro = macro && lens.macro
        } catch {
            lenses.removeAll { $0.id == id }
            if session.inputs.contains(input) { session.removeInput(input) }
            if session.canAddInput(previous) { session.addInput(previous) }
            try? configureOutput(device: previous.device, macro: self.macro)
            throw error
        }
        return try configuration()
    }
    func focus(at point: CGPoint) throws {
        guard session.isRunning, !session.isInterrupted,
            let device = (session.inputs.first as? AVCaptureDeviceInput)?.device,
            point.x.isFinite, point.y.isFinite
        else { throw CameraFailure.notReady }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        let point = CGPoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1))
        if device.isFocusPointOfInterestSupported {
            device.focusPointOfInterest = point
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
        }
        if device.isExposurePointOfInterestSupported {
            device.exposurePointOfInterest = point
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
        }
    }
    func setExposureBias(_ value: Double) throws {
        guard !closed, session.isRunning, value.isFinite,
            let device = (session.inputs.first as? AVCaptureDeviceInput)?.device
        else { throw CameraFailure.notReady }
        let bias = min(
            max(Float(value), device.minExposureTargetBias), device.maxExposureTargetBias)
        guard abs(bias - device.exposureTargetBias) >= 0.01 else { return }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.setExposureTargetBias(bias, completionHandler: nil)
    }
    private func observeSession() {
        guard observations.isEmpty else { return }
        let sink = sink
        let center = NotificationCenter.default
        observations = [
            center.addObserver(
                forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil
            ) { note in
                let code =
                    (note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? NSNumber)?.intValue
                    ?? 0
                Log.camera.info("Interrupted: \(code)")
                let message: String
                switch AVCaptureSession.InterruptionReason(rawValue: code) {
                case .videoDeviceInUseByAnotherClient:
                    message = String(
                        localized: "camera.interrupted.in_use",
                        defaultValue: "Another app is using the camera.")
                case .videoDeviceNotAvailableWithMultipleForegroundApps:
                    message =
                        String(
                            localized: "camera.interrupted.multitasking",
                            defaultValue:
                                "iOS paused camera access while another view is active. Stop screen sharing to resume."
                        )
                case .videoDeviceNotAvailableDueToSystemPressure:
                    message = String(
                        localized: "camera.interrupted.system_pressure",
                        defaultValue: "iOS paused the camera to reduce system load.")
                default:
                    message = String(
                        localized: "camera.interrupted.generic",
                        defaultValue: "The camera will resume when it is available.")
                }
                sink.yield(.interrupted(message))
            },
            center.addObserver(
                forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil
            ) { _ in
                sink.yield(.resumed)
            },
            center.addObserver(
                forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil
            ) { note in
                let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
                sink.yield(
                    .failed(
                        error?.localizedDescription
                            ?? String(
                                localized: "camera.error.stopped",
                                defaultValue: "The camera stopped. Try again.")))
            },
        ]
        readiness = output.observe(\.captureReadiness, options: [.initial, .new]) { [weak self] _, _ in
            Task { await self?.publishReadiness() }
        }
    }
    func stop() {
        stopRequested = true
        if captures.isEmpty && session.isRunning { session.stopRunning() }
        publishReadiness()
    }
    func shutdown() async {
        closed = true
        stopRequested = true
        await waitForCaptures()
        if session.isRunning { session.stopRunning() }
        observations.forEach(NotificationCenter.default.removeObserver)
        observations.removeAll()
        readiness = nil
        video.setSampleBufferDelegate(nil, queue: nil)
        meter = nil
        sink.finish()
    }
    private func finishCapture(
        id: Int64, result: Result<URL, Error>,
        onStored: @escaping @MainActor @Sendable (Result<URL, Error>) -> Void
    ) async {
        captures.removeValue(forKey: id)
        if captures.isEmpty {
            let waiters = drainWaiters
            drainWaiters.removeAll()
            waiters.forEach { $0.resume() }
            if stopRequested && session.isRunning { session.stopRunning() }
        }
        publishReadiness()
        await onStored(result)
    }
    /// Returns as soon as sensor exposure completes so the shutter unlocks immediately;
    /// `onStored` runs asynchronously once ISP processing and disk writing finish.
    func takePhoto(
        format: CameraFormat, rotation: CGFloat, inbox: CameraInbox, location: CaptureLocation?,
        flash: Bool = false,
        onStored: @escaping @MainActor @Sendable (Result<URL, Error>) -> Void
    )
        async throws -> Bool
    {
        guard !closed, !stopRequested, session.isRunning, !session.isInterrupted,
            captures.count < Self.maxInFlightCaptures, output.captureReadiness == .ready
        else { throw CameraFailure.notReady }
        preferredFormat = format
        preparedFlash = flash
        let settings = try photoSettings(format: format, flash: flash)
        guard let connection = output.connection(with: .video) else { throw CameraFailure.notReady }
        let angle =
            connection.isVideoRotationAngleSupported(rotation)
            ? rotation : (rotation / 90).rounded() * 90
        guard connection.isVideoRotationAngleSupported(angle) else {
            throw CameraFailure.configuration
        }
        connection.videoRotationAngle = angle
        let id = settings.uniqueID
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let delegate = PhotoCapture(
                id: id, expectsRAW: format.isRAW, fileExtension: format.fileExtension,
                inbox: inbox, location: location, writeQueue: writeQueue,
                exposureContinuation: continuation
            ) { [weak self] captureID, outcome in
                guard let self else {
                    Task { @MainActor in onStored(outcome) }
                    return
                }
                Task { await self.finishCapture(id: captureID, result: outcome, onStored: onStored) }
            }
            captures[id] = delegate
            publishReadiness()
            output.capturePhoto(with: settings, delegate: delegate)
        }
        publishReadiness()
        return isReadyToCapture
    }
}

/// The system needs a delegate before it shows Camera Control overlays; nothing to do here.
@available(iOS 18.0, *)
nonisolated private final class CameraControlsDelegate: NSObject, AVCaptureSessionControlsDelegate {
    func sessionControlsDidBecomeActive(_ session: AVCaptureSession) {}
    func sessionControlsWillEnterFullscreenAppearance(_ session: AVCaptureSession) {}
    func sessionControlsWillExitFullscreenAppearance(_ session: AVCaptureSession) {}
    func sessionControlsDidBecomeInactive(_ session: AVCaptureSession) {}
}

/// AVFoundation serializes the callbacks for one capture request; disk writes run on `writeQueue`.
nonisolated private final class PhotoCapture: NSObject, AVCapturePhotoCaptureDelegate,
    AVCapturePhotoFileDataRepresentationCustomizer, @unchecked Sendable
{
    private let id: Int64
    private let expectsRAW: Bool
    private let fileExtension: String
    private let inbox: CameraInbox
    private let location: CaptureLocation?
    private let writeQueue: DispatchQueue
    private var exposureContinuation: CheckedContinuation<Void, Error>?
    private let onComplete: @Sendable (Int64, Result<URL, Error>) -> Void
    private var writeResult: Result<URL, Error>?
    private let started = ProcessInfo.processInfo.systemUptime

    init(
        id: Int64, expectsRAW: Bool, fileExtension: String, inbox: CameraInbox,
        location: CaptureLocation?, writeQueue: DispatchQueue,
        exposureContinuation: CheckedContinuation<Void, Error>,
        onComplete: @escaping @Sendable (Int64, Result<URL, Error>) -> Void
    ) {
        self.id = id
        self.expectsRAW = expectsRAW
        self.fileExtension = fileExtension
        self.inbox = inbox
        self.location = location
        self.writeQueue = writeQueue
        self.exposureContinuation = exposureContinuation
        self.onComplete = onComplete
    }

    func replacementMetadata(for photo: AVCapturePhoto) -> [String: Any]? {
        var metadata = photo.metadata
        if let location { metadata[kCGImagePropertyGPSDictionary as String] = location.gps }
        return metadata
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings
    ) {
        if let continuation = exposureContinuation {
            exposureContinuation = nil
            continuation.resume()
        }
        Log.camera.debug(
            "Exposure complete (\(self.fileExtension)): \(ProcessInfo.processInfo.systemUptime - self.started) s")
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if let error {
            writeResult = .failure(error)
            return
        }
        if expectsRAW && !photo.isRawPhoto { return }
        guard
            let data = location == nil
                ? photo.fileDataRepresentation() : photo.fileDataRepresentation(with: self)
        else {
            writeResult = .failure(expectsRAW ? CameraFailure.noData : CameraFailure.noPhotoData)
            return
        }
        let inbox = inbox
        let ext = fileExtension
        let started = started
        let dimensions =
            photo.isRawPhoto
            ? photo.resolvedSettings.rawPhotoDimensions : photo.resolvedSettings.photoDimensions
        writeQueue.async {
            let outcome = Result { try inbox.store(data, fileExtension: ext) }
            self.writeResult = outcome
            Log.camera.debug(
                "Capture \(ext.uppercased()) \(dimensions.width)×\(dimensions.height) saved: \(ProcessInfo.processInfo.systemUptime - started) s"
            )
        }
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
        error: Error?
    ) {
        if let continuation = exposureContinuation {
            exposureContinuation = nil
            if let error {
                continuation.resume(throwing: error)
                onComplete(id, .failure(error))
                return
            }
            continuation.resume()
        }
        let id = id
        let fallbackError: Error = error ?? (expectsRAW ? CameraFailure.noData : CameraFailure.noPhotoData)
        let onComplete = onComplete
        writeQueue.async {
            if let error {
                onComplete(id, .failure(error))
            } else {
                onComplete(id, self.writeResult ?? .failure(fallbackError))
            }
        }
    }
}
