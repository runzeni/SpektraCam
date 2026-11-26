@preconcurrency import AVFoundation
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import OSLog

nonisolated struct CameraReadings: Sendable {
    var histogram = Array(repeating: Double(0), count: 64)
    var seconds = Double(0)
    var aperture = Float(0)
    var iso = Float(0)
    /// The device's own exposure bias, so the slider follows Camera Control.
    var bias = Float(0)
}

nonisolated struct CameraLens: Identifiable, Equatable, Sendable {
    let id: String
    let millimeters: Int
    let front: Bool
    let macro: Bool
    let primary: Bool
    var title: String {
        front ? String(localized: "camera.front", defaultValue: "Front") : String(millimeters)
    }
}

/// Preview-sized luma samples, at most five updates per second. This is not a RAW histogram.
/// Also supports a one-shot exposure snapshot while a still capture is armed, without converting
/// frames or holding buffers during normal live viewfinder operation.
nonisolated final class CameraMeter: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
    @unchecked Sendable
{
    private struct SnapshotWaiter {
        let id: UUID
        let targetRotation: CGFloat
        let targetMirrored: Bool
        let completion: @Sendable (CGImage?) -> Void
    }

    private let device: AVCaptureDevice
    private let publish: @Sendable (CameraReadings) -> Void
    private var lastUpdate = -Double.infinity
    private let started = ProcessInfo.processInfo.systemUptime
    private let snapshotLock = NSLock()
    private var armedCount = 0
    private var latestSample: (buffer: CVPixelBuffer, rotation: CGFloat, mirrored: Bool)?
    private var pendingWaiters: [SnapshotWaiter] = []
    private var _snapshotContext: CIContext?

    private func currentSnapshotContext() -> CIContext {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        if let existing = _snapshotContext { return existing }
        let created = CIContext(options: [.cacheIntermediates: false])
        _snapshotContext = created
        return created
    }

    init(device: AVCaptureDevice, publish: @escaping @Sendable (CameraReadings) -> Void) {
        self.device = device
        self.publish = publish
    }

    func armSnapshot() {
        snapshotLock.lock()
        armedCount += 1
        snapshotLock.unlock()
    }

    func disarmSnapshot() {
        snapshotLock.lock()
        armedCount = max(0, armedCount - 1)
        if armedCount == 0 { latestSample = nil }
        snapshotLock.unlock()
    }

    func disarmAll() {
        let waiters: [SnapshotWaiter]
        snapshotLock.lock()
        armedCount = 0
        latestSample = nil
        waiters = pendingWaiters
        pendingWaiters.removeAll()
        snapshotLock.unlock()
        for waiter in waiters { waiter.completion(nil) }
    }

    func takeSnapshot(
        targetRotation: CGFloat, targetMirrored: Bool, on queue: DispatchQueue,
        completion: @escaping @Sendable (CGImage?) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else {
                completion(nil)
                return
            }
            var sample: (buffer: CVPixelBuffer, rotation: CGFloat, mirrored: Bool)?
            var waiterID: UUID?
            self.snapshotLock.lock()
            self.armedCount = max(0, self.armedCount - 1)
            sample = self.latestSample
            if self.armedCount == 0 { self.latestSample = nil }
            if sample == nil {
                let id = UUID()
                waiterID = id
                self.pendingWaiters.append(
                    SnapshotWaiter(
                        id: id, targetRotation: targetRotation, targetMirrored: targetMirrored,
                        completion: completion))
            }
            self.snapshotLock.unlock()
            if let sample {
                completion(
                    Self.renderThumbnail(
                        context: self.currentSnapshotContext(), buffer: sample.buffer,
                        sourceRotation: sample.rotation, sourceMirrored: sample.mirrored,
                        targetRotation: targetRotation, targetMirrored: targetMirrored))
            } else if let id = waiterID {
                queue.asyncAfter(deadline: .now() + .milliseconds(60)) { [weak self] in
                    guard let self else { return }
                    var expired: SnapshotWaiter?
                    self.snapshotLock.lock()
                    if let index = self.pendingWaiters.firstIndex(where: { $0.id == id }) {
                        expired = self.pendingWaiters.remove(at: index)
                    }
                    self.snapshotLock.unlock()
                    expired?.completion(nil)
                }
            }
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        snapshotLock.lock()
        let wantsSample = armedCount > 0 || !pendingWaiters.isEmpty
        let waiters = pendingWaiters
        if !waiters.isEmpty { pendingWaiters.removeAll() }
        if wantsSample, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            let sourceRotation = connection.videoRotationAngle
            let sourceMirrored = connection.isVideoMirrored
            if armedCount > 0 {
                latestSample = (buffer, sourceRotation, sourceMirrored)
            }
            snapshotLock.unlock()
            let context = waiters.isEmpty ? nil : currentSnapshotContext()
            for waiter in waiters {
                waiter.completion(
                    Self.renderThumbnail(
                        context: context!, buffer: buffer,
                        sourceRotation: sourceRotation, sourceMirrored: sourceMirrored,
                        targetRotation: waiter.targetRotation, targetMirrored: waiter.targetMirrored))
            }
        } else {
            snapshotLock.unlock()
            for waiter in waiters { waiter.completion(nil) }
        }

        let now = ProcessInfo.processInfo.systemUptime
        if lastUpdate == -.infinity {
            Log.camera.debug("First preview frame: \(now - self.started) s")
        }
        guard now - lastUpdate >= 0.2, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer),
            CVPixelBufferGetPlaneCount(buffer) >= 1
        else { return }
        lastUpdate = now
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        let fullRange =
            CVPixelBufferGetPixelFormatType(buffer)
            == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        var bins = Array(repeating: Double(0), count: 64)
        for y in stride(from: 0, to: height, by: max(1, height / 64)) {
            for x in stride(from: 0, to: width, by: max(1, width / 64)) {
                let value = Int(pixels[y * rowBytes + x])
                let code = fullRange ? value : max(0, min(255, (value - 16) * 255 / 219))
                bins[code / 4] += 1
            }
        }
        let peak = max(1, bins.max() ?? 1)
        publish(
            CameraReadings(
                histogram: bins.map { $0 / peak }, seconds: device.exposureDuration.seconds,
                aperture: device.lensAperture, iso: device.iso,
                bias: device.exposureTargetBias))
    }

    private static func renderThumbnail(
        context: CIContext, buffer: CVPixelBuffer,
        sourceRotation: CGFloat, sourceMirrored: Bool,
        targetRotation: CGFloat, targetMirrored: Bool,
        maximumPixelSize: Int = 192
    ) -> CGImage? {
        var image = CIImage(cvPixelBuffer: buffer)
        let delta = ((targetRotation - sourceRotation).truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360)
        let step = Int((delta / 90).rounded()) % 4
        if abs(delta - CGFloat(step) * 90) < 1 {
            switch step {
            case 1: image = image.oriented(.right)
            case 2: image = image.oriented(.down)
            case 3: image = image.oriented(.left)
            default: break
            }
        } else {
            image = image.transformed(by: CGAffineTransform(rotationAngle: -delta * .pi / 180))
            image = image.transformed(
                by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        }
        if targetMirrored != sourceMirrored {
            image = image.oriented(.upMirrored)
        }
        let extent = image.extent
        let longEdge = max(extent.width, extent.height)
        guard longEdge > 0 else { return nil }
        let scale = min(1, CGFloat(maximumPixelSize) / longEdge)
        let targetWidth = max(1, Int((extent.width * scale).rounded()))
        let targetHeight = max(1, Int((extent.height * scale).rounded()))
        let scaled = image.transformed(
            by: CGAffineTransform(
                scaleX: CGFloat(targetWidth) / extent.width,
                y: CGFloat(targetHeight) / extent.height))
        let normalized = scaled.transformed(
            by: CGAffineTransform(translationX: -scaled.extent.minX, y: -scaled.extent.minY))
        return context.createCGImage(
            normalized,
            from: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight),
            format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }
}
