import UIKit
import XCTest

/// Run unchanged on phone, Duo (both displays), and iPad (full screen and windowed).
final class CameraLifecycleTests: XCTestCase {
    override func tearDown() {
        MainActor.assumeIsolated { XCUIDevice.shared.orientation = .portrait }
        super.tearDown()
    }

    @MainActor func testPortraitRoundTrip() throws { try roundTrip(.portrait) }
    @MainActor func testLandscapeRoundTrip() throws { try roundTrip(.landscapeLeft) }

    @MainActor private func roundTrip(_ orientation: UIDeviceOrientation) throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = orientation
        // Odd dimensions exercise partial GPU groups in thumbnails, previews, and grading.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 517, height: 337), format: format)
            .image { context in
                UIColor.gray.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 517, height: 337))
                UIColor.orange.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 259, height: 169))
            }
        let photo = FileManager.default.temporaryDirectory.appendingPathComponent("camera-round-trip.png")
        try XCTUnwrap(image.pngData()).write(to: photo)
        defer { try? FileManager.default.removeItem(at: photo) }
        let app = XCUIApplication(bundleIdentifier: "io.github.runzeni.spektracam")
        app.launchArguments = [
            "--ui-test-library", "--reset-test-library", "--ui-test-camera-demo",
            "--ui-test-camera-scene", "--ui-test-import", photo.path,
        ]
        app.launch()
        let cell = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'library.photo.'")).firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 30))
        for useLibraryButton in [false, true] {
            app.buttons["camera.open"].tap()
            let shutter = app.buttons["camera.shutter"]
            XCTAssertTrue(app.buttons["camera.lens.24"].waitForExistence(timeout: 10))
            XCTAssertTrue(shutter.isEnabled)
            let window = app.windows.firstMatch.frame
            if min(window.width, window.height) <= 450 {
                XCTAssertLessThan(window.width, window.height, "Standard iPhone camera must stay locked to portrait")
            }
            let library = app.buttons["camera.library"].frame
            let holdButton = app.buttons["camera.hold"].frame
            let exposure = app.sliders["camera.exposure"].frame
            let flash = app.buttons["camera.flash"].frame
            let flip = app.buttons["camera.flip"].frame
            let lens24 = app.buttons["camera.lens.24"].frame
            let finder = app.descendants(matching: .any)["camera.viewfinder"]
            XCTAssertTrue(finder.waitForExistence(timeout: 5))
            let finderFrame = finder.frame
            if window.width > window.height {
                // Wide iPad / Duo: whole portrait arrangement rotated 90° so the 4:3 finder keeps height.
                XCTAssertEqual(finderFrame.width / finderFrame.height, 4.0 / 3.0, accuracy: 0.03)
                XCTAssertEqual(shutter.frame.midY, finderFrame.midY, accuracy: 4)
                XCTAssertLessThanOrEqual(exposure.height, 260)
                let close = app.buttons["camera.close"].frame
                let format = app.buttons["camera.format"].frame
                XCTAssertEqual(close.midX, format.midX, accuracy: 8)
                XCTAssertLessThan(exposure.maxX, lens24.minX)
                XCTAssertLessThan(lens24.maxX, shutter.frame.minX)
                XCTAssertLessThan(holdButton.midY, shutter.frame.midY)
                XCTAssertLessThan(shutter.frame.midY, library.midY)
                XCTAssertLessThan(flip.midY, lens24.midY)
                XCTAssertLessThan(lens24.midY, flash.midY)
            } else {
                // Portrait phone & portrait iPad: Library · Shutter · LVF aligned under the EV slider.
                XCTAssertEqual(finderFrame.width / finderFrame.height, 3.0 / 4.0, accuracy: 0.03)
                XCTAssertLessThan(library.maxX, shutter.frame.minX)
                XCTAssertGreaterThan(holdButton.minX, shutter.frame.maxX)
                XCTAssertEqual(library.midY, shutter.frame.midY, accuracy: 1)
                XCTAssertEqual(holdButton.midY, shutter.frame.midY, accuracy: 1)
                XCTAssertEqual((library.minX + holdButton.maxX) / 2, shutter.frame.midX, accuracy: 2)
                XCTAssertEqual(exposure.midX, shutter.frame.midX, accuracy: 2, "Exposure slider drifted from shutter center")
                XCTAssertLessThanOrEqual(exposure.width, 260, "Exposure slider stretched beyond portrait length")
                XCTAssertEqual(lens24.midY, flash.midY, accuracy: 1)
                XCTAssertEqual(flip.midY, flash.midY, accuracy: 1)
                XCTAssertLessThan(flash.maxY, shutter.frame.minY)
            }
            app.buttons["camera.hold"].tap()
            let hold = app.descendants(matching: .any)["camera.hold.screen"]
            XCTAssertTrue(hold.waitForExistence(timeout: 5))
            if !useLibraryButton {
                XCUIDevice.shared.press(.home)
                app.activate()
                XCTAssertTrue(hold.waitForExistence(timeout: 5), "Foregrounding ended a user hold")
            }
            shutter.tap()
            XCTAssertTrue(hold.waitForNonExistence(timeout: 5))
            XCTAssertTrue(shutter.isEnabled)
            XCUIDevice.shared.orientation = orientation.isLandscape ? .portrait : .landscapeLeft
            app.buttons[useLibraryButton ? "camera.library" : "camera.close"].tap()
            XCTAssertTrue(app.buttons["camera.close"].waitForNonExistence(timeout: 10))
            // A visible or hittable library is insufficient: prove that a real action works.
            app.buttons["library.info"].tap()
            let about = app.navigationBars["About"]
            XCTAssertTrue(about.waitForExistence(timeout: 5))
            let done = app.buttons["Done"]
            XCTAssertTrue(done.waitForExistence(timeout: 5))
            done.tap()
            XCTAssertTrue(about.waitForNonExistence(timeout: 5))
        }
        cell.tap()
        XCTAssertTrue(app.buttons["photo.develop"].waitForExistence(timeout: 10))
        app.buttons["photo.develop"].tap()
        let film = app.buttons["develop.mode.spektrafilm"]
        XCTAssertTrue(film.waitForExistence(timeout: 30))
        film.tap()
        let preview = app.images["Edited photo"]
        XCTAssertTrue(preview.waitForExistence(timeout: 30))
        XCTAssertTrue(app.activityIndicators["Rendering preview"].waitForNonExistence(timeout: 30))
        app.buttons["editor.tool.adjust"].tap()
        let slider = app.sliders["tone.exposure"]
        XCTAssertTrue(slider.waitForExistence(timeout: 10))
        slider.adjust(toNormalizedSliderPosition: 0.6)
        XCTAssertTrue(app.activityIndicators["Rendering preview"].waitForNonExistence(timeout: 30))
        // Dismiss from inside the editor too; its navigation state and landscape orientation must survive the camera.
        app.buttons["camera.open"].tap()
        XCTAssertTrue(app.buttons["camera.close"].waitForExistence(timeout: 10))
        if min(app.windows.firstMatch.frame.width, app.windows.firstMatch.frame.height) <= 450 {
            XCTAssertLessThan(app.windows.firstMatch.frame.width, app.windows.firstMatch.frame.height)
        }
        app.buttons["camera.close"].tap()
        XCTAssertTrue(app.buttons["camera.close"].waitForNonExistence(timeout: 10))
        if XCUIDevice.shared.orientation.isLandscape {
            let restored = NSPredicate { _, _ in
                let f = app.windows.firstMatch.frame
                return f.width > f.height
            }
            expectation(for: restored, evaluatedWith: nil)
            waitForExpectations(timeout: 5)
        }
        app.buttons["editor.back"].tap()
        XCTAssertTrue(app.buttons["photo.develop"].waitForExistence(timeout: 15))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Camera returned to a working rendered photo"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor func testBayerOnlyCamera() {
        let app = XCUIApplication(bundleIdentifier: "io.github.runzeni.spektracam")
        app.launchArguments = ["--ui-test-library", "--reset-test-library", "--ui-test-camera-demo", "--ui-test-camera-bayer-only"]
        app.launch()
        XCTAssertTrue(app.buttons["camera.open"].waitForExistence(timeout: 15))
        app.buttons["camera.open"].tap()
        XCTAssertTrue(app.buttons["camera.lens.24"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["camera.lens.120"].exists)
        XCTAssertFalse(app.buttons["camera.lens.13"].exists)
        XCTAssertFalse(app.buttons["camera.flip"].isEnabled)
        XCTAssertTrue(app.buttons["camera.format"].label.contains("Bayer RAW"))
        app.buttons["camera.lens.120"].tap()
        XCTAssertTrue(app.buttons["camera.lens.120"].isSelected)
        app.buttons["camera.close"].tap()
        XCTAssertTrue(app.buttons["library.info"].waitForExistence(timeout: 10))
    }

    @MainActor func testNoRAWCameraKeepsLibraryAvailable() {
        let app = XCUIApplication(bundleIdentifier: "io.github.runzeni.spektracam")
        app.launchArguments = ["--ui-test-library", "--reset-test-library", "--ui-test-camera-demo", "--ui-test-camera-no-raw"]
        app.launch()
        XCTAssertTrue(app.buttons["camera.open"].waitForExistence(timeout: 15))
        app.buttons["camera.open"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["camera.rawUnsupported"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["camera.shutter"].isEnabled)
        XCTAssertFalse(app.buttons["camera.flip"].isEnabled)
        app.buttons["camera.close"].tap()
        app.buttons["library.info"].tap()
        XCTAssertTrue(app.buttons["about.importFiles"].waitForExistence(timeout: 10))
    }

    @MainActor func testRegularOnlyCameraAndRenderPrecision() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 480, height: 360), format: format)
            .image { context in
                UIColor.darkGray.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 480, height: 360))
            }
        let photo = FileManager.default.temporaryDirectory.appendingPathComponent("regular-camera.png")
        try XCTUnwrap(image.pngData()).write(to: photo)
        defer { try? FileManager.default.removeItem(at: photo) }

        let app = XCUIApplication(bundleIdentifier: "io.github.runzeni.spektracam")
        app.launchArguments = [
            "--ui-test-library", "--reset-test-library", "--ui-test-camera-demo",
            "--ui-test-camera-regular-only", "--ui-test-import", photo.path,
        ]
        app.launch()
        let cell = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'library.photo.'")).firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 30))

        app.buttons["camera.open"].tap()
        XCTAssertTrue(app.buttons["camera.lens.24"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["camera.lens.13"].exists)
        XCTAssertFalse(app.buttons["camera.lens.120"].exists)
        XCTAssertTrue(app.buttons["camera.flip"].isEnabled)
        XCTAssertTrue(app.buttons["camera.shutter"].isEnabled)
        XCTAssertTrue(app.buttons["camera.format"].label.contains("HEIC"))

        app.buttons["camera.shutter"].tap()
        let savedBadge = app.descendants(matching: .any)["camera.saved"]
        XCTAssertTrue(savedBadge.waitForExistence(timeout: 5))
        app.buttons["camera.flip"].tap()
        app.buttons["camera.flip"].tap()
        XCTAssertTrue(app.buttons["camera.lens.24"].waitForExistence(timeout: 5))
        app.buttons["camera.close"].tap()
        XCTAssertTrue(app.buttons["camera.close"].waitForNonExistence(timeout: 10))

        app.buttons["library.info"].tap()
        XCTAssertTrue(app.navigationBars["About"].waitForExistence(timeout: 5))
        let precision = app.buttons["about.renderPrecision"]
        func revealPrecision() {
            let list = app.collectionViews.firstMatch
            XCTAssertTrue(list.waitForExistence(timeout: 5))
            for _ in 0..<6 where !(precision.exists && precision.isHittable) {
                let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.78))
                let end = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.28))
                start.press(
                    forDuration: 0.05, thenDragTo: end, withVelocity: .slow,
                    thenHoldForDuration: 0.15)
            }
            XCTAssertTrue(precision.waitForExistence(timeout: 5))
            XCTAssertTrue(precision.isHittable)
        }
        revealPrecision()
        precision.tap()
        app.buttons["16-bit float"].tap()
        app.buttons["Done"].tap()

        cell.tap()
        XCTAssertTrue(app.buttons["photo.develop"].waitForExistence(timeout: 10))
        app.buttons["photo.develop"].tap()
        let film = app.buttons["develop.mode.spektrafilm"]
        XCTAssertTrue(film.waitForExistence(timeout: 30))
        film.tap()
        XCTAssertTrue(app.images["Edited photo"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.activityIndicators["Rendering preview"].waitForNonExistence(timeout: 30))
        app.buttons["editor.back"].tap()
        XCTAssertTrue(app.buttons["photo.develop"].waitForExistence(timeout: 15))
        let back = app.buttons["BackButton"]
        (back.exists ? back : app.navigationBars.buttons["Library"]).tap()
        XCTAssertTrue(app.buttons["library.info"].waitForExistence(timeout: 10))

        app.buttons["library.info"].tap()
        XCTAssertTrue(app.navigationBars["About"].waitForExistence(timeout: 5))
        revealPrecision()
        precision.tap()
        app.buttons["Automatic"].tap()
        app.buttons["Done"].tap()
    }

    @MainActor func testBayerHybridLensFlipPreservesRAW() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "io.github.runzeni.spektracam")
        app.launchArguments = [
            "--ui-test-library", "--reset-test-library", "--ui-test-camera-demo",
            "--ui-test-camera-bayer-hybrid",
        ]
        app.launch()
        XCTAssertTrue(app.buttons["camera.open"].waitForExistence(timeout: 15))
        app.buttons["camera.open"].tap()
        XCTAssertTrue(app.buttons["camera.lens.24"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["camera.format"].label.contains("Bayer RAW"))

        // Switch to non-RAW ultra-wide (13 mm -> HEIC), then back to primary wide (24 mm -> Bayer RAW).
        app.buttons["camera.lens.13"].tap()
        XCTAssertTrue(app.buttons["camera.format"].label.contains("HEIC"))
        app.buttons["camera.lens.24"].tap()
        XCTAssertTrue(app.buttons["camera.format"].label.contains("Bayer RAW"))

        // Flip to non-RAW front camera (-> HEIC), then flip back to rear wide (-> Bayer RAW).
        app.buttons["camera.flip"].tap()
        XCTAssertTrue(app.buttons["camera.format"].label.contains("HEIC"))
        app.buttons["camera.flip"].tap()
        XCTAssertTrue(app.buttons["camera.lens.24"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["camera.format"].label.contains("Bayer RAW"))

        app.buttons["camera.close"].tap()
        XCTAssertTrue(app.buttons["library.info"].waitForExistence(timeout: 10))
    }
}
