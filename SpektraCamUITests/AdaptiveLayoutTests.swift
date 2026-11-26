import XCTest

/// The editor and Darkroom follow the space they are given: stacked when taller than wide,
/// side by side when wider than tall. Runs on any Simulator; set
/// `SPEKTRACAM_LAYOUT_PHOTO` to a host image path and, optionally,
/// `SPEKTRACAM_LAYOUT_SHOTS` to a host directory for screenshots.
final class AdaptiveLayoutTests: XCTestCase {
    private var shots: String? { ProcessInfo.processInfo.environment["SPEKTRACAM_LAYOUT_SHOTS"] }

    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let screenshot = app.windows.firstMatch.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let shots {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: shots + "/" + name + ".png"))
        }
    }

    @MainActor private func openEditor(_ orientation: UIDeviceOrientation) throws -> XCUIApplication {
        let photo = try XCTUnwrap(
            ProcessInfo.processInfo.environment["SPEKTRACAM_LAYOUT_PHOTO"],
            "Set SPEKTRACAM_LAYOUT_PHOTO to an image on the host")
        continueAfterFailure = false
        XCUIDevice.shared.orientation = orientation
        let app = XCUIApplication(bundleIdentifier: "io.github.runzeni.spektracam")
        app.launchArguments = ["--ui-test-library", "--reset-test-library", "--ui-test-import", photo]
        app.launch()
        let cell = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'library.photo.'")).firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 30))
        capture(app, orientation.isLandscape ? "wide-library" : "tall-library")
        app.buttons["camera.open"].tap()
        XCTAssertTrue(app.buttons["camera.shutter"].waitForExistence(timeout: 10))
        capture(app, orientation.isLandscape ? "wide-camera" : "tall-camera")
        app.buttons["camera.close"].tap()
        // Leaving the camera releases its portrait hold; the library must come back usable.
        XCTAssertTrue(app.buttons["library.import"].waitForExistence(timeout: 10))
        capture(app, orientation.isLandscape ? "wide-after-camera" : "tall-after-camera")
        cell.tap()
        XCTAssertTrue(app.buttons["photo.develop"].waitForExistence(timeout: 10))
        capture(app, orientation.isLandscape ? "wide-viewer" : "tall-viewer")
        app.buttons["photo.develop"].tap()
        XCTAssertTrue(app.buttons["editor.tool.develop"].waitForExistence(timeout: 30))
        return app
    }

    @MainActor private func tour(_ app: XCUIApplication, prefix: String) {
        app.buttons["editor.tool.develop"].tap()
        XCTAssertTrue(app.buttons["develop.mode.spektrafilm"].waitForExistence(timeout: 5))
        app.buttons["develop.mode.spektrafilm"].tap()
        sleep(2)
        capture(app, prefix + "develop")
        app.buttons["editor.tool.adjust"].tap()
        XCTAssertTrue(app.sliders["tone.exposure"].waitForExistence(timeout: 5))
        capture(app, prefix + "adjust")
        app.buttons["editor.tool.effects"].tap()
        capture(app, prefix + "effects")
        app.buttons["editor.tool.crop"].tap()
        XCTAssertTrue(app.sliders["crop.straighten"].waitForExistence(timeout: 5))
        capture(app, prefix + "crop")
        app.buttons["crop.done"].tap()
        app.buttons["editor.export"].tap()
        XCTAssertTrue(app.buttons["darkroom.export"].waitForExistence(timeout: 10))
        capture(app, prefix + "darkroom")
        app.buttons["darkroom.filmEdge"].tap()
        sleep(3)
        capture(app, prefix + "darkroom-edge")
    }

    /// The simulator has no camera; `--ui-test-camera-demo` stands one in so every control is live.
    @MainActor private func cameraDemo(_ orientation: UIDeviceOrientation, prefix: String) {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = orientation
        let app = XCUIApplication(bundleIdentifier: "io.github.runzeni.spektracam")
        app.launchArguments = [
            "--ui-test-library", "--reset-test-library", "--ui-test-camera-demo",
            "--ui-test-camera-scene",
        ]
        app.launch()
        XCTAssertTrue(app.buttons["camera.open"].waitForExistence(timeout: 15))
        app.buttons["camera.open"].tap()
        let shutter = app.buttons["camera.shutter"]
        let hold = app.buttons["camera.hold"]
        XCTAssertTrue(app.buttons["camera.lens.24"].waitForExistence(timeout: 10))
        XCTAssertTrue(shutter.isEnabled)
        let window = app.windows.firstMatch.frame
        let wide = window.width > window.height
        let finder = app.descendants(matching: .any)["camera.viewfinder"]
        XCTAssertTrue(finder.waitForExistence(timeout: 5))
        let finderFrame = finder.frame
        let expectedAspect = wide ? (4.0 / 3.0) : (3.0 / 4.0)
        XCTAssertEqual(finderFrame.width / finderFrame.height, expectedAspect, accuracy: 0.03)
        capture(app, prefix + "camera-ready")
        XCTContext.runActivity(
            named: "Camera geometry window=\(NSCoder.string(for: window)) finder=\(NSCoder.string(for: finderFrame))"
        ) { _ in }

        if wide {
            let expectedRight = orientation != .landscapeRight
            assertWideCameraAnchors(app, shutterOnRight: expectedRight, finderFrame: finderFrame)
        } else {
            // Portrait: hold sits on the shutter's right, under the right thumb.
            XCTAssertGreaterThanOrEqual(hold.frame.midX, shutter.frame.midX)
            let exposure = app.sliders["camera.exposure"].frame
            XCTAssertEqual(exposure.midX, shutter.frame.midX, accuracy: 2)
            XCTAssertLessThanOrEqual(exposure.width, 260)
        }

        // Flash has two states and starts off.
        let flash = app.buttons["camera.flash"]
        XCTAssertEqual(flash.value as? String, "Off")
        flash.tap()
        XCTAssertEqual(flash.value as? String, "On")
        shutter.tap()
        XCTAssertTrue(app.staticTexts["camera.saved"].waitForExistence(timeout: 5))
        // LVF switches the camera off; the shutter stays where it was and wakes it.
        let shutterFrame = shutter.frame
        hold.tap()
        let screen = app.descendants(matching: .any)["camera.hold.screen"]
        XCTAssertTrue(screen.waitForExistence(timeout: 5))
        // The controls stay in place on hold; they are only inactive.
        XCTAssertTrue(app.buttons["camera.lens.24"].exists)
        XCTAssertFalse(app.buttons["camera.lens.24"].isEnabled)
        XCTAssertEqual(shutter.frame.midX, shutterFrame.midX, accuracy: 1)
        XCTAssertEqual(shutter.frame.midY, shutterFrame.midY, accuracy: 1)
        capture(app, prefix + "camera-hold")
        shutter.tap()
        XCTAssertTrue(screen.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["camera.lens.24"].isEnabled)
        hold.tap()
        XCTAssertTrue(screen.waitForExistence(timeout: 5))
        screen.tap()
        XCTAssertTrue(screen.waitForNonExistence(timeout: 5))
        // EV slider stays compact and reachable; reset returns it to +0.00 EV.
        let exposureControl = app.sliders["camera.exposure"]
        if wide {
            let start = exposureControl.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let end = exposureControl.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.18))
            start.press(forDuration: 0.05, thenDragTo: end)
        } else {
            exposureControl.adjust(toNormalizedSliderPosition: 0.75)
        }
        XCTAssertNotEqual(app.buttons["camera.exposureReset"].value as? String, "+0.00 EV")
        app.buttons["camera.exposureReset"].tap()
        XCTAssertEqual(app.buttons["camera.exposureReset"].value as? String, "+0.00 EV")
        // A live camera must still let go: Close returns to a working library.
        app.buttons["camera.close"].tap()
        XCTAssertTrue(app.buttons["library.import"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["camera.open"].isHittable)
    }

    @MainActor private func assertWideCameraAnchors(
        _ app: XCUIApplication, shutterOnRight: Bool, finderFrame: CGRect
    ) {
        XCTAssertEqual(app.buttons.matching(identifier: "camera.close").count, 1)
        let close = app.buttons["camera.close"].frame
        let format = app.buttons["camera.format"].frame
        let exposureInfo = app.descendants(matching: .any)["camera.exposureInfo"].frame
        let exposure = app.sliders["camera.exposure"].frame
        let exposureReset = app.buttons["camera.exposureReset"].frame
        let flash = app.buttons["camera.flash"].frame
        let flip = app.buttons["camera.flip"].frame
        let macro = app.buttons["camera.macro"].frame
        let lens13 = app.buttons["camera.lens.13"].frame
        let lens24 = app.buttons["camera.lens.24"].frame
        let lens120 = app.buttons["camera.lens.120"].frame
        let library = app.buttons["camera.library"].frame
        let shutter = app.buttons["camera.shutter"].frame
        let hold = app.buttons["camera.hold"].frame

        XCTAssertEqual(shutter.midY, finderFrame.midY, accuracy: 4)
        XCTAssertLessThanOrEqual(exposure.height, 260)
        XCTAssertEqual(close.midX, format.midX, accuracy: 8)
        XCTAssertEqual(close.midX, exposureInfo.midX, accuracy: 8)

        if shutterOnRight {
            XCTAssertLessThanOrEqual(close.maxX, finderFrame.minX + 2)
            XCTAssertGreaterThanOrEqual(exposureReset.minX, finderFrame.maxX - 2)
            XCTAssertLessThan(exposure.maxX, lens24.minX)
            XCTAssertLessThan(lens24.maxX, shutter.minX)
            XCTAssertLessThan(exposureInfo.midY, format.midY)
            XCTAssertLessThan(format.midY, close.midY)
            XCTAssertLessThanOrEqual(exposureReset.maxY, exposure.minY + 4)
            XCTAssertLessThan(flip.midY, lens120.midY)
            XCTAssertLessThan(lens120.midY, lens24.midY)
            XCTAssertLessThan(lens24.midY, lens13.midY)
            XCTAssertLessThan(lens13.midY, macro.midY)
            XCTAssertLessThan(macro.midY, flash.midY)
            XCTAssertLessThan(hold.midY, shutter.midY)
            XCTAssertLessThan(shutter.midY, library.midY)
        } else {
            XCTAssertLessThan(shutter.maxX, lens24.minX)
            XCTAssertLessThan(lens24.maxX, exposure.minX)
            XCTAssertLessThanOrEqual(exposureReset.maxX, finderFrame.minX + 2)
            XCTAssertGreaterThanOrEqual(close.minX, finderFrame.maxX - 2)
            XCTAssertLessThan(close.midY, format.midY)
            XCTAssertLessThan(format.midY, exposureInfo.midY)
            XCTAssertLessThanOrEqual(exposure.maxY, exposureReset.minY + 4)
            XCTAssertLessThan(flash.midY, macro.midY)
            XCTAssertLessThan(macro.midY, lens13.midY)
            XCTAssertLessThan(lens13.midY, lens24.midY)
            XCTAssertLessThan(lens24.midY, lens120.midY)
            XCTAssertLessThan(lens120.midY, flip.midY)
            XCTAssertLessThan(library.midY, shutter.midY)
            XCTAssertLessThan(shutter.midY, hold.midY)
        }
    }

    @MainActor func testCameraHoldFlashAndShutterInPortrait() { cameraDemo(.portrait, prefix: "tall-") }
    @MainActor func testCameraHoldFlashAndShutterInLandscape() { cameraDemo(.landscapeLeft, prefix: "wide-") }
    @MainActor func testCameraHoldFlashAndShutterInOppositeLandscape() throws {
        XCUIDevice.shared.orientation = .landscapeRight
        let app = XCUIApplication(bundleIdentifier: "io.github.runzeni.spektracam")
        app.launchArguments = [
            "--ui-test-library", "--reset-test-library", "--ui-test-camera-demo",
            "--ui-test-camera-scene",
        ]
        app.launch()
        XCTAssertTrue(app.buttons["camera.open"].waitForExistence(timeout: 15))
        app.buttons["camera.open"].tap()
        XCTAssertTrue(app.buttons["camera.lens.24"].waitForExistence(timeout: 10))
        let window = app.windows.firstMatch.frame
        try XCTSkipIf(window.width <= window.height, "Device stays portrait-locked in Camera")
        let finder = app.descendants(matching: .any)["camera.viewfinder"]
        XCTAssertTrue(finder.waitForExistence(timeout: 5))
        let close = app.buttons["camera.close"].frame
        let shutter = app.buttons["camera.shutter"].frame
        try XCTSkipIf(shutter.midX > finder.frame.midX, "Device stayed in right-shutter wide configuration")
        capture(app, "wide-left-shutter-camera-ready")
        assertWideCameraAnchors(app, shutterOnRight: false, finderFrame: finder.frame)
        XCTAssertGreaterThanOrEqual(close.minX, finder.frame.maxX - 2)
        app.buttons["camera.close"].tap()
        XCTAssertTrue(app.buttons["library.import"].waitForExistence(timeout: 10))
    }

    @MainActor func testSideBySideWorkspaceInLandscape() throws {
        let app = try openEditor(.landscapeLeft)
        let window = app.windows.firstMatch.frame
        try XCTSkipIf(window.width <= window.height, "This device did not rotate to landscape")
        app.buttons["editor.tool.adjust"].tap()
        let slider = app.sliders["tone.exposure"]
        XCTAssertTrue(slider.waitForExistence(timeout: 5))
        let tools = EditorToolIDs.all.map { app.buttons[$0].frame }
        // Tools run top to bottom on the trailing edge, beside the controls, beside the photo.
        XCTAssertEqual(Set(tools.map { Int($0.midX) }).count, 1, "Tools are not in one column")
        XCTAssertEqual(tools.map(\.minY), tools.map(\.minY).sorted())
        XCTAssertGreaterThan(tools[0].minX, slider.frame.maxX)
        XCTAssertGreaterThan(slider.frame.minX, app.images["Edited photo"].frame.midX)
        XCTAssertFalse(app.buttons["editor.expand"].exists, "A full-height column has nothing to expand")
        // Section pills stay in a row above the controls.
        let pills = ["exposure", "liftGain", "color"].map { app.buttons["adjust.section." + $0].frame }
        XCTAssertEqual(pills.map(\.minX), pills.map(\.minX).sorted())
        XCTAssertLessThan(pills[0].maxY, slider.frame.minY)
        tour(app, prefix: "wide-")
    }

    @MainActor func testStackedWorkspaceInPortrait() throws {
        let app = try openEditor(.portrait)
        let window = app.windows.firstMatch.frame
        try XCTSkipIf(window.width >= window.height, "This device did not rotate to portrait")
        app.buttons["editor.tool.adjust"].tap()
        let slider = app.sliders["tone.exposure"]
        XCTAssertTrue(slider.waitForExistence(timeout: 5))
        let tools = EditorToolIDs.all.map { app.buttons[$0].frame }
        XCTAssertEqual(tools.map(\.minX), tools.map(\.minX).sorted())
        XCTAssertTrue(app.buttons["editor.expand"].exists)
        XCTAssertGreaterThan(slider.frame.minY, app.images["Edited photo"].frame.minY)
        tour(app, prefix: "tall-")
    }
}

private enum EditorToolIDs {
    static let all = ["crop", "develop", "adjust", "effects"].map { "editor.tool." + $0 }
}
