import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ImageIO
import UniformTypeIdentifiers

@main struct Checks {
    private static func makeTestCGImage(width: Int = 32, height: Int = 24, r: CGFloat, g: CGFloat, b: CGFloat) -> CGImage {
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: r, green: g, blue: b, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    private static func makeJPEG(exifDate: String, r: CGFloat, g: CGFloat, b: CGFloat) -> Data {
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        let img = makeTestCGImage(r: r, g: g, b: b)
        CGImageDestinationAddImage(
            dest, img,
            [kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: exifDate]] as CFDictionary)
        precondition(CGImageDestinationFinalize(dest))
        return data as Data
    }

    @MainActor static func main() async throws {
        let rootProject = URL(fileURLWithPath: CommandLine.arguments[1])
        let modelDir = rootProject.appendingPathComponent("SpektraCam/Resources/ModelData")
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SpektraCam-CameraChecks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let libRoot = temp.appendingPathComponent("Lib")
        let libCache = temp.appendingPathComponent("Cache")
        let library = try PhotoLibrary(root: libRoot, cache: libCache, modelDirectory: modelDir)

        // 1. Future-dated EXIF photo imported earlier vs newly added capture.
        let futureURL = temp.appendingPathComponent("future.jpg")
        try makeJPEG(exifDate: "2099:01:01 12:00:00", r: 0.9, g: 0.1, b: 0.1).write(to: futureURL)
        let futurePhoto = try await library.importPhoto(futureURL)
        try await Task.sleep(for: .milliseconds(25))
        let newURL = temp.appendingPathComponent("recent.jpg")
        try makeJPEG(exifDate: "2020:06:15 12:34:56", r: 0.1, g: 0.8, b: 0.2).write(to: newURL)
        let newPhoto = try await library.importPhoto(newURL)
        precondition(
            futurePhoto.date > newPhoto.date && newPhoto.importedAt > futurePhoto.importedAt,
            "Test fixture dates did not exercise future-dated EXIF vs newer import")
        precondition(
            library.latestAddedPhoto?.id == newPhoto.id,
            "latestAddedPhoto picked future-dated photo \(String(describing: library.latestAddedPhoto?.id)) over newest import \(newPhoto.id)")

        // 2. CameraThumbnailCoordinator token lifecycle: exposure -> still preview -> commit,
        //    no provisional overwrite after exact still, out-of-order burst isolation, write failure revert.
        var coordinator = CameraThumbnailCoordinator()
        let t1 = coordinator.issueToken(format: .heic, highResolution: false, standardMegapixels: 12, flash: false)
        let t2 = coordinator.issueToken(format: .proRAW, highResolution: false, standardMegapixels: 12, flash: false)
        precondition(t2.sequence > t1.sequence)

        let prov1 = makeTestCGImage(r: 0.2, g: 0.3, b: 0.8)
        let still1 = makeTestCGImage(r: 0.3, g: 0.4, b: 0.9)
        let prov2 = makeTestCGImage(r: 0.8, g: 0.7, b: 0.1)

        // Exposure sets provisional pending state; late nil/other provisional frame cannot clobber exact still.
        coordinator.didExpose(token: t1, provisionalFrame: prov1)
        if case .pending(let tok, let img, let isProv) = coordinator.buttonState {
            precondition(tok.id == t1.id && img === prov1 && isProv)
        } else { preconditionFailure("t1 exposure did not enter pending provisional") }

        coordinator.didReceiveStillPreview(token: t1, image: still1)
        if case .pending(let tok, let img, let isProv) = coordinator.buttonState {
            precondition(tok.id == t1.id && img === still1 && !isProv)
        } else { preconditionFailure("t1 still preview did not upgrade pending") }

        // A delayed provisional callback for t1 must NEVER revert isProvisional back to true.
        coordinator.didExpose(token: t1, provisionalFrame: prov1)
        if case .pending(_, let img, let isProv) = coordinator.buttonState {
            precondition(img === still1 && !isProv, "Delayed provisional frame downgraded exact still preview")
        } else { preconditionFailure("Unexpected buttonState after late provisional") }

        let fakeURL1 = temp.appendingPathComponent("shot1.heic")
        let dims = CMVideoDimensions(width: 120, height: 90)
        coordinator.didStoreToInbox(
            result: .init(
                token: t1,
                url: fakeURL1,
                requestedDimensions: dims,
                resolvedDimensions: dims,
                deliveredWidth: 120,
                deliveredHeight: 90,
                thumbnail: still1,
                exposureMs: 1,
                serializationMs: 1,
                writeMs: 1))
        let committed1 = coordinator.didRecoverImports([fakeURL1.standardizedFileURL: newPhoto])
        precondition(committed1?.id == newPhoto.id)
        if case .committed(let tok, let photo, let img) = coordinator.buttonState {
            precondition(tok.id == t1.id && photo.id == newPhoto.id && img === still1)
        } else { preconditionFailure("t1 recovery did not commit") }

        // Rapid burst: expose t2 BEFORE late t1 callbacks; late t1 cannot hijack t2!
        coordinator.didExpose(token: t2, provisionalFrame: prov2)
        coordinator.didReceiveStillPreview(token: t1, image: prov1)
        if case .pending(let tok, let img, let isProv) = coordinator.buttonState {
            precondition(tok.id == t2.id && img === prov2 && isProv, "Older token t1 overwrote active t2")
        } else { preconditionFailure("Expected t2 to stay pending") }

        // Failed write on active token t2 sets hasFailedSave and reverts cleanly to last committed (t1/newPhoto).
        coordinator.didFailWrite(for: t2)
        precondition(coordinator.hasFailedSave, "didFailWrite did not set hasFailedSave")
        if case .committed(let tok, let photo, _) = coordinator.buttonState {
            precondition(tok.id == t1.id && photo.id == newPhoto.id, "Failed t2 did not revert to lastCommitted t1")
        } else { preconditionFailure("Failed t2 did not revert buttonState to lastCommitted") }

        // Next exposure clears hasFailedSave.
        let t3 = coordinator.issueToken(format: .heic, highResolution: false, standardMegapixels: 12, flash: false)
        coordinator.didExpose(token: t3, provisionalFrame: nil)
        precondition(!coordinator.hasFailedSave, "Next exposure did not clear hasFailedSave")

        // Failed write when nothing was ever committed falls back to `.library`.
        var freshCoord = CameraThumbnailCoordinator()
        let tf = freshCoord.issueToken(format: .heic, highResolution: false, standardMegapixels: 12, flash: false)
        freshCoord.didExpose(token: tf, provisionalFrame: prov1)
        freshCoord.didFailWrite(for: tf)
        precondition(freshCoord.hasFailedSave)
        if case .library = freshCoord.buttonState {} else { preconditionFailure("Uncommitted failure did not revert to .library") }

        // 3. LibraryImages.cameraThumbnail must bypass paused ImageRequestPool (Camera over Develop).
        let pauseOwner = UUID()
        await library.images.beginEditing(owner: pauseOwner)
        await library.images.discardMemory()
        let bypassed = try await library.images.cameraThumbnail(newPhoto)
        precondition(bypassed.width > 0 && bypassed.height > 0, "cameraThumbnail returned empty image while requests paused")
        await library.images.endEditing(owner: pauseOwner)

        // 4. Deleting a committed shot removes it from Camera's buttonState & lastCommitted.
        try await library.delete([newPhoto.id])
        coordinator.pruneInactivePhotos { library.photo($0) != nil }
        if case .committed(_, let committedPhoto, _) = coordinator.buttonState {
            precondition(committedPhoto.id != newPhoto.id, "Deleted photo remained in Camera thumbnail")
        }
        precondition(coordinator.lastCommitted?.photo.id != newPhoto.id, "Deleted photo remained in lastCommitted")

        // 5. CameraModel lifecycle & shutter readiness resilience:
        //    Simulator has no physical camera (`state == .unavailable`), and rapid active/inactive/close
        //    transitions must reconcile deterministically without hanging or leaving `canCapture` true.
        let model = CameraModel(library: library)
        let monitorTask = Task { await model.monitor() }
        let readingsTask = Task { await model.monitorReadings() }
        await model.setActive(false)
        precondition(model.state == .paused && !model.canCapture)
        await model.setActive(true)
        precondition(model.state == .unavailable && !model.canCapture)
        // Momentary readiness transitions should not request shutter dimming when otherwise active,
        // while `.sessionNotRunning` / `.unavailable` does dim.
        precondition(model.dimsDisabledShutter, "Unavailable camera should dim disabled shutter")
        await model.close()
        monitorTask.cancel()
        readingsTask.cancel()
        precondition(model.state == .paused && !model.canCapture)

        // 6. Exposure readout must never render impossible ƒ0.0 when aperture is unknown/0,
        //    and CameraReadinessBridge tracks current readiness synchronously.
        var zeroReading = CameraReadings()
        zeroReading.aperture = 0
        zeroReading.seconds = 1.0 / 125.0
        let unknownLine = CameraExposureReadout.primaryLine(zeroReading)
        precondition(
            unknownLine == "ƒ— | 1/125 s" && !unknownLine.contains("0.0"),
            "Zero aperture rendered invalid readout: \(unknownLine)")
        var validReading = CameraReadings()
        validReading.aperture = 1.78
        validReading.seconds = 1.0 / 4000.0
        let validLine = CameraExposureReadout.primaryLine(validReading)
        precondition(validLine == "ƒ1.8 | 1/4000 s", "Unexpected valid readout: \(validLine)")
        let bridge = CameraReadinessBridge(output: AVCapturePhotoOutput())
        precondition(bridge.currentReadiness == .sessionNotRunning)

        // 7. RAW delivered dimensions must use pixelBuffer / resolved rawPhotoDimensions, never
        //    the 1080×810 (~0.87 MP -> "Saved at 1 MP") IFD0 embedded thumbnail, while non-RAW
        //    still honors encodedHeaderDimensions.
        let thumbDims = (width: 1080, height: 810)
        let dims48MP = CMVideoDimensions(width: 8064, height: 6048)
        let dims12MP = CMVideoDimensions(width: 4032, height: 3024)
        let raw48 = CameraService.deliveredDimensions(
            isRAW: true,
            pixelBufferDimensions: dims48MP,
            resolvedDimensions: dims48MP,
            encodedHeaderDimensions: thumbDims)
        precondition(
            raw48.width == 8064 && raw48.height == 6048
                && CameraService.nominalMegapixels(CMVideoDimensions(width: Int32(raw48.width), height: Int32(raw48.height))) == 48,
            "RAW 48 MP capture fell back to IFD0 thumbnail: \(raw48)")
        let rawBinned12 = CameraService.deliveredDimensions(
            isRAW: true,
            pixelBufferDimensions: CMVideoDimensions(width: 0, height: 0),
            resolvedDimensions: dims12MP,
            encodedHeaderDimensions: thumbDims)
        precondition(
            rawBinned12.width == 4032 && rawBinned12.height == 3024
                && CameraService.nominalMegapixels(CMVideoDimensions(width: Int32(rawBinned12.width), height: Int32(rawBinned12.height))) == 12,
            "ISP-binned 12 MP RAW reported wrong size (e.g. 1 MP thumbnail): \(rawBinned12)")
        let heic12 = CameraService.deliveredDimensions(
            isRAW: false,
            pixelBufferDimensions: CMVideoDimensions(width: 0, height: 0),
            resolvedDimensions: dims48MP,
            encodedHeaderDimensions: (4032, 3024))
        precondition(heic12.width == 4032 && heic12.height == 3024, "HEIC ignored encoded header dimensions: \(heic12)")

        print("PASS: camera thumbnail token handoff, out-of-order burst immunity, future-date latestAddedPhoto immunity, write-failure revert, pause-bypassing cameraThumbnail, and CameraModel lifecycle reconciliation")
    }
}
