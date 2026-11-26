@preconcurrency import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import ImageIO
import OSLog
import UniformTypeIdentifiers

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
    func badge(
        megapixels: Int, highResolution: Bool, maximumMegapixels: Int, standardMegapixels: Int = 12
    ) -> String {
        switch self {
        case .proRAW:
            "PRO \(megapixels)"
        case .bayerRAW:
            "RAW"
        case .heic:
            highResolution && maximumMegapixels > standardMegapixels ? "HEIC \(megapixels)" : "HEIC"
        case .jpeg:
            highResolution && maximumMegapixels > standardMegapixels ? "JPEG \(megapixels)" : "JPEG"
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
        case inFlight(count: Int, max: Int)
        case interrupted(String)
        case resumed
        case failed(String)
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
    static var maxInFlightCaptures: Int {
        #if os(iOS) && !targetEnvironment(simulator)
            return ProcessInfo.processInfo.physicalMemory < 4_500_000_000 ? 2 : 3
        #else
            return 3
        #endif
    }
    nonisolated let events: AsyncStream<Event>
    nonisolated let readingsStream: AsyncStream<CameraReadings>
    private let sink: AsyncStream<Event>.Continuation
    private let readingsSink: AsyncStream<CameraReadings>.Continuation
    private var session = AVCaptureSession()
    private var output = AVCapturePhotoOutput()
    private var video = AVCaptureVideoDataOutput()
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
    private var readinessBridge: CameraReadinessBridge?
    private var sourceDeviceID: String?
    private var formats: [CameraFormat: FormatSpec] = [:]
    private var preferredFormat: CameraFormat?
    private var preparedFlash = false
    private var preparedKey: PreparedKey?
    private var captures: [Int64: PhotoCapture] = [:]
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    private var stopRequested = false
    private var closed = false
    private var interruptionReason: String?
    private var observations: [NSObjectProtocol] = []
    private var readiness: NSKeyValueObservation?
    private var controlsDelegateStorage: NSObject?

    init() {
        // Lifecycle and readiness state transitions must never be evicted by 5 Hz meter samples.
        let channel = AsyncStream<Event>.makeStream(bufferingPolicy: .unbounded)
        events = channel.stream
        sink = channel.continuation
        let meterChannel = AsyncStream<CameraReadings>.makeStream(bufferingPolicy: .bufferingNewest(1))
        readingsStream = meterChannel.stream
        readingsSink = meterChannel.continuation
    }
    nonisolated struct CaptureToken: Equatable, Hashable, Sendable {
        let id: UUID
        let sequence: UInt64
        let format: CameraFormat
        let highResolution: Bool
        let standardMegapixels: Int
        let flash: Bool
    }
    struct CaptureStoredResult: @unchecked Sendable {
        let token: CaptureToken
        let url: URL
        let requestedDimensions: CMVideoDimensions
        let resolvedDimensions: CMVideoDimensions
        let deliveredWidth: Int
        let deliveredHeight: Int
        let thumbnail: CGImage?
        let exposureMs: Double
        let serializationMs: Double
        let writeMs: Double
    }
    struct Configuration: Sendable {
        let source: CameraPreviewSource
        let readinessBridge: CameraReadinessBridge
        let outputReady: Bool
        let interrupted: Bool
        let interruptionReason: String?
        let formats: [CameraFormat]
        let lenses: [CameraLens]
        let selectedLens: CameraLens
        let macro: Bool
        let highResolution: Bool
        let standardMegapixels: Int
        let maximumMegapixels: Int
        let exposureBias: Double
        let exposureRange: ClosedRange<Double>
        let flashAvailable: Bool
    }
    nonisolated static func nominalMegapixels(_ dimensions: CMVideoDimensions) -> Int {
        let pixels = Int64(dimensions.width) * Int64(dimensions.height)
        switch pixels {
        case 45_000_000...52_000_000: return 48
        case 21_000_000...27_000_000: return 24
        case 10_000_000...14_000_000: return 12
        default: return max(1, Int((Double(pixels) / 1_000_000).rounded()))
        }
    }
    nonisolated static func deliveredDimensions(
        isRAW: Bool,
        pixelBufferDimensions: CMVideoDimensions,
        resolvedDimensions: CMVideoDimensions,
        encodedHeaderDimensions: (width: Int, height: Int)
    ) -> (width: Int, height: Int) {
        if isRAW {
            if pixelBufferDimensions.width > 0 && pixelBufferDimensions.height > 0 {
                return (Int(pixelBufferDimensions.width), Int(pixelBufferDimensions.height))
            }
            if resolvedDimensions.width > 0 && resolvedDimensions.height > 0 {
                return (Int(resolvedDimensions.width), Int(resolvedDimensions.height))
            }
            return (0, 0)
        }
        if encodedHeaderDimensions.width > 0 && encodedHeaderDimensions.height > 0 {
            return encodedHeaderDimensions
        }
        return (Int(resolvedDimensions.width), Int(resolvedDimensions.height))
    }
    nonisolated static func selectableDimensions(from supported: [CMVideoDimensions]) -> [CMVideoDimensions] {
        let sorted = supported.sorted {
            Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height)
        }
        guard !sorted.isEmpty else { return [] }
        let hasStandard = sorted.contains {
            (10_000_000...14_000_000).contains(Int64($0.width) * Int64($0.height))
        }
        // Without isAutoDeferredPhotoDeliveryEnabled, 24 MP (5712x4284) cannot be delivered
        // reliably alongside a 12 MP base tier; keep genuinely immediate tiers (e.g. 12 MP & 48 MP).
        let filtered = sorted.filter { dims in
            let px = Int64(dims.width) * Int64(dims.height)
            return !(hasStandard && (21_000_000...27_000_000).contains(px))
        }
        return filtered.isEmpty ? sorted : filtered
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
        let bridge = readinessBridge ?? CameraReadinessBridge(output: output)
        readinessBridge = bridge
        let selectable = Self.selectableDimensions(
            from: device.activeFormat.supportedMaxPhotoDimensions)
        let standardDims = selectable.first ?? output.maxPhotoDimensions
        let maximumDims = selectable.last ?? maximumDimensions()
        let interrupted = session.isInterrupted
        if !interrupted { interruptionReason = nil }
        return Configuration(
            source: source, readinessBridge: bridge, outputReady: isReadyToCapture,
            interrupted: interrupted,
            interruptionReason: interrupted
                ? (interruptionReason
                    ?? String(
                        localized: "camera.interrupted.generic",
                        defaultValue: "The camera will resume when it is available."))
                : nil,
            formats: CameraFormat.allCases.filter { formats[$0] != nil },
            lenses: lenses, selectedLens: activeLens, macro: macro, highResolution: highResolution,
            standardMegapixels: Self.nominalMegapixels(standardDims),
            maximumMegapixels: Self.nominalMegapixels(maximumDims),
            exposureBias: Double(device.exposureTargetBias),
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
        do {
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
            session.commitConfiguration()
        } catch {
            session.commitConfiguration()
            throw error
        }
        prepareCapture(deviceID: selectedDevice.uniqueID, format: preferredFormat, flash: preparedFlash, force: true)
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
        let dimensions = Self.selectableDimensions(
            from: device.activeFormat.supportedMaxPhotoDimensions)
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
        // does not reset them during output format reconfiguration. Keep fast capture prioritization
        // off in high-resolution mode so AVFoundation never bins 48 MP requests down for burst speed.
        if output.isZeroShutterLagSupported { output.isZeroShutterLagEnabled = true }
        if output.isResponsiveCaptureSupported { output.isResponsiveCaptureEnabled = true }
        if output.isFastCapturePrioritizationSupported {
            output.isFastCapturePrioritizationEnabled = !highResolution
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
                return
            }
            if (video.videoSettings[kCVPixelBufferPixelFormatTypeKey as String] as? OSType) != type
            {
                video.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: type]
            }
            if deviceChanged || meter == nil {
                let readingsSink = readingsSink
                let nextMeter = CameraMeter(device: device) { readingsSink.yield($0) }
                meter = nextMeter
                video.setSampleBufferDelegate(nextMeter, queue: meterQueue)
            }
        }
        if deviceChanged {
            source = CameraPreviewSource(session: session, device: device)
            sourceDeviceID = device.uniqueID
        }
        Log.camera.debug(
            "Photo size: \(self.output.maxPhotoDimensions.width)×\(self.output.maxPhotoDimensions.height)")
    }
    /// Query only after attaching a video input and the photo output to the session.
    private func availableFormats() -> [CameraFormat: FormatSpec] {
        var result: [CameraFormat: FormatSpec] = [:]
        if output.availableRawPhotoFileTypes.contains(.dng) {
            let dngRawTypes = Set(output.supportedRawPhotoPixelFormatTypes(for: .dng))
            // Keep the first matching entry; AVFoundation orders preferred pixel formats first.
            for value in output.availableRawPhotoPixelFormatTypes where dngRawTypes.contains(value) {
                if result[.proRAW] == nil, AVCapturePhotoOutput.isAppleProRAWPixelFormat(value) {
                    result[.proRAW] = .raw(value)
                }
                if result[.bayerRAW] == nil, AVCapturePhotoOutput.isBayerRAWPixelFormat(value) {
                    result[.bayerRAW] = .raw(value)
                }
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
        sink.yield(.inFlight(count: captures.count, max: Self.maxInFlightCaptures))
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
        if let previewFormat = settings.availablePreviewPhotoPixelFormatTypes.first {
            let size = output.maxPhotoDimensions
            let scale = min(1, 384.0 / Double(max(size.width, size.height, 1)))
            settings.previewPhotoFormat = [
                kCVPixelBufferPixelFormatTypeKey as String: previewFormat,
                kCVPixelBufferWidthKey as String: max(2, Int(Double(size.width) * scale) & ~1),
                kCVPixelBufferHeightKey as String: max(2, Int(Double(size.height) * scale) & ~1),
            ]
        }
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
        do {
            try configureOutput(device: device, macro: macro)
            session.commitConfiguration()
        } catch {
            session.commitConfiguration()
            throw error
        }
        prepareCapture(deviceID: device.uniqueID, format: preferredFormat, flash: preparedFlash, force: true)
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
        let previousMacro = self.macro
        let input: AVCaptureDeviceInput
        do {
            input = try inputs[id] ?? AVCaptureDeviceInput(device: device)
            inputs[id] = input
        } catch {
            throw error
        }
        session.beginConfiguration()
        session.removeInput(previous)
        do {
            guard session.canAddInput(input) else { throw CameraFailure.configuration }
            session.addInput(input)
            try configureOutput(device: device, macro: macro && lens.macro)
            activeLens = lens
            self.macro = macro && lens.macro
            session.commitConfiguration()
        } catch {
            if session.inputs.contains(input) { session.removeInput(input) }
            if !session.inputs.contains(previous), session.canAddInput(previous) {
                session.addInput(previous)
            }
            self.macro = previousMacro
            try? configureOutput(device: previous.device, macro: previousMacro)
            session.commitConfiguration()
            Log.camera.debug(
                "Lens \(lens.millimeters): \(ProcessInfo.processInfo.systemUptime - started) s")
            throw error
        }
        Log.camera.debug(
            "Lens \(lens.millimeters): \(ProcessInfo.processInfo.systemUptime - started) s")
        prepareCapture(deviceID: device.uniqueID, format: preferredFormat, flash: preparedFlash, force: true)
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
        let center = NotificationCenter.default
        observations = [
            center.addObserver(
                forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil
            ) { [weak self] note in
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
                Task { await self?.recordInterruption(message) }
            },
            center.addObserver(
                forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil
            ) { [weak self] _ in
                Task { await self?.recordInterruptionEnded() }
            },
            center.addObserver(
                forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil
            ) { [weak self] note in
                let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
                Task { await self?.handleRuntimeFailure(error) }
            },
            center.addObserver(
                forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil
            ) { [weak self] _ in
                Task { await self?.handleMediaServicesReset() }
            },
        ]
        readiness = output.observe(\.captureReadiness, options: [.initial, .new]) { [weak self] _, _ in
            Task { await self?.publishReadiness() }
        }
    }
    private func recordInterruption(_ message: String) {
        interruptionReason = message
        sink.yield(.interrupted(message))
    }
    private func recordInterruptionEnded() {
        interruptionReason = nil
        sink.yield(.resumed)
    }
    private func abortAllCaptures(error: Error) {
        let pending = Array(captures.values)
        guard !pending.isEmpty else { return }
        captures.removeAll()
        meter?.disarmAll()
        let waiters = drainWaiters
        drainWaiters.removeAll()
        waiters.forEach { $0.resume() }
        for capture in pending {
            capture.abortForSessionFailure(error)
        }
        publishReadiness()
    }
    private func handleRuntimeFailure(_ error: Error?) {
        if (error as? AVError)?.code == .mediaServicesWereReset {
            handleMediaServicesReset()
            return
        }
        if !session.isRunning {
            abortAllCaptures(error: error ?? CameraFailure.notReady)
        }
        sink.yield(
            .failed(
                error?.localizedDescription
                    ?? String(
                        localized: "camera.error.stopped",
                        defaultValue: "The camera stopped. Try again.")))
    }
    private func handleMediaServicesReset() {
        Log.camera.error("Media services were reset; rebuilding capture session")
        abortAllCaptures(error: CameraFailure.notReady)
        observations.forEach(NotificationCenter.default.removeObserver)
        observations.removeAll()
        readiness = nil
        readinessBridge = nil
        controlsDelegateStorage = nil
        video.setSampleBufferDelegate(nil, queue: nil)
        meter = nil
        source = nil
        sourceDeviceID = nil
        devices.removeAll()
        inputs.removeAll()
        formats.removeAll()
        activeLens = nil
        preparedKey = nil
        interruptionReason = nil
        session = AVCaptureSession()
        output = AVCapturePhotoOutput()
        video = AVCaptureVideoDataOutput()
        sink.yield(.resumed)
    }
    func stop() {
        stopRequested = true
        if captures.isEmpty {
            meter?.disarmAll()
            if session.isRunning { session.stopRunning() }
        }
        publishReadiness()
    }
    func shutdown() async {
        closed = true
        stopRequested = true
        await waitForCaptures()
        meter?.disarmAll()
        if session.isRunning { session.stopRunning() }
        observations.forEach(NotificationCenter.default.removeObserver)
        observations.removeAll()
        readiness = nil
        readinessBridge = nil
        video.setSampleBufferDelegate(nil, queue: nil)
        meter = nil
        readingsSink.finish()
        sink.finish()
    }
    private func removeCapture(id: Int64) {
        captures.removeValue(forKey: id)
        if captures.isEmpty {
            meter?.disarmAll()
            let waiters = drainWaiters
            drainWaiters.removeAll()
            waiters.forEach { $0.resume() }
            if stopRequested && session.isRunning { session.stopRunning() }
        }
        publishReadiness()
    }
    private func finishCapture(
        id: Int64, result: Result<CaptureStoredResult, Error>,
        onStored: @escaping @MainActor @Sendable (Result<CaptureStoredResult, Error>) -> Void
    ) async {
        removeCapture(id: id)
        await onStored(result)
    }
    /// Returns as soon as sensor exposure completes so the shutter unlocks immediately;
    /// `onStored` runs asynchronously once ISP processing and disk writing finish.
    func takePhoto(
        token: CaptureToken, rotation: CGFloat, inbox: CameraInbox, location: CaptureLocation?,
        flash: Bool = false,
        onExposure: @escaping @MainActor @Sendable (CaptureToken, CGImage?) -> Void,
        onStillPreview: @escaping @MainActor @Sendable (CaptureToken, CGImage) -> Void,
        onStored: @escaping @MainActor @Sendable (Result<CaptureStoredResult, Error>) -> Void
    )
        async throws -> Bool
    {
        guard !closed, !stopRequested, session.isRunning, !session.isInterrupted,
            captures.count < Self.maxInFlightCaptures, output.captureReadiness == .ready
        else { throw CameraFailure.notReady }
        preferredFormat = token.format
        preparedFlash = flash
        let settings = try photoSettings(format: token.format, flash: flash)
        guard let connection = output.connection(with: .video) else { throw CameraFailure.notReady }
        let angle =
            connection.isVideoRotationAngleSupported(rotation)
            ? rotation : (rotation / 90).rounded() * 90
        guard connection.isVideoRotationAngleSupported(angle) else {
            throw CameraFailure.configuration
        }
        connection.videoRotationAngle = angle
        let targetMirrored = connection.isVideoMirrored
        let id = settings.uniqueID
        let requestedDimensions = settings.maxPhotoDimensions
        let currentMeter = meter
        currentMeter?.armSnapshot()
        let meterQueue = self.meterQueue
        let requestSnapshot: @Sendable (@escaping @Sendable (CGImage?) -> Void) -> Void = { deliver in
            guard let currentMeter else {
                deliver(nil)
                return
            }
            currentMeter.takeSnapshot(
                targetRotation: angle, targetMirrored: targetMirrored, on: meterQueue,
                completion: deliver)
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let delegate = PhotoCapture(
                id: id, token: token, expectsRAW: token.format.isRAW,
                fileExtension: token.format.fileExtension,
                requestedDimensions: requestedDimensions,
                inbox: inbox, location: location, writeQueue: writeQueue,
                exposureContinuation: continuation,
                requestSnapshot: requestSnapshot,
                onExposure: onExposure,
                onStillPreview: onStillPreview,
                onAbort: { [weak self] captureID in
                    currentMeter?.disarmSnapshot()
                    Task { await self?.removeCapture(id: captureID) }
                }
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
    private static let previewContext = CIContext(options: [.cacheIntermediates: false])

    private let id: Int64
    private let token: CameraService.CaptureToken
    private let expectsRAW: Bool
    private let fileExtension: String
    private let requestedDimensions: CMVideoDimensions
    private let inbox: CameraInbox
    private let location: CaptureLocation?
    private let writeQueue: DispatchQueue
    private let lock = NSLock()
    private var completed = false
    private var exposureContinuation: CheckedContinuation<Void, Error>?
    private let requestSnapshot: @Sendable (@escaping @Sendable (CGImage?) -> Void) -> Void
    private let onExposure: @MainActor @Sendable (CameraService.CaptureToken, CGImage?) -> Void
    private let onStillPreview: @MainActor @Sendable (CameraService.CaptureToken, CGImage) -> Void
    private let onAbort: @Sendable (Int64) -> Void
    private let onComplete: @Sendable (Int64, Result<CameraService.CaptureStoredResult, Error>) -> Void
    private var writeResult: Result<CameraService.CaptureStoredResult, Error>?
    private var stillPreviewImage: CGImage?
    private let started = ProcessInfo.processInfo.systemUptime
    private var exposureMs = 0.0

    init(
        id: Int64, token: CameraService.CaptureToken, expectsRAW: Bool, fileExtension: String,
        requestedDimensions: CMVideoDimensions, inbox: CameraInbox, location: CaptureLocation?,
        writeQueue: DispatchQueue, exposureContinuation: CheckedContinuation<Void, Error>,
        requestSnapshot: @escaping @Sendable (@escaping @Sendable (CGImage?) -> Void) -> Void,
        onExposure: @escaping @MainActor @Sendable (CameraService.CaptureToken, CGImage?) -> Void,
        onStillPreview: @escaping @MainActor @Sendable (CameraService.CaptureToken, CGImage) -> Void,
        onAbort: @escaping @Sendable (Int64) -> Void,
        onComplete: @escaping @Sendable (Int64, Result<CameraService.CaptureStoredResult, Error>) -> Void
    ) {
        self.id = id
        self.token = token
        self.expectsRAW = expectsRAW
        self.fileExtension = fileExtension
        self.requestedDimensions = requestedDimensions
        self.inbox = inbox
        self.location = location
        self.writeQueue = writeQueue
        self.exposureContinuation = exposureContinuation
        self.requestSnapshot = requestSnapshot
        self.onExposure = onExposure
        self.onStillPreview = onStillPreview
        self.onAbort = onAbort
        self.onComplete = onComplete
    }

    func replacementMetadata(for photo: AVCapturePhoto) -> [String: Any]? {
        var metadata = photo.metadata
        if let location { metadata[kCGImagePropertyGPSDictionary as String] = location.gps }
        return metadata
    }

    func abortForSessionFailure(_ error: Error) {
        lock.lock()
        let continuation = exposureContinuation
        exposureContinuation = nil
        let alreadyCompleted = completed
        completed = true
        lock.unlock()
        if let continuation {
            continuation.resume(throwing: error)
            return
        }
        guard !alreadyCompleted else { return }
        let id = id
        let onComplete = onComplete
        writeQueue.async { onComplete(id, .failure(error)) }
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings
    ) {
        exposureMs = (ProcessInfo.processInfo.systemUptime - started) * 1000
        lock.lock()
        let continuation = exposureContinuation
        exposureContinuation = nil
        lock.unlock()
        continuation?.resume()
        let token = token
        let onExposure = onExposure
        Task { @MainActor in onExposure(token, nil) }
        requestSnapshot { snapshot in
            guard let snapshot else { return }
            Task { @MainActor in onExposure(token, snapshot) }
        }
        Log.camera.debug(
            "Exposure complete (\(self.fileExtension)): \(Int(self.exposureMs.rounded())) ms")
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
        if stillPreviewImage == nil, let preview = Self.orientedPreviewImage(from: photo) {
            stillPreviewImage = preview
            let token = token
            let onStillPreview = onStillPreview
            Task { @MainActor in onStillPreview(token, preview) }
        }
        let serializationStarted = ProcessInfo.processInfo.systemUptime
        guard
            let data = location == nil
                ? photo.fileDataRepresentation() : photo.fileDataRepresentation(with: self)
        else {
            writeResult = .failure(expectsRAW ? CameraFailure.noData : CameraFailure.noPhotoData)
            return
        }
        let serializationMs = (ProcessInfo.processInfo.systemUptime - serializationStarted) * 1000
        let token = token
        let inbox = inbox
        let ext = fileExtension
        let expectsRAW = expectsRAW
        let requested = requestedDimensions
        let resolved =
            photo.isRawPhoto
            ? photo.resolvedSettings.rawPhotoDimensions : photo.resolvedSettings.photoDimensions
        let pbDims: CMVideoDimensions = photo.pixelBuffer.map {
            CMVideoDimensions(
                width: Int32(CVPixelBufferGetWidth($0)),
                height: Int32(CVPixelBufferGetHeight($0)))
        } ?? CMVideoDimensions(width: 0, height: 0)
        let exposureMs = exposureMs
        let previewThumb = stillPreviewImage ?? Self.orientedPreviewImage(from: photo)
        writeQueue.async {
            let writeStarted = ProcessInfo.processInfo.systemUptime
            let needsInspect = !expectsRAW || previewThumb == nil
            let (headerW, headerH, sourceThumb) = needsInspect
                ? Self.inspectEncodedHeader(
                    data, needsThumbnail: previewThumb == nil, allowFallbackDecode: !expectsRAW)
                : (0, 0, nil)
            var (deliveredW, deliveredH) = CameraService.deliveredDimensions(
                isRAW: expectsRAW,
                pixelBufferDimensions: pbDims,
                resolvedDimensions: resolved,
                encodedHeaderDimensions: (headerW, headerH))
            if expectsRAW && (deliveredW <= 0 || deliveredH <= 0),
               let raw = CIRAWFilter(imageData: data, identifierHint: AVFileType.dng.rawValue),
               raw.nativeSize.width > 0, raw.nativeSize.height > 0
            {
                deliveredW = Int(raw.nativeSize.width.rounded())
                deliveredH = Int(raw.nativeSize.height.rounded())
            }
            let outcome = Result<CameraService.CaptureStoredResult, Error> {
                let url = try inbox.store(data, fileExtension: ext)
                let writeMs = (ProcessInfo.processInfo.systemUptime - writeStarted) * 1000
                Log.camera.debug(
                    "Capture \(ext.uppercased()) req=\(requested.width)×\(requested.height) res=\(resolved.width)×\(resolved.height) file=\(deliveredW)×\(deliveredH) exp=\(Int(exposureMs.rounded()))ms ser=\(Int(serializationMs.rounded()))ms write=\(Int(writeMs.rounded()))ms"
                )
                return CameraService.CaptureStoredResult(
                    token: token, url: url, requestedDimensions: requested, resolvedDimensions: resolved,
                    deliveredWidth: deliveredW,
                    deliveredHeight: deliveredH,
                    thumbnail: previewThumb ?? sourceThumb,
                    exposureMs: exposureMs, serializationMs: serializationMs, writeMs: writeMs)
            }
            self.writeResult = outcome
        }
    }

    private static func orientedPreviewImage(from photo: AVCapturePhoto) -> CGImage? {
        let base: CIImage
        if let buffer = photo.previewPixelBuffer {
            base = CIImage(cvPixelBuffer: buffer)
        } else if let rawCG = photo.previewCGImageRepresentation() {
            base = CIImage(cgImage: rawCG)
        } else {
            return nil
        }
        let rawOrientation = (photo.metadata[kCGImagePropertyOrientation as String] as? NSNumber)?.int32Value ?? 1
        var image = rawOrientation > 1 ? base.oriented(forExifOrientation: rawOrientation) : base
        let extent = image.extent
        let longEdge = max(extent.width, extent.height)
        guard longEdge > 0 else { return nil }
        let scale = min(1, 384.0 / longEdge)
        let targetW = max(1, Int((extent.width * scale).rounded()))
        let targetH = max(1, Int((extent.height * scale).rounded()))
        if abs(CGFloat(targetW) - extent.width) > 0.5 || abs(CGFloat(targetH) - extent.height) > 0.5 {
            image = image.transformed(
                by: CGAffineTransform(
                    scaleX: CGFloat(targetW) / extent.width, y: CGFloat(targetH) / extent.height))
        }
        image = image.transformed(
            by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        return previewContext.createCGImage(
            image, from: CGRect(x: 0, y: 0, width: targetW, height: targetH),
            format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }

    private static func inspectEncodedHeader(
        _ data: Data, needsThumbnail: Bool, allowFallbackDecode: Bool
    ) -> (Int, Int, CGImage?) {
        guard
            let source = CGImageSourceCreateWithData(
                data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return (0, 0, nil) }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let thumb: CGImage? =
            needsThumbnail
            ? CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageIfAbsent: allowFallbackDecode,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 160,
                    kCGImageSourceShouldCacheImmediately: true,
                ] as CFDictionary)
            : nil
        return (width, height, thumb)
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
        error: Error?
    ) {
        lock.lock()
        let continuation = exposureContinuation
        exposureContinuation = nil
        let alreadyCompleted = completed
        completed = true
        lock.unlock()
        if let continuation {
            if let error {
                onAbort(id)
                continuation.resume(throwing: error)
                return
            }
            continuation.resume()
        }
        guard !alreadyCompleted else { return }
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
