import XCTest

/// Native gestures catch integration faults that pixel/reference checks cannot observe.
final class EditorInteractionTests: XCTestCase {
    @MainActor func testHorizontalCameraExposureControl() {
        let app = XCUIApplication(bundleIdentifier: "io.github.runzeni.spektracam")
        app.launchArguments = ["--ui-test-camera-controls"]
        app.launch()
        let slider = app.sliders["camera.exposure"]
        XCTAssertTrue(slider.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(slider.frame.width, slider.frame.height * 3)
        let reset = app.buttons["camera.exposureReset"]
        XCTAssertEqual(reset.value as? String, "+0.00 EV")
        drag(slider, to: 0.8)
        XCTAssertGreaterThanOrEqual(reset.frame.height, 44)
        let value = reset.value as? String ?? ""
        XCTAssertTrue(value.hasPrefix("+"))
        XCTAssertNotEqual(value, "+0.00 EV")
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "Horizontal camera EV control at narrow width"
        capture.lifetime = .keepAlways
        add(capture)
        slider.doubleTap()
        XCTAssertEqual(reset.value as? String, "+0.00 EV")
        drag(slider, to: 0.2)
        XCTAssertTrue((reset.value as? String ?? "").hasPrefix("-"))
        let negative = XCTAttachment(screenshot: app.screenshot())
        negative.name = "Camera EV fills left from zero"
        negative.lifetime = .keepAlways
        add(negative)
        slider.doubleTap()
        XCTAssertEqual(reset.value as? String, "+0.00 EV")
    }
    @MainActor func testFormattingAndMeteringSwitchBounds() {
        let app = openPhoto()
        XCTAssertEqual(app.buttons["develop.mix.value"].value as? String, "100 %")
        app.buttons["editor.tool.adjust"].tap()
        if app.buttons["editor.expand"].value as? String == "Collapsed" { app.buttons["editor.expand"].tap() }
        XCTAssertEqual(app.buttons["tone.pivot.value"].value as? String, "0.35")
        app.descendants(matching: .any).matching(identifier: "adjust.exposureStages").firstMatch.tap()
        let toggle = app.descendants(matching: .any).matching(identifier: "camera.auto_exposure").firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(toggle.frame.maxX, app.scrollViews["editor.controls"].frame.maxX - 8)
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "Exposure metering controls and white selected tab"
        capture.lifetime = .keepAlways
        add(capture)
        app.buttons["adjust.section.color"].tap()
        if app.buttons["source.warmth.value"].exists {
            XCTAssertEqual(app.buttons["source.warmth.value"].value as? String, "0")
        }
    }

    @MainActor func testNewEditDefaultsInInformation() {
        let app = importPhoto()
        app.buttons["library.select"].tap()
        libraryPhotos(app).firstMatch.tap()
        let selected = XCTAttachment(screenshot: app.screenshot())
        selected.name = "Accent selection with white checkmark"
        selected.lifetime = .keepAlways
        add(selected)
        app.buttons["library.select"].tap()
        func setToggle(_ key: String, to value: String) {
            let toggle = app.switches[key]
            XCTAssertTrue(toggle.exists)
            if toggle.value as? String != value {
                // A native List switch exposes the entire label row as its AX frame.
                toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
            }
            expectation(for: NSPredicate(format: "value == %@", value), evaluatedWith: toggle)
            waitForExpectations(timeout: 3)
        }
        func information() {
            app.buttons["library.info"].tap()
            for _ in 0..<5 {
                if app.switches["about.defaultGrain"].isHittable { break }
                app.swipeUp()
            }
        }
        information()
        let keys = ["about.defaultHalation", "about.defaultGrain", "about.defaultMonochromeGrain"]
        let previous = keys.map { app.switches[$0].value as? String ?? "0" }
        for (key, desired) in zip(keys, ["0", "0", "1"]) {
            setToggle(key, to: desired)
        }
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "New edit effect defaults"
        capture.lifetime = .keepAlways
        add(capture)
        app.buttons["Done"].tap()
        libraryPhotos(app).firstMatch.tap()
        app.buttons["photo.develop"].tap()
        XCTAssertTrue(app.buttons["develop.mode.spektrafilm"].waitForExistence(timeout: 20))
        app.buttons["develop.mode.spektrafilm"].tap()
        app.buttons["editor.tool.effects"].tap()
        for (key, desired) in [("film_render.grain.active", "0"), ("grain.monochrome", "1")] {
            XCTAssertEqual(app.descendants(matching: .any).matching(identifier: key).firstMatch.value as? String, desired)
        }
        app.buttons["editor.back"].tap()
        XCTAssertTrue(app.buttons["photo.develop"].waitForExistence(timeout: 20))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["library.info"].waitForExistence(timeout: 10))
        information()
        for (key, value) in zip(keys, previous) {
            setToggle(key, to: value)
        }
        app.buttons["Done"].tap()
    }
    @MainActor func testNeutralEntryAndUniformPhotoActions() {
        let app = openPhoto(activateLook: false, expanded: false)
        let film = app.buttons["develop.mode.spektrafilm"]
        let lut = app.buttons["develop.mode.lut"]
        XCTAssertEqual(app.buttons["editor.expand"].value as? String, "Collapsed")
        XCTAssertFalse(film.isSelected)
        XCTAssertFalse(lut.isSelected)
        XCTAssertTrue(app.buttons["editor.info"].label.contains("Original"))
        let camera = app.buttons["camera.open"]
        for identifier in ["editor.compare", "editor.back", "editor.history"] {
            XCTAssertEqual(app.buttons[identifier].frame.width, camera.frame.width, accuracy: 2, identifier)
            XCTAssertEqual(app.buttons[identifier].frame.height, camera.frame.height, accuracy: 2, identifier)
        }
        let neutral = XCTAttachment(screenshot: app.screenshot())
        neutral.name = "Neutral collapsed editor with uniform actions"
        neutral.lifetime = .keepAlways
        add(neutral)
        film.tap()
        XCTAssertTrue(film.isSelected)
        app.buttons["editor.history"].tap()
        app.buttons["Undo"].tap()
        XCTAssertFalse(film.isSelected)
        app.buttons["editor.back"].tap()
        XCTAssertTrue(app.buttons["photo.develop"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["photo.revert"].isEnabled, "Opening an editor must not save a default look")
        let viewerBack = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertEqual(viewerBack.frame.height, app.buttons["camera.open"].frame.height, accuracy: 1)
        for identifier in ["photo.export", "photo.revert", "photo.delete"] {
            XCTAssertEqual(app.buttons[identifier].frame.width, app.buttons["camera.open"].frame.width, accuracy: 1)
            XCTAssertEqual(app.buttons[identifier].frame.height, app.buttons["camera.open"].frame.height, accuracy: 1)
        }
        XCTAssertEqual(app.buttons["photo.develop"].frame.height, app.buttons["camera.open"].frame.height, accuracy: 1)
        let viewer = XCTAttachment(screenshot: app.screenshot())
        viewer.name = "Uniform photo page actions"
        viewer.lifetime = .keepAlways
        add(viewer)
    }

    @MainActor func testFilesImportFromInformation() {
        let app = importPhoto()
        let camera = app.buttons["camera.open"]
        let delete = app.buttons["library.delete"]
        XCTAssertLessThan(camera.frame.maxY, delete.frame.minY)
        XCTAssertEqual(camera.frame.midX, delete.frame.midX, accuracy: 2)
        XCTAssertGreaterThan(camera.frame.width, delete.frame.width)
        app.buttons["library.info"].tap()
        let files = app.buttons["about.importFiles"]
        XCTAssertTrue(files.waitForExistence(timeout: 5))
        files.tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 10))
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "Files import from library settings"
        capture.lifetime = .keepAlways
        add(capture)
    }

    /// Run on the isolated simulator with enough synthetic Photos fixtures to scroll.
    @MainActor func testPickerReturnsToRecentAndRetainsImportedChecks() {
        let app = importPhoto()
        app.buttons["library.import"].tap()
        let cells = app.images.matching(identifier: "PXGGridLayout-Info")
        XCTAssertTrue(cells.firstMatch.waitForExistence(timeout: 10))
        func visibleCells() -> [XCUIElement] {
            let area = CGRect(x: 0, y: 150, width: app.frame.width, height: app.frame.height - 270)
            return cells.allElementsBoundByIndex.filter {
                let frame = $0.frame
                return frame.width > 50 && area.contains(CGPoint(x: frame.midX, y: frame.midY))
            }.sorted { a, b in a.frame.minY == b.frame.minY ? a.frame.minX < b.frame.minX : a.frame.minY < b.frame.minY }
        }
        let recent = visibleCells().first!
        let recentLabel = recent.label
        for _ in 0..<6 { app.swipeUp() }
        let old = visibleCells().last!
        let oldLabel = old.label
        XCTAssertNotEqual(recentLabel, oldLabel)
        old.tap()
        app.navigationBars["Photos"].buttons["Done"].tap()
        XCTAssertTrue(app.buttons["library.import"].waitForExistence(timeout: 15))
        expectation(for: NSPredicate(format: "label == %@", "2 photos"), evaluatedWith: app.staticTexts["library.count"])
        waitForExpectations(timeout: 20)
        app.buttons["library.import"].tap()
        let returnedRecent = cells.matching(NSPredicate(format: "label == %@", recentLabel)).firstMatch
        XCTAssertTrue(returnedRecent.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(returnedRecent.isHittable, "Picker reopened at the older selected photo")
        let initial = XCTAttachment(screenshot: app.screenshot())
        initial.name = "Picker reopens at recent photos"
        initial.lifetime = .keepAlways
        add(initial)
        for _ in 0..<6 { app.swipeUp() }
        let checked = cells.matching(NSPredicate(format: "label == %@", oldLabel)).firstMatch
        XCTAssertTrue(checked.waitForExistence(timeout: 5))
        print("IMPORTED PICKER ITEM", checked.debugDescription)
        XCTAssertTrue(checked.isSelected, "Previously imported photo lost its checked marker")
        let selection = XCTAttachment(screenshot: app.screenshot())
        selection.name = "Older imported photo remains checked"
        selection.lifetime = .keepAlways
        add(selection)
    }

    @MainActor func testCameraLibraryReturnsToLatestAfterScrolling() {
        let app = importPhoto()
        app.buttons["library.import"].tap()
        let cells = app.images.matching(identifier: "PXGGridLayout-Info")
        XCTAssertTrue(cells.firstMatch.waitForExistence(timeout: 10))
        var added = 0
        for _ in 0..<5 {
            let area = CGRect(x: 0, y: 150, width: app.frame.width, height: app.frame.height - 270)
            let visible = cells.allElementsBoundByIndex.filter {
                let frame = $0.frame
                return frame.width > 50 && area.contains(CGPoint(x: frame.midX, y: frame.midY))
            }
            for cell in visible where !cell.isSelected {
                cell.tap()
                added += 1
                if added == 18 { break }
            }
            if added == 18 { break }
            app.swipeUp()
        }
        XCTAssertEqual(added, 18, "Seed the isolated simulator with the synthetic picker fixtures")
        app.navigationBars["Photos"].buttons["Done"].tap()
        // Duplicate imports are intentionally skipped; this test needs a scrollable library.
        expectation(for: NSPredicate(block: { _, _ in
            Int(app.staticTexts["library.count"].label.split(separator: " ").first ?? "0") ?? 0 >= 15
        }), evaluatedWith: app)
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: app.buttons["library.import"])
        waitForExpectations(timeout: 30)
        let latestID = libraryPhotos(app).firstMatch.identifier
        let initialY = app.buttons[latestID].frame.minY
        for _ in 0..<4 { app.swipeUp() }
        XCTAssertTrue(!app.buttons[latestID].exists || app.buttons[latestID].frame.minY < initialY - 10)
        app.buttons["camera.open"].tap()
        XCTAssertTrue(app.buttons["camera.library"].waitForExistence(timeout: 10))
        app.buttons["camera.library"].tap()
        let latest = app.buttons[latestID]
        XCTAssertTrue(latest.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(latest.frame.minY, 100)
        XCTAssertEqual(latest.frame.minY, initialY, accuracy: 1)
        XCTAssertLessThan(latest.frame.maxY, app.frame.height / 2)
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "Camera returns to top of newest-first library"
        capture.lifetime = .keepAlways
        add(capture)
    }

    @MainActor func testPreviewSettingsAndBatchExport() {
        let app = importPhoto(count: 2)
        app.buttons["library.info"].tap()
        let library = app.buttons["about.libraryPreview"]
        let editor = app.buttons["about.editorPreview"]
        for _ in 0..<3 where !editor.isHittable { app.swipeUp() }
        XCTAssertTrue(library.waitForExistence(timeout: 5))
        XCTAssertTrue(editor.exists)
        library.tap()
        app.buttons["720 px"].tap()
        editor.tap()
        app.buttons["2,160 px"].tap()
        let settings = XCTAttachment(screenshot: app.screenshot())
        settings.name = "Independent library and editor preview settings"
        settings.lifetime = .keepAlways
        add(settings)
        app.buttons["Done"].tap()
        app.buttons["library.select"].tap()
        XCTAssertFalse(app.buttons["library.export"].isEnabled)
        libraryPhotos(app).element(boundBy: 0).tap()
        libraryPhotos(app).element(boundBy: 1).tap()
        XCTAssertTrue(app.buttons["library.export"].isEnabled)
        XCTAssertLessThan(app.buttons["library.export"].frame.midX, app.buttons["library.revert"].frame.midX)
        app.buttons["library.export"].tap()
        XCTAssertTrue(app.buttons["batch.prepareShare"].waitForExistence(timeout: 10))
        app.buttons["Percent"].tap()
        app.buttons["25 %"].tap()
        app.buttons["batch.prepareShare"].tap()
        let ready = app.buttons["batch.share"]
        XCTAssertTrue(ready.waitForExistence(timeout: 45))
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: ready)
        waitForExpectations(timeout: 45)
        XCTAssertEqual(app.staticTexts.matching(identifier: "Ready to share").count, 2)
        let batch = XCTAttachment(screenshot: app.screenshot())
        batch.name = "Sequential batch export ready to share"
        batch.lifetime = .keepAlways
        add(batch)
        app.buttons["Done"].tap()
        // Restore defaults for other tests; these preferences are separate from the test library.
        app.buttons["library.select"].tap()
        app.buttons["library.info"].tap()
        for _ in 0..<3 where !editor.isHittable { app.swipeUp() }
        app.buttons["about.libraryPreview"].tap(); app.buttons["1,080 px"].tap()
        app.buttons["about.editorPreview"].tap(); app.buttons["1,080 px"].tap()
    }
    @MainActor func testStraightenDragAndPanelReentry() {
        let app = openPhoto()
        XCTAssertEqual(app.buttons["editor.expand"].value as? String, "Expanded")
        app.buttons["editor.tool.crop"].tap()
        let slider = app.sliders["crop.straighten"]
        XCTAssertTrue(slider.waitForExistence(timeout: 5))
        drag(slider, to: 0.65)
        XCTAssertFalse((slider.value as? String ?? "").hasPrefix("-45"))
        drag(slider, to: 0.35)
        let left = slider.value as? String
        drag(slider, to: 0.6)
        XCTAssertNotEqual(slider.value as? String, left)
        app.buttons["editor.tool.develop"].tap()
        XCTAssertEqual(app.buttons["editor.expand"].value as? String, "Collapsed")
    }
    @MainActor func testChineseLocalizationPanels() {
        let app = importPhoto()
        app.terminate()
        app.launchArguments = [
            "--ui-test-library", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
        ]
        app.launch()
        XCTAssertTrue(app.navigationBars["图库"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["library.count"].label, "1 张照片")
        app.buttons["library.info"].tap()
        XCTAssertTrue(app.buttons["about.language"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["about.language"].label.contains("简体中文"))
        XCTAssertTrue(app.staticTexts["语言"].exists)
        let about = XCTAttachment(screenshot: app.screenshot())
        about.name = "Chinese About and language"
        about.lifetime = .keepAlways
        add(about)
        app.buttons["完成"].tap()
        libraryPhotos(app).firstMatch.tap()
        XCTAssertTrue(app.buttons["photo.develop"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.buttons["photo.develop"].label, "冲洗")
        let photo = app.images["照片"]
        XCTAssertTrue(photo.waitForExistence(timeout: 15))
        XCTAssertEqual(photo.value as? String, "缩放 100%")
        app.buttons["photo.develop"].tap()
        XCTAssertTrue(app.buttons["editor.tool.develop"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["印相"].exists)
        let develop = XCTAttachment(screenshot: app.screenshot())
        develop.name = "Chinese Develop"
        develop.lifetime = .keepAlways
        add(develop)
        app.buttons["editor.tool.adjust"].tap()
        XCTAssertTrue(app.buttons["高光/阴影"].waitForExistence(timeout: 5))
        app.buttons["高光/阴影"].tap()
        XCTAssertTrue(app.sliders["tone.highlights"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["高光"].exists)
        XCTAssertEqual(app.buttons["adjust.liftGainRange"].label, "切换高光和阴影范围")
        XCTAssertEqual(app.buttons["adjust.liftGainRange"].value as? String, "±2")
        app.buttons["editor.tool.crop"].tap()
        let area = app.otherElements["crop.area"]
        XCTAssertTrue(area.waitForExistence(timeout: 5))
        XCTAssertTrue((area.value as? String ?? "").contains("100%"))
        XCTAssertFalse((area.value as? String ?? "").contains("百分之"))
        app.buttons["editor.export"].tap()
        XCTAssertTrue(app.navigationBars["暗房"].waitForExistence(timeout: 5))
        app.buttons["darkroom.export"].tap()
        XCTAssertTrue(app.buttons["export.save"].waitForExistence(timeout: 45))
        XCTAssertTrue(app.buttons["export.save"].label.contains("照片"))
        XCTAssertEqual(app.buttons["export.share"].label, "共享")
        let exported = XCTAttachment(screenshot: app.screenshot())
        exported.name = "Chinese Export"
        exported.lifetime = .keepAlways
        add(exported)
    }

    @MainActor func testNativeLanguageSettingsPage() {
        let app = openPhoto()
        app.buttons["editor.tool.adjust"].tap()
        drag(app.sliders["tone.exposure"], to: 0.6)
        let savedExposure = app.buttons["tone.exposure.value"].value as? String
        app.buttons["editor.back"].tap()
        app.terminate()
        app.launchArguments = ["--ui-test-library"]
        app.launch()
        app.buttons["library.info"].tap()
        app.buttons["about.language"].tap()
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        XCTAssertTrue(settings.wait(for: .runningForeground, timeout: 10))
        print("NATIVE APP SETTINGS", settings.debugDescription)
        let capture = XCTAttachment(screenshot: settings.screenshot())
        capture.name = "Native app language settings"
        capture.lifetime = .keepAlways
        add(capture)
        if !settings.staticTexts["Language"].waitForExistence(timeout: 3) {
            for _ in 0..<8 {
                let apps = settings.buttons["Apps"]
                if apps.exists && apps.isHittable {
                    apps.tap()
                    break
                }
                let cell = settings.cells.containing(.staticText, identifier: "Apps").firstMatch
                if cell.exists && cell.isHittable {
                    cell.tap()
                    break
                }
                settings.swipeUp()
            }
            print("SETTINGS APPS", settings.debugDescription)
            let bundleRow = settings.buttons["io.github.runzeni.spektracam"]
            if bundleRow.waitForExistence(timeout: 2) {
                bundleRow.tap()
            } else {
                let spektra = settings.staticTexts["SpektraCam"].firstMatch
                if !spektra.waitForExistence(timeout: 2) {
                    let search = settings.searchFields.firstMatch
                    if search.exists {
                        search.tap()
                        search.typeText("SpektraCam")
                    }
                }
                if bundleRow.waitForExistence(timeout: 3) {
                    bundleRow.tap()
                } else if spektra.waitForExistence(timeout: 5) {
                    spektra.tap()
                }
            }
        }
        print("SETTINGS APP PAGE", settings.debugDescription)
        let page = XCTAttachment(screenshot: settings.screenshot())
        page.name = "SpektraCam Settings page"
        page.lifetime = .keepAlways
        add(page)
        let language = settings.staticTexts["Language"]
        XCTAssertTrue(language.waitForExistence(timeout: 5))
        language.tap()
        XCTAssertTrue(settings.staticTexts["English"].waitForExistence(timeout: 5))
        XCTAssertTrue(settings.staticTexts["简体中文"].exists)
        let choices = XCTAttachment(screenshot: settings.screenshot())
        choices.name = "Native English and Chinese choices"
        choices.lifetime = .keepAlways
        add(choices)
        settings.staticTexts["简体中文"].tap()
        app.terminate()
        app.launch()
        XCTAssertTrue(app.navigationBars["图库"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts["library.count"].label, "1 张照片")
        let switched = XCTAttachment(screenshot: app.screenshot())
        switched.name = "Chinese selected in native Settings"
        switched.lifetime = .keepAlways
        add(switched)
        settings.activate()
        if !settings.staticTexts["English"].exists {
            settings.staticTexts["Language"].tap()
        }
        XCTAssertTrue(settings.staticTexts["English"].waitForExistence(timeout: 5))
        settings.staticTexts["English"].tap()
        app.terminate()
        app.launch()
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts["library.count"].label, "1 photo")
        libraryPhotos(app).firstMatch.tap()
        app.buttons["photo.develop"].tap()
        XCTAssertTrue(app.buttons["editor.tool.adjust"].waitForExistence(timeout: 30))
        app.buttons["editor.tool.adjust"].tap()
        XCTAssertEqual(app.buttons["tone.exposure.value"].value as? String, savedExposure)
    }

    @MainActor func testChineseLargeTextEffectSwitchFits() {
        let app = importPhoto()
        app.terminate()
        app.launchArguments = [
            "--ui-test-library", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
        ]
        app.launch()
        XCTAssertTrue(libraryPhotos(app).firstMatch.waitForExistence(timeout: 10))
        libraryPhotos(app).firstMatch.tap()
        app.buttons["photo.develop"].tap()
        XCTAssertTrue(app.buttons["editor.tool.effects"].waitForExistence(timeout: 30))
        app.buttons["editor.tool.effects"].tap()
        let toggle = app.descendants(matching: .any).matching(
            identifier: "film_render.grain.active"
        ).firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(toggle.frame.maxX, app.frame.maxX - 8)
        XCTAssertGreaterThanOrEqual(toggle.frame.minX, app.frame.minX + 8)
        XCTAssertTrue(app.staticTexts["颗粒"].exists)
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "Chinese large-text effects"
        capture.lifetime = .keepAlways
        add(capture)
    }

    @MainActor func testAboutLinks() {
        let app = importPhoto()
        XCTAssertEqual(app.staticTexts["library.count"].label, "1 photo")
        app.buttons["library.info"].tap()
        let importFiles = app.descendants(matching: .any)["about.importFiles"]
        let recentlyDeleted = app.descendants(matching: .any)["about.recentlyDeleted"]
        XCTAssertTrue(importFiles.waitForExistence(timeout: 5))
        XCTAssertTrue(recentlyDeleted.exists)
        let language = app.descendants(matching: .any)["about.language"]
        XCTAssertTrue(language.waitForExistence(timeout: 5))
        XCTAssertLessThan(recentlyDeleted.frame.maxY, language.frame.minY)
        XCTAssertTrue(
            app.staticTexts["All editing features are free."].exists
                || app.staticTexts["Free and open source. All editing features are free."].exists)
        // Authors moved immediately above Legal; App Review requires Legal privacy/support/licenses.
        let licenses = app.descendants(matching: .any)["about.licenses"]
        for _ in 0..<6 where !licenses.isHittable { app.swipeUp() }
        let runze = app.descendants(matching: .any)["Runze · Website"]
        let spektrafilm = app.descendants(matching: .any)["Andrea Volpato · Spektrafilm"]
        let project = app.descendants(matching: .any)["SpektraCam · Project"]
        let privacy = app.descendants(matching: .any)["about.privacy"]
        let support = app.descendants(matching: .any)["about.support"]
        XCTAssertTrue(runze.waitForExistence(timeout: 5))
        XCTAssertTrue(spektrafilm.exists)
        XCTAssertTrue(project.exists)
        XCTAssertTrue(privacy.exists)
        XCTAssertTrue(support.exists)
        XCTAssertLessThan(spektrafilm.frame.maxY, privacy.frame.minY, "Authors must appear immediately above Legal")
        let defaultMonoGrain = app.descendants(matching: .any)["about.defaultMonochromeGrain"]
        if defaultMonoGrain.exists {
            XCTAssertLessThan(defaultMonoGrain.frame.maxY, spektrafilm.frame.minY, "Authors must appear below New edit defaults")
        }
        licenses.tap()
        app.buttons["SpektraCam · GPLv3"].tap()
        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "GNU GENERAL PUBLIC LICENSE"))
                .firstMatch.waitForExistence(timeout: 5))
    }
    @MainActor func testPhotoRevertAndControls() {
        let app = openPhoto()
        app.buttons["editor.tool.adjust"].tap()
        drag(app.sliders["tone.exposure"], to: 0.6)
        app.buttons["editor.back"].tap()
        let revert = app.buttons["photo.revert"]
        XCTAssertTrue(revert.waitForExistence(timeout: 10))
        XCTAssertTrue(revert.isEnabled)
        XCTAssertEqual(
            app.buttons["photo.export"].frame.height, app.buttons["photo.delete"].frame.height,
            accuracy: 2)
        XCTAssertLessThan(revert.frame.maxX, app.buttons["photo.delete"].frame.minX)
        revert.tap()
        let revertAction = app.buttons["photo.revert.menuAction"]
        XCTAssertTrue(revertAction.waitForExistence(timeout: 5))
        revertAction.tap()
        let confirm = app.buttons["Revert to Original"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        if app.buttons["Cancel"].exists {
            app.buttons["Cancel"].tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        }
        XCTAssertTrue(revert.isEnabled)
        revert.tap()
        XCTAssertTrue(revertAction.waitForExistence(timeout: 5))
        revertAction.tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        expectation(for: NSPredicate(format: "isEnabled == false"), evaluatedWith: revert)
        waitForExpectations(timeout: 10)
    }
    @MainActor func testStraightenedCropCanReframe() throws {
        let app = openPhoto()
        app.buttons["editor.tool.crop"].tap()
        let slider = app.sliders["crop.straighten"]
        XCTAssertTrue(slider.waitForExistence(timeout: 5))
        drag(slider, to: 0.65)
        let area = app.otherElements["crop.area"]
        XCTAssertTrue(area.waitForExistence(timeout: 5))
        // A straightened square fills its frame exactly, so there is nothing to reframe.
        try XCTSkipIf(
            abs(area.frame.width - area.frame.height) < 2,
            "Needs a non-square first photo in the test Simulator")
        let before = area.value as? String
        area.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(
            forDuration: 0.1,
            thenDragTo: area.coordinate(withNormalizedOffset: CGVector(dx: 0.56, dy: 0.53)))
        XCTAssertNotEqual(area.value as? String, before)
        let framing = (area.value as? String ?? "").components(separatedBy: "framing ").last!.split(
            separator: ",")
        if framing.count == 2, let x = Double(framing[0].trimmingCharacters(in: .whitespaces)),
            let y = Double(framing[1].trimmingCharacters(in: .whitespaces))
        {
            XCTAssertGreaterThan(
                x * 0.06 * area.frame.width * area.frame.width + y * 0.03 * area.frame.height
                    * area.frame.height, 0,
                "Photo moved against the drag direction")
        } else {
            XCTFail("Missing framing accessibility value")
        }
    }
    @MainActor func testLargeTextEffectSwitchFits() {
        let app = importPhoto()
        app.terminate()
        app.launchArguments = [
            "--ui-test-library", "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL",
        ]
        app.launch()
        let photo = libraryPhotos(app).firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 10))
        photo.tap()
        app.buttons["photo.develop"].tap()
        XCTAssertTrue(app.buttons["editor.tool.effects"].waitForExistence(timeout: 30))
        app.buttons["editor.tool.effects"].tap()
        let toggle = app.descendants(matching: .any).matching(
            identifier: "film_render.grain.active"
        ).firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(toggle.frame.maxX, app.frame.maxX - 8)
        XCTAssertGreaterThanOrEqual(toggle.frame.minX, app.frame.minX + 8)
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "Large-text adaptive effect switch"
        capture.lifetime = .keepAlways
        add(capture)
    }
    @MainActor func testPhotoPinchThenPage() {
        let app = importPhoto(count: 2)
        let secondID = libraryPhotos(app).element(boundBy: 1).identifier.replacingOccurrences(
            of: "library.photo.", with: "")
        libraryPhotos(app).element(boundBy: 0).tap()
        let image = app.images["Photo"]
        XCTAssertTrue(image.waitForExistence(timeout: 10))
        image.pinch(withScale: 2, velocity: 1)
        expectation(
            for: NSPredicate(format: "value != %@", "100 percent zoom"), evaluatedWith: image)
        waitForExpectations(timeout: 5)
        // Once zoomed, XCTest generates a full-window pinch that starts on the floating
        // controls. Use the native double-tap fit gesture before checking paging handoff.
        image.doubleTap()
        expectation(
            for: NSPredicate(format: "value == %@", "100 percent zoom"), evaluatedWith: image)
        waitForExpectations(timeout: 5)
        // The grid opens at the newest item; the viewer's chronological previous page is to the right.
        image.swipeRight()
        expectation(
            for: NSPredicate(format: "isSelected == true"),
            evaluatedWith: app.buttons["photo.filmstrip." + secondID])
        waitForExpectations(timeout: 5)
    }
    @MainActor func testCancelledPhotoSwipeSettles() {
        let app = importPhoto(count: 2)
        let id = libraryPhotos(app).element(boundBy: 0).identifier.replacingOccurrences(
            of: "library.photo.", with: "")
        libraryPhotos(app).element(boundBy: 0).tap()
        let image = app.images["Photo"]
        XCTAssertTrue(image.waitForExistence(timeout: 10))
        for _ in 0..<3 {
            image.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(
                forDuration: 0.1,
                thenDragTo: image.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5)),
                withVelocity: .slow, thenHoldForDuration: 0.4)
            XCTAssertTrue(app.buttons["photo.filmstrip." + id].isSelected)
            XCTAssertEqual(
                image.frame.midX, app.frame.midX, accuracy: 2, "Cancelled swipe left a partial page"
            )
        }
        image.swipeRight()
        image.swipeLeft()
        XCTAssertTrue(app.buttons["photo.filmstrip." + id].isSelected)
        XCTAssertEqual(image.frame.midX, app.frame.midX, accuracy: 2)
    }
    @MainActor func testLUTManagerPresentation() throws {
        let app = importPhoto()
        let manager = app.buttons["library.formulae"]
        XCTAssertTrue(manager.waitForExistence(timeout: 5))
        XCTAssertLessThan(app.staticTexts["library.count"].frame.maxY, manager.frame.minY)
        manager.tap()
        // Formulae lead; the LUTs are the second tab of the same sheet.
        XCTAssertTrue(app.buttons["formula.library.close"].waitForExistence(timeout: 5))
        app.segmentedControls["manager.tab"].buttons["LUTs"].tap()
        XCTAssertTrue(app.buttons["lut.import"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["lut.delete"].isEnabled)
        XCTAssertFalse(
            app.buttons["lut.none"].exists, "Manager must not edit a photo's LUT assignment")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Shared LUT Manager"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["lut.library.close"].tap()
        XCTAssertTrue(manager.waitForExistence(timeout: 5))
    }
    @MainActor func testCameraPresentationKeepsEditor() throws {
        let app = importPhoto()
        app.buttons["camera.open"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["camera.unavailable"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["camera.shutter"].isEnabled)
        XCTAssertEqual(
            app.buttons["camera.shutter"].frame.midX, app.frame.midX, accuracy: 1,
            "The camera shutter is not centered")
        app.buttons["camera.library"].tap()
        XCTAssertTrue(app.buttons["library.import"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["camera.close"].exists)
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'library.photo.'"))
            .firstMatch.tap()
        XCTAssertTrue(app.buttons["photo.develop"].waitForExistence(timeout: 10))
        app.buttons["camera.open"].tap()
        XCTAssertTrue(app.buttons["camera.close"].waitForExistence(timeout: 5))
        app.buttons["camera.close"].tap()
        app.buttons["photo.develop"].tap()
        XCTAssertTrue(app.buttons["editor.back"].waitForExistence(timeout: 30))
        app.buttons["editor.expand"].tap()
        let panel = app.buttons["editor.expand"].value as? String
        XCTAssertEqual(panel, "Expanded")
        app.buttons["camera.open"].tap()
        XCTAssertTrue(app.buttons["camera.close"].waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Simulator camera unavailable"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["camera.close"].tap()
        XCTAssertTrue(app.buttons["editor.back"].waitForExistence(timeout: 10))
        XCTAssertEqual(
            app.buttons["editor.expand"].value as? String, panel,
            "Presenting the camera changed the editor panel")
    }
    @MainActor func testCameraLibraryReturnsToRoot() {
        let app = openPhoto()
        app.buttons["camera.open"].tap()
        XCTAssertTrue(app.buttons["camera.library"].waitForExistence(timeout: 10))
        app.buttons["camera.library"].tap()
        XCTAssertTrue(app.buttons["library.import"].waitForExistence(timeout: 10))
        XCTAssertEqual(libraryPhotos(app).firstMatch.value as? String, "Edited")
        XCTAssertFalse(app.buttons["editor.back"].exists)
        XCTAssertFalse(app.buttons["photo.develop"].exists)
        XCTAssertFalse(app.buttons["camera.close"].exists)
    }
    @MainActor func testRevertSelectedPhoto() throws {
        let app = openPhoto()
        app.buttons["editor.back"].tap()
        XCTAssertTrue(app.buttons["photo.develop"].waitForExistence(timeout: 30))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["library.select"].waitForExistence(timeout: 5))
        app.buttons["library.select"].tap()
        XCTAssertTrue(app.buttons["library.revert"].waitForExistence(timeout: 5))
        expectation(
            for: NSPredicate(format: "exists == false"),
            evaluatedWith: app.buttons["library.import"])
        waitForExpectations(timeout: 5)
        XCTAssertFalse(app.buttons["library.revert"].isEnabled)
        libraryPhotos(app).firstMatch.tap()
        XCTAssertTrue(app.buttons["library.revert"].isEnabled)
        app.buttons["library.revert"].tap()
        XCTAssertTrue(app.buttons["Revert to Original"].waitForExistence(timeout: 5))
        if app.buttons["Cancel"].exists {
            app.buttons["Cancel"].tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        }
        XCTAssertTrue(app.descendants(matching: .any)["photo.badge.edited"].exists)
        app.buttons["library.revert"].tap()
        app.buttons["Revert to Original"].tap()
        let original = NSPredicate(format: "value == %@", "Original")
        expectation(for: original, evaluatedWith: libraryPhotos(app).firstMatch)
        waitForExpectations(timeout: 10)
        XCTAssertFalse(app.descendants(matching: .any)["photo.badge.edited"].exists)
        app.buttons["library.select"].tap()
        XCTAssertTrue(app.buttons["library.import"].exists)
    }
    @MainActor func testNativeZoomAndGuardedExit() throws {
        let app = openPhoto()
        app.buttons["editor.tool.develop"].tap()
        let photo = app.images["Edited photo"]
        XCTAssertTrue(photo.waitForExistence(timeout: 30))
        let fit = NSPredicate(format: "value == %@", "100 percent zoom")
        expectation(for: fit, evaluatedWith: photo)
        waitForExpectations(timeout: 15)
        photo.doubleTap()
        let zoomed = NSPredicate(format: "value != %@", "100 percent zoom")
        expectation(for: zoomed, evaluatedWith: photo)
        waitForExpectations(timeout: 10)
        let compareZoom = photo.value as? String
        app.buttons["editor.compare"].tap()
        XCTAssertEqual(photo.value as? String, compareZoom, "Compare reset the zoom")
        app.buttons["editor.compare"].tap()
        XCTAssertEqual(photo.value as? String, compareZoom, "Returning to edits reset the zoom")
        let zoomImage = XCTAttachment(screenshot: app.screenshot())
        zoomImage.name = "Native double tap zoom"
        zoomImage.lifetime = .keepAlways
        add(zoomImage)
        let doubleTapValue = photo.value as? String
        photo.pinch(withScale: 1.2, velocity: 1)
        XCTAssertNotEqual(
            photo.value as? String, doubleTapValue, "Native pinch did not change zoom")
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(
                forDuration: 0.05,
                thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.4)))
        photo.doubleTap()
        expectation(for: fit, evaluatedWith: photo)
        waitForExpectations(timeout: 10)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.001, dy: 0.4))
            .press(
                forDuration: 0.05,
                thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.4)))
        XCTAssertTrue(
            app.buttons["editor.back"].exists, "Editing allowed an accidental navigation pop")
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "Native zoom and guarded exit"
        image.lifetime = .keepAlways
        add(image)
        // The interface follows the device and keeps the edit; portrait comes back as it was.
        let portraitPhoto = photo.frame
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["editor.back"].waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .portrait
        let restored = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in abs(photo.frame.width - portraitPhoto.width) < 1 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 5), .completed)
        app.buttons["editor.back"].tap()
        XCTAssertTrue(app.buttons["photo.develop"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.sheets["Return to Photo?"].exists)
        XCTAssertFalse(app.buttons["editor.back"].exists)
    }
    @MainActor func testCompareKeepsCroppedZoom() {
        let app = openPhoto()
        app.buttons["editor.tool.crop"].tap()
        app.buttons["crop.ratio.square"].tap()
        app.buttons["editor.tool.adjust"].tap()
        app.buttons["editor.tool.adjust"].tap()
        let photo = app.images["Edited photo"]
        let square = NSPredicate { _, _ in abs(photo.frame.width - photo.frame.height) < 2 }
        expectation(for: square, evaluatedWith: photo)
        waitForExpectations(timeout: 15)
        photo.doubleTap()
        let zoomed = NSPredicate(format: "value != %@", "100 percent zoom")
        expectation(for: zoomed, evaluatedWith: photo)
        waitForExpectations(timeout: 10)
        let value = photo.value as? String
        XCTAssertLessThan(
            photo.frame.minY, app.buttons["editor.info"].frame.maxY,
            "Zoomed photo cannot extend behind the information panel")
        app.buttons["editor.compare"].tap()
        XCTAssertEqual(photo.value as? String, value, "Comparing an uncropped original reset zoom")
        app.buttons["editor.compare"].tap()
        XCTAssertEqual(photo.value as? String, value, "Returning to a crop reset zoom")
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "Cropped comparison preserves zoom behind glass"
        capture.lifetime = .keepAlways
        add(capture)
    }
    @MainActor private func importPhoto(count: Int = 1) -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(bundleIdentifier: "io.github.runzeni.spektracam")
        app.launchArguments = ["--ui-test-library", "--reset-test-library"]
        app.launch()
        XCTAssertTrue(app.buttons["library.import"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["library.delete"].isEnabled)
        app.buttons["library.import"].tap()
        if app.buttons["From Photos"].exists { app.buttons["From Photos"].tap() }
        // Prefer native picker elements. Some Simulator runs expose only its remote surface.
        let cells = app.images.matching(identifier: "PXGGridLayout-Info")
        let legacyCells = app.images.matching(NSPredicate(format: "label BEGINSWITH 'Photo,'"))
        if cells.firstMatch.waitForExistence(timeout: 5) {
            cells.element(boundBy: 0).tap()
            if count > 1 { cells.element(boundBy: 1).tap() }
        } else if legacyCells.firstMatch.waitForExistence(timeout: 3) {
            legacyCells.element(boundBy: 0).tap()
            if count > 1 { legacyCells.element(boundBy: 1).tap() }
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.167, dy: 0.24)).press(
                forDuration: 0.15)
            if count > 1 {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.24)).press(
                    forDuration: 0.15)
            }
        }
        let picked = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        picked.name = "System picker selection"
        picked.lifetime = .keepAlways
        self.add(picked)
        let done = app.navigationBars["Photos"].buttons["Done"]
        let add = app.navigationBars["Photos"].buttons["Add"]
        if done.exists {
            XCTAssertTrue(done.isEnabled)
            done.tap()
        } else if add.exists {
            XCTAssertTrue(add.isEnabled)
            add.tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.91, dy: 0.115)).press(
                forDuration: 0.15)
        }
        let photo = libraryPhotos(app).firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 30), app.debugDescription)
        return app
    }
    /// A physical thumb drag also checks the new native glass track, independent of AX value formatting.
    @MainActor private func drag(_ slider: XCUIElement, to position: CGFloat) {
        let current: CGFloat
        if let number = slider.value as? NSNumber {
            current = CGFloat(number.doubleValue)
        } else {
            let text = slider.value as? String ?? "50%"
            if text.contains("degrees"),
                let degrees = Double(text.replacingOccurrences(of: " degrees", with: ""))
            {
                current = CGFloat((degrees + 45) / 90)
            } else {
                let number =
                    Double(text.replacingOccurrences(of: "%", with: ""))
                    ?? (text.contains("%") ? 50 : 0.5)
                current = CGFloat(text.contains("%") ? number / 100 : number)
            }
        }
        slider.coordinate(withNormalizedOffset: CGVector(dx: current, dy: 0.5)).press(
            forDuration: 0.1,
            thenDragTo: slider.coordinate(withNormalizedOffset: CGVector(dx: position, dy: 0.5)),
            withVelocity: .slow, thenHoldForDuration: 0.1)
    }
    /// Scroll the editor panel until a control is wholly inside it. A collapsed panel clips the
    /// last control to a sliver that XCUITest still reports as hittable.
    @MainActor private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        let controls = app.descendants(matching: .any).matching(identifier: "editor.controls").firstMatch
        for _ in 0..<4 where element.frame.maxY > controls.frame.maxY - 8 {
            controls.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)).press(
                forDuration: 0.05,
                thenDragTo: controls.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)))
        }
    }
    @MainActor private func libraryPhotos(_ app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'library.photo.'"))
    }
    @MainActor private func openPhoto(activateLook: Bool = true, expanded: Bool = true) -> XCUIApplication {
        let app = importPhoto()
        libraryPhotos(app).firstMatch.tap()
        XCTAssertTrue(app.buttons["photo.develop"].waitForExistence(timeout: 10))
        app.buttons["photo.develop"].tap()
        XCTAssertTrue(app.buttons["editor.histogram"].waitForExistence(timeout: 30))
        if activateLook { app.buttons["develop.mode.spektrafilm"].tap() }
        if expanded && app.buttons["editor.expand"].value as? String == "Collapsed" {
            app.buttons["editor.expand"].tap()
        }
        return app
    }

    @MainActor func testLibraryRestartEditAndDelete() {
        let app = openPhoto()
        app.buttons["editor.tool.adjust"].tap()
        let slider = app.sliders["tone.exposure"]
        XCTAssertTrue(slider.waitForExistence(timeout: 5))
        drag(slider, to: 0.75)
        let savedValue = app.buttons["tone.exposure.value"].value as? String
        XCTAssertNotEqual(savedValue, "0.00 EV")
        // A recipe also survives termination without using the editor's Save action.
        Thread.sleep(forTimeInterval: 0.5)
        app.terminate()
        app.launchArguments = ["--ui-test-library"]
        app.launch()
        XCTAssertTrue(libraryPhotos(app).firstMatch.waitForExistence(timeout: 15))
        libraryPhotos(app).firstMatch.tap()
        app.buttons["photo.develop"].tap()
        XCTAssertTrue(app.buttons["editor.tool.adjust"].waitForExistence(timeout: 30))
        app.buttons["editor.tool.adjust"].tap()
        XCTAssertEqual(app.buttons["tone.exposure.value"].value as? String, savedValue)
        app.buttons["editor.back"].tap()
        XCTAssertTrue(app.buttons["photo.delete"].waitForExistence(timeout: 30))
        app.buttons["photo.delete"].tap()
        app.buttons["Delete App Copy"].tap()
        XCTAssertTrue(app.buttons["library.import"].waitForExistence(timeout: 10))
        XCTAssertEqual(libraryPhotos(app).count, 0)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["Your Library"].waitForExistence(timeout: 10))
        XCTAssertEqual(libraryPhotos(app).count, 0)
    }

    @MainActor func testLibraryFiltersSelectionAndOriginalExport() {
        let app = importPhoto()
        app.buttons["library.filter"].tap()
        app.buttons["RAW"].tap()
        // The seeded first asset is a rendered photo.
        XCTAssertTrue(app.staticTexts["No RAW Photos"].waitForExistence(timeout: 5))
        app.buttons["library.filter"].tap()
        app.buttons["All"].tap()
        XCTAssertTrue(libraryPhotos(app).firstMatch.waitForExistence(timeout: 5))
        app.buttons["library.select"].tap()
        XCTAssertFalse(app.buttons["library.delete"].isEnabled)
        libraryPhotos(app).firstMatch.tap()
        XCTAssertTrue(app.buttons["library.delete"].isEnabled)
        XCTAssertTrue(app.buttons["Cancel Selection"].exists)
        app.buttons["library.select"].tap()
        XCTAssertFalse(app.buttons["library.delete"].isEnabled)
        libraryPhotos(app).firstMatch.tap()
        app.buttons["photo.export"].tap()
        XCTAssertTrue(app.buttons["Percent"].waitForExistence(timeout: 10))
        app.buttons["Percent"].tap()
        app.buttons["25 %"].tap()
        XCTAssertTrue(app.buttons["export.save"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["export.save"].isHittable)
        XCTAssertTrue(app.buttons["export.share"].isHittable)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["photo.develop"].waitForExistence(timeout: 5))
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = "Photo view before development"
        image.lifetime = .keepAlways
        add(image)
    }

    @MainActor func testFilmstripAndEditedBadge() {
        let app = importPhoto(count: 2)
        XCTAssertEqual(app.staticTexts["library.count"].label, "2 photos")
        XCTAssertEqual(libraryPhotos(app).count, 2)
        let firstID = libraryPhotos(app).element(boundBy: 0).identifier.replacingOccurrences(
            of: "library.photo.", with: "")
        let secondID = libraryPhotos(app).element(boundBy: 1).identifier.replacingOccurrences(
            of: "library.photo.", with: "")
        libraryPhotos(app).element(boundBy: 0).tap()
        let first = app.buttons["photo.filmstrip." + firstID]
        let second = app.buttons["photo.filmstrip." + secondID]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCTAssertTrue(first.isSelected)
        app.images["Photo"].swipeRight()
        let selected = NSPredicate(format: "isSelected == true")
        expectation(for: selected, evaluatedWith: second)
        waitForExpectations(timeout: 10)
        XCTAssertTrue(second.isSelected)
        XCTAssertFalse(first.isSelected)
        for _ in 0..<5 {
            app.images["Photo"].swipeLeft()
            expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: first)
            waitForExpectations(timeout: 5)
            app.images["Photo"].swipeRight()
            expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: second)
            waitForExpectations(timeout: 5)
        }
        app.buttons["photo.develop"].tap()
        XCTAssertTrue(app.buttons["develop.mode.spektrafilm"].waitForExistence(timeout: 30))
        app.buttons["develop.mode.spektrafilm"].tap()
        app.buttons["editor.back"].tap()
        XCTAssertTrue(app.buttons["photo.develop"].waitForExistence(timeout: 30))
        XCTAssertEqual(second.value as? String, "Edited")
        app.navigationBars.buttons["BackButton"].tap()
        XCTAssertTrue(libraryPhotos(app).firstMatch.waitForExistence(timeout: 10))
        let edited = app.buttons["library.photo." + secondID]
        XCTAssertEqual(edited.value as? String, "Edited")
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Edited badge in gallery"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor func testPhotoInformationAndCanvasBounds() {
        let app = openPhoto()
        let info = app.buttons["editor.info"]
        XCTAssertTrue(info.waitForExistence(timeout: 10))
        let image = app.images["Edited photo"]
        XCTAssertTrue(image.waitForExistence(timeout: 20))
        XCTAssertEqual(info.value as? String, "Collapsed")
        let toolbar =
            ["crop", "develop", "adjust", "effects"].map { app.buttons["editor.tool." + $0] }
            + [app.buttons["editor.export"]]
        for button in toolbar {
            XCTAssertGreaterThanOrEqual(button.frame.width, 44, "Tool touch area is too narrow")
            XCTAssertEqual(button.frame.midY, toolbar[0].frame.midY, accuracy: 1)
        }
        // Native toolbar segments expose their 36 pt visual frame inside a 48 pt glass surface.
        // Check the required 44 pt touch height with physical taps outside that visual frame.
        for name in ["crop", "develop", "adjust", "effects"] {
            let button = app.buttons["editor.tool." + name]
            let center = button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            center.withOffset(CGVector(dx: 0, dy: -21)).tap()
            XCTAssertTrue(button.isSelected, "The native tool did not accept its upper touch edge")
            center.withOffset(CGVector(dx: 0, dy: 21)).tap()
            XCTAssertFalse(button.isSelected, "The native tool did not accept its lower touch edge")
        }
        app.buttons["editor.tool.develop"].tap()
        let before = image.frame
        XCTAssertEqual(before.minY, info.frame.maxY, accuracy: 2)
        XCTAssertLessThanOrEqual(before.maxY, app.buttons["editor.tool.develop"].frame.minY + 1)
        app.buttons["editor.histogram"].tap()
        XCTAssertEqual(info.value as? String, "Collapsed", "Histogram opened photo details")
        info.tap()
        XCTAssertEqual(info.value as? String, "Expanded")
        XCTAssertEqual(image.frame.minY, before.minY, accuracy: 1)
        XCTAssertEqual(image.frame.height, before.height, accuracy: 1)
        let editorImport = app.buttons["editor.formula.import"]
        let editorSave = app.buttons["editor.formula.save"]
        XCTAssertTrue(editorImport.waitForExistence(timeout: 5))
        XCTAssertTrue(editorSave.exists)
        XCTAssertLessThanOrEqual(editorImport.frame.maxX, editorSave.frame.minX + 1)
        let editorDetails = app.descendants(matching: .any).matching(identifier: "editor.photoDetails").firstMatch
        XCTAssertTrue(editorDetails.waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "editor.location").firstMatch.exists)
        editorDetails.tap()
        for row in ["location", "time", "camera", "lens", "exposure", "format", "colorSpace"] {
            XCTAssertTrue(
                app.descendants(matching: .any).matching(identifier: "editor." + row).firstMatch
                    .waitForExistence(timeout: 5), "Missing metadata row: " + row)
        }
        let editorColor = app.descendants(matching: .any).matching(identifier: "editor.colorSpace")
            .firstMatch
        XCTAssertTrue(editorColor.exists)
        if editorColor.frame.maxY > app.scrollViews["editor.details"].frame.maxY {
            app.scrollViews["editor.details"].swipeUp()
        }
        XCTAssertLessThanOrEqual(
            editorColor.frame.maxY, app.scrollViews["editor.details"].frame.maxY)
        let metadataCapture = XCTAttachment(screenshot: app.screenshot())
        metadataCapture.name = "All seven photo detail rows"
        metadataCapture.lifetime = .keepAlways
        add(metadataCapture)
        app.buttons["editor.histogram"].tap()
        XCTAssertEqual(info.value as? String, "Expanded", "Histogram closed photo details")
        info.tap()
        XCTAssertEqual(info.value as? String, "Collapsed")
        app.buttons["editor.tool.crop"].tap()
        XCTAssertFalse(app.buttons["editor.info"].exists)
        app.buttons["editor.back"].tap()
        XCTAssertTrue(app.buttons["photo.info"].waitForExistence(timeout: 30))
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "photo.banner.date").firstMatch
                .exists)
        let badge = app.images["photo.badge.edited"]
        XCTAssertTrue(badge.exists)
        XCTAssertLessThan(badge.frame.maxY, app.buttons["photo.info"].frame.minY)
        let viewerInfo = app.buttons["photo.info"]
        app.buttons["photo.histogram"].tap()
        XCTAssertEqual(viewerInfo.value as? String, "Collapsed")
        viewerInfo.tap()
        XCTAssertEqual(viewerInfo.value as? String, "Expanded")
        let photoImport = app.buttons["photo.formula.import"]
        let photoSave = app.buttons["photo.formula.save"]
        XCTAssertTrue(photoImport.waitForExistence(timeout: 5))
        XCTAssertTrue(photoSave.exists)
        XCTAssertLessThanOrEqual(photoImport.frame.maxX, photoSave.frame.minX + 1)
        let photoDetails = app.descendants(matching: .any).matching(identifier: "photo.photoDetails").firstMatch
        XCTAssertTrue(photoDetails.waitForExistence(timeout: 5))
        // Universal Photo Details disclosure state: expanded in Editor stays expanded in Viewer.
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "photo.location").firstMatch
                .waitForExistence(timeout: 5),
            "Universal Photo Details state did not persist from Editor to Viewer")
        let photoColor = app.descendants(matching: .any).matching(identifier: "photo.colorSpace")
            .firstMatch
        XCTAssertTrue(photoColor.waitForExistence(timeout: 5))
        if photoColor.frame.maxY > app.scrollViews["photo.details"].frame.maxY {
            app.scrollViews["photo.details"].swipeUp()
        }
        XCTAssertLessThanOrEqual(photoColor.frame.maxY, app.scrollViews["photo.details"].frame.maxY)
        photoDetails.tap()
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "photo.location").firstMatch
                .waitForNonExistence(timeout: 5))
    }

    @MainActor func testCollapsedAdjustmentsAndCouplerBounds() {
        let app = openPhoto()
        app.buttons["editor.tool.adjust"].tap()
        if app.buttons["editor.expand"].value as? String == "Expanded" {
            app.buttons["editor.expand"].tap()
        }
        let controls = app.scrollViews["editor.controls"]
        func assertVisible(_ identifiers: [String]) {
            for identifier in identifiers {
                let slider = app.sliders[identifier]
                XCTAssertTrue(slider.waitForExistence(timeout: 5))
                XCTAssertGreaterThanOrEqual(slider.frame.minY, controls.frame.minY)
                XCTAssertLessThanOrEqual(slider.frame.maxY, controls.frame.maxY)
                XCTAssertTrue(slider.isHittable, identifier)
            }
        }
        func capture(_ name: String) {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        app.buttons["adjust.section.liftGain"].tap()
        assertVisible(["tone.highlights", "tone.shadows"])
        capture("Collapsed Lift and Gain")
        app.buttons["adjust.section.color"].tap()
        assertVisible(["source.warmth", "source.tint", "source.saturation"])
        capture("Collapsed Color")

        app.buttons["editor.expand"].tap()
        app.buttons["Dye couplers"].tap()
        let details = app.buttons["film_render.dir_couplers.details"]
        XCTAssertTrue(details.waitForExistence(timeout: 5))
        if !details.isHittable { controls.swipeUp() }
        details.tap()
        let sliders = app.sliders.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "film_render.dir_couplers."))
        XCTAssertGreaterThan(sliders.count, 1)
        for slider in sliders.allElementsBoundByIndex {
            XCTAssertGreaterThanOrEqual(slider.frame.minX, controls.frame.minX)
            XCTAssertLessThanOrEqual(slider.frame.maxX, controls.frame.maxX)
        }
        controls.swipeUp()
        capture("Dye couplers Details")
    }

    @MainActor func testAdjustmentRangesAndColorOrder() {
        let app = openPhoto()
        app.buttons["editor.tool.adjust"].tap()
        XCTAssertEqual(app.buttons["adjust.section.exposure"].label, "Exposure/Contrast")
        app.buttons["adjust.section.liftGain"].tap()
        let range = app.buttons["adjust.liftGainRange"]
        XCTAssertTrue(range.waitForExistence(timeout: 5))
        XCTAssertEqual(range.value as? String, "±2")
        range.tap()
        XCTAssertEqual(range.value as? String, "±5")
        let shadow = app.sliders["tone.shadows"]
        drag(shadow, to: 0.95)
        let saved = app.buttons["tone.shadows.value"].value as? String
        XCTAssertNotNil(saved)
        XCTAssertGreaterThan(Double(saved?.trimmingCharacters(in: .whitespaces) ?? "0") ?? 0, 2)
        XCTAssertFalse(range.isEnabled, "Narrowing the range would hide the current edit")
        shadow.doubleTap()
        XCTAssertEqual(
            (app.buttons["tone.shadows.value"].value as? String)?.trimmingCharacters(
                in: .whitespaces), "0.0")
        XCTAssertTrue(range.isEnabled)
        range.tap()
        XCTAssertEqual(range.value as? String, "±2")
        if app.buttons["editor.expand"].value as? String == "Collapsed" {
            app.buttons["editor.expand"].tap()
        }
        app.buttons["adjust.section.color"].tap()
        let balance = app.buttons["Print balance"]
        let couplers = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "Dye couplers")
        ).firstMatch
        XCTAssertTrue(balance.waitForExistence(timeout: 5))
        XCTAssertLessThan(balance.frame.minY, couplers.frame.minY)
        balance.tap()
        let balanceRange = app.buttons["adjust.balanceRange"]
        XCTAssertTrue(balanceRange.waitForExistence(timeout: 5))
        XCTAssertEqual(balanceRange.value as? String, "±35 CC")
        balanceRange.tap()
        XCTAssertEqual(balanceRange.value as? String, "±100 CC")
        // Let the native title transition settle before visual capture.
        Thread.sleep(forTimeInterval: 0.8)
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "Shared native range controls"
        capture.lifetime = .keepAlways
        add(capture)
    }

    @MainActor func testGroupedPanelsAndSliderReset() {
        let app = openPhoto()
        XCTAssertEqual(app.buttons["editor.expand"].value as? String, "Expanded")
        let compare = app.buttons["editor.compare"]
        XCTAssertGreaterThanOrEqual(compare.frame.minY, app.buttons["editor.info"].frame.maxY)
        XCTAssertTrue(app.buttons["Camera"].exists)
        app.buttons["editor.tool.adjust"].tap()
        drag(app.sliders["tone.exposure"], to: 0.7)
        XCTAssertNotEqual(app.buttons["tone.exposure.value"].value as? String, "0.00 EV")
        app.buttons["editor.history"].tap()
        app.buttons["Undo"].tap()
        XCTAssertEqual(
            app.buttons["tone.exposure.value"].value as? String, "0.00 EV",
            "A drag must undo in one step")
        app.buttons["editor.expand"].tap()
        let contrast = app.sliders["tone.contrast"]
        XCTAssertTrue(contrast.waitForExistence(timeout: 5))
        drag(contrast, to: 0.8)
        XCTAssertNotEqual(
            (app.buttons["tone.contrast.value"].value as? String)?.trimmingCharacters(
                in: .whitespaces), "0.0")
        contrast.doubleTap()
        XCTAssertEqual(
            (app.buttons["tone.contrast.value"].value as? String)?.trimmingCharacters(
                in: .whitespaces), "0.0")
        XCTAssertEqual(app.buttons["editor.expand"].value as? String, "Expanded")
        app.images["Edited photo"].coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.02))
            .tap()
        XCTAssertTrue(
            XCTWaiter.wait(
                for: [
                    XCTNSPredicateExpectation(
                        predicate: NSPredicate(format: "value == %@", "Collapsed"),
                        object: app.buttons["editor.expand"])
                ], timeout: 3) == .completed)
        app.buttons["adjust.section.liftGain"].tap()
        XCTAssertTrue(app.sliders["tone.shadows"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.sliders["tone.highlights"].waitForExistence(timeout: 5))
        XCTAssertLessThan(
            app.sliders["tone.highlights"].frame.minY, app.sliders["tone.shadows"].frame.minY)
        app.buttons["adjust.section.color"].tap()
        let bw = app.descendants(matching: .any).matching(identifier: "tone.monochrome").firstMatch
        XCTAssertTrue(bw.waitForExistence(timeout: 5))
        reveal(bw, in: app)
        bw.tap()
        XCTAssertEqual(bw.value as? String, "1")
        app.buttons["editor.tool.effects"].tap()
        let grain = app.descendants(matching: .any).matching(identifier: "grain.monochrome")
            .firstMatch
        XCTAssertTrue(grain.waitForExistence(timeout: 5))
        reveal(grain, in: app)
        grain.tap()
        XCTAssertEqual(grain.value as? String, "1")
        app.buttons["effects.section.halation"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "film_render.halation.active")
                .firstMatch
                .waitForExistence(timeout: 5))
        app.buttons["effects.section.diffusion"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "camera.diffusion_filter.active")
                .firstMatch
                .waitForExistence(timeout: 5))
        app.buttons["editor.back"].tap()
        XCTAssertTrue(app.buttons["photo.develop"].waitForExistence(timeout: 30))
    }

    @MainActor func testSourceResetAndDiffusionControls() {
        let app = openPhoto()
        app.buttons["editor.tool.adjust"].tap()
        let exposure = app.sliders["tone.exposure"]
        XCTAssertTrue(exposure.waitForExistence(timeout: 5))
        drag(exposure, to: 0.6)
        let entered = app.buttons["tone.exposure.value"]
        XCTAssertNotEqual(entered.value as? String, "0.00 EV")
        app.buttons["editor.history"].tap()
        app.buttons["Reset All Edits"].tap()
        let reset = app.alerts["Reset all edits?"]
        XCTAssertTrue(reset.waitForExistence(timeout: 5))
        reset.buttons["Reset All Edits"].tap()
        expectation(for: NSPredicate(format: "value == %@", "0.00 EV"), evaluatedWith: entered)
        waitForExpectations(timeout: 10)
        app.buttons["editor.tool.develop"].tap()
        app.buttons["develop.mode.spektrafilm"].tap()
        app.buttons["editor.tool.effects"].tap()
        let area = app.sliders["film_render.grain.particle_area_um2"]
        let areaValue = app.buttons["film_render.grain.particle_area_um2.value"]
        let stockArea = areaValue.value as? String
        drag(area, to: 0.5)
        XCTAssertNotEqual(areaValue.value as? String, stockArea)
        app.buttons["grain.stockDefaults"].tap()
        let resetButtons = app.buttons.matching(identifier: "Use Stock Grain")
        resetButtons.element(boundBy: resetButtons.count - 1).tap()
        XCTAssertEqual(areaValue.value as? String, stockArea)
        XCTAssertLessThan(
            app.buttons["grain.stockDefaults"].frame.maxY,
            app.buttons["film_render.grain.details"].frame.minY)
        app.buttons["effects.section.halation"].tap()
        let scatter = app.buttons["film_render.halation.scatter_amount.value"]
        XCTAssertEqual(scatter.value as? String, "100 %")
        let halation = app.sliders["film_render.halation.halation_amount"]
        drag(halation, to: 0.8)
        let amount =
            app.buttons["film_render.halation.halation_amount.value"].value as? String ?? ""
        XCTAssertGreaterThan(Double(amount.split(separator: " ").first ?? "0") ?? 0, 20)
        app.buttons["effects.section.diffusion"].tap()
        for key in ["camera.diffusion_filter.active", "enlarger.diffusion_filter.active"] {
            let toggle = app.descendants(matching: .any).matching(identifier: key).firstMatch
            XCTAssertTrue(toggle.waitForExistence(timeout: 5))
            for _ in 0..<8 {
                let controls = app.scrollViews["editor.controls"].frame
                let top = controls.minY + 12
                let bottom = controls.maxY - 12
                if toggle.isHittable && toggle.frame.minY >= top && toggle.frame.maxY <= bottom {
                    break
                }
                let upwards = toggle.frame.midY > (top + bottom) / 2
                let origin = app.coordinate(withNormalizedOffset: .zero)
                let start = origin.withOffset(
                    CGVector(dx: app.frame.midX, dy: upwards ? bottom : top))
                let end = origin.withOffset(CGVector(dx: app.frame.midX, dy: (top + bottom) / 2))
                start.press(
                    forDuration: 0.05, thenDragTo: end, withVelocity: .slow,
                    thenHoldForDuration: 0.2)
            }
            XCTAssertTrue(toggle.isHittable, app.debugDescription)
            toggle.tap()
            XCTAssertEqual(toggle.value as? String, "1")
            XCTAssertLessThanOrEqual(toggle.frame.maxX, app.frame.maxX)
        }
        let busy = app.progressIndicators["Rendering preview"]
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: busy)
        waitForExpectations(timeout: 30)
        XCTAssertFalse(app.staticTexts["Couldn’t update preview"].exists)
        XCTAssertTrue(app.buttons["editor.back"].exists)
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "Both diffusion stages enabled"
        image.lifetime = .keepAlways
        add(image)
    }

    @MainActor func testExportOptionsAndCancellation() {
        let app = openPhoto()
        app.buttons["editor.export"].tap()
        XCTAssertTrue(app.buttons["darkroom.export"].waitForExistence(timeout: 5))
        app.buttons["darkroom.export"].tap()
        XCTAssertTrue(app.buttons["Long edge"].waitForExistence(timeout: 5))
        app.buttons["Percent"].tap()
        XCTAssertLessThan(app.buttons["75 %"].frame.minX, app.buttons["50 %"].frame.minX)
        XCTAssertLessThan(app.buttons["50 %"].frame.minX, app.buttons["25 %"].frame.minX)
        app.buttons["Long edge"].tap()
        // The output size is known before the file renders.
        let output = app.descendants(matching: .any)["export.output"]
        XCTAssertTrue(output.waitForExistence(timeout: 5))
        app.buttons["PNG"].tap()
        app.buttons["JPEG"].tap()
        XCTAssertLessThan(app.buttons["Maximum"].frame.minX, app.buttons["High"].frame.minX)
        XCTAssertLessThan(app.buttons["High"].frame.minX, app.buttons["Standard"].frame.minX)
        app.buttons["Standard"].tap()
        let save = app.buttons["export.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 45))
        let preparing = app.descendants(matching: .any)["export.preparing"]
        if preparing.exists && preparing.isHittable {
            XCTAssertLessThan(abs(preparing.frame.midX - app.frame.midX), 32)
            XCTAssertLessThanOrEqual(preparing.frame.maxY, save.frame.minY)
        }
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: save)
        waitForExpectations(timeout: 45)
        XCTAssertTrue(save.isHittable, "Default export layout hid Save to Photos")
        XCTAssertTrue(app.buttons["export.share"].isHittable)
        XCTAssertLessThan(app.buttons["Standard"].frame.maxY + 40, save.frame.minY)
        XCTAssertGreaterThan(
            app.buttons["Done"].frame.minY, app.frame.height * 0.15, "Export opened at full height")
        let dimensionRow = app.descendants(matching: .any)["export.output"]
        XCTAssertTrue(dimensionRow.isHittable)
        let dimensionText = ([dimensionRow.label, dimensionRow.value as? String ?? ""]
            + dimensionRow.staticTexts.allElementsBoundByIndex.map(\.label)).joined(separator: " ")
        // "W × H px · N MP": the first two numbers are the pixel size.
        let dimensions = Array(dimensionText.components(separatedBy: " px").first.map {
            $0.components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap(Int.init) } ?? [])
        XCTAssertGreaterThanOrEqual(dimensions.count, 2)
        XCTAssertTrue(dimensions.prefix(2).allSatisfy { (1...2048).contains($0) }, "A 2048 px long edge must not exceed 2048 or upscale a small fixture")
        XCTAssertLessThan(dimensionRow.frame.maxY, save.frame.minY)
        XCTAssertFalse(
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "needs more rendering memory")
            )
            .firstMatch.exists)
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "Native export options"
        image.lifetime = .keepAlways
        add(image)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["4 × 6"].waitForExistence(timeout: 5))
        app.buttons["4 × 6"].tap()
        app.buttons["darkroom.export"].tap()
        XCTAssertTrue(app.buttons["Print"].waitForExistence(timeout: 5))
        app.buttons["Print"].tap()
        XCTAssertLessThan(app.buttons["360 ppi"].frame.minX, app.buttons["300 ppi"].frame.minX)
        XCTAssertLessThan(app.buttons["300 ppi"].frame.minX, app.buttons["240 ppi"].frame.minX)
        app.buttons["Original"].tap()
    }

    @MainActor func testDarkroomLayoutHistoryAndReopening() {
        let app = openPhoto(activateLook: false, expanded: false)
        app.buttons["editor.export"].tap()
        let border = app.sliders["darkroom.border"]
        XCTAssertTrue(border.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["export.save"].exists, "Darkroom entry started the export sheet")
        XCTAssertTrue(app.buttons["darkroom.filmEdge"].isEnabled)
        app.buttons["8 × 10"].tap()
        let paperBorder = app.buttons["darkroom.border.value"].value as? String
        drag(border, to: 0.3)
        let chosenScale = app.buttons["darkroom.border.value"].value as? String
        XCTAssertNotEqual(chosenScale, paperBorder)
        app.buttons["editor.history"].tap()
        app.buttons["Undo"].tap()
        XCTAssertEqual(app.buttons["darkroom.border.value"].value as? String, paperBorder)
        app.buttons["editor.history"].tap()
        app.buttons["Redo"].tap()
        XCTAssertEqual(app.buttons["darkroom.border.value"].value as? String, chosenScale)
        let preview = XCTAttachment(screenshot: app.screenshot())
        preview.name = "Darkroom fixed paper with easel border"
        preview.lifetime = .keepAlways
        add(preview)
        // The value editor: a compact popover showing the value as the label rounds it.
        app.buttons["darkroom.border.value"].tap()
        XCTAssertTrue(app.textFields["numeric.input"].waitForExistence(timeout: 5))
        let entry = XCTAttachment(screenshot: app.screenshot())
        entry.name = "Compact value editor"
        entry.lifetime = .keepAlways
        add(entry)
        app.buttons["numeric.done"].tap()
        XCTAssertEqual(app.buttons["darkroom.border.value"].value as? String, chosenScale, "Done changed an untouched value")
        // Borderless: the loupe shows the same cropped sheet as the preview, never a border.
        app.buttons["darkroom.fill"].tap()
        let borderless = XCTAttachment(screenshot: app.screenshot())
        borderless.name = "Darkroom borderless sheet under the loupe"
        borderless.lifetime = .keepAlways
        add(borderless)
        XCTAssertEqual(app.buttons["darkroom.fill"].value as? String, "On", "Fill did not set the covering border")
        // Fill sets a value (the covering, usually negative border); Undo restores the previous one.
        app.buttons["editor.history"].tap()
        app.buttons["Undo"].tap()
        XCTAssertEqual(app.buttons["darkroom.border.value"].value as? String, chosenScale)
        XCTAssertTrue(app.buttons["darkroom.rotatePaper"].waitForExistence(timeout: 5))
        app.buttons["darkroom.rotatePaper"].tap()
        let expanded = XCTAttachment(screenshot: app.screenshot())
        expanded.name = "Expanded Darkroom controls"
        expanded.lifetime = .keepAlways
        add(expanded)
        app.buttons["editor.tool.develop"].tap()
        XCTAssertTrue(app.buttons["develop.mode.spektrafilm"].waitForExistence(timeout: 5))
        app.buttons["editor.export"].tap()
        XCTAssertEqual(app.buttons["darkroom.border.value"].value as? String, chosenScale)
        app.buttons["darkroom.back"].tap()
        XCTAssertTrue(app.buttons["photo.develop"].waitForExistence(timeout: 15))
        app.buttons["photo.develop"].tap()
        XCTAssertTrue(app.buttons["editor.export"].waitForExistence(timeout: 15))
        app.buttons["editor.export"].tap()
        XCTAssertEqual(app.buttons["darkroom.border.value"].value as? String, chosenScale)
    }

    @MainActor func testDarkroomPortraitPaperFollowsCrop() {
        let app = openPhoto(activateLook: false, expanded: false)
        app.buttons["editor.export"].tap()
        app.buttons["darkroom.filmEdge"].tap()
        XCTAssertTrue(app.buttons["crop.done"].waitForExistence(timeout: 10))
        app.buttons["crop.portrait"].tap()
        app.buttons["crop.done"].tap()
        let preview = app.descendants(matching: .any)["darkroom.preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        XCTAssertTrue((preview.value as? String ?? "").contains("Portrait"))
        app.buttons["darkroom.expand"].tap()
        app.buttons["4 × 6"].tap()
        XCTAssertTrue((preview.value as? String ?? "").contains("Portrait"), "Default paper ignored the portrait crop")
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "Default paper follows portrait crop before and after rendering"
        capture.lifetime = .keepAlways
        add(capture)
        app.buttons["darkroom.edge.adjustCrop"].tap()
        XCTAssertTrue(app.buttons["crop.done"].waitForExistence(timeout: 5))
        app.buttons["crop.landscape"].tap()
        app.buttons["crop.done"].tap()
        XCTAssertTrue(app.buttons["darkroom.export"].waitForExistence(timeout: 10))
        XCTAssertTrue((preview.value as? String ?? "").contains("Landscape"), "Automatic paper kept a stale portrait frame")
    }

    @MainActor func testFilmEdgeSelectionExportAndRestart() {
        let app = openPhoto(expanded: false)
        app.buttons["editor.export"].tap()
        app.buttons["darkroom.filmEdge"].tap()
        XCTAssertTrue(app.buttons["crop.done"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["crop.ratio.Free"].exists)
        XCTAssertFalse(app.buttons["crop.moreRatios"].exists)
        let filmGateMenu = app.buttons["crop.filmGate"]
        XCTAssertTrue(filmGateMenu.waitForExistence(timeout: 5))
        XCTAssertEqual(filmGateMenu.value as? String, "135 · Full frame")
        let crop = app.descendants(matching: .any)["crop.area"]
        XCTAssertEqual(crop.frame.width / crop.frame.height, 1.5, accuracy: 0.02)
        let initial35Width = crop.frame.width
        let initial35Height = crop.frame.height

        // Switch 135 Full -> 120 6x6 -> 135 Full in Crop without double-trimming.
        filmGateMenu.tap()
        let sixSixOption = app.buttons["6 × 6"]
        XCTAssertTrue(sixSixOption.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Full frame"].exists)
        XCTAssertTrue(app.buttons["Half frame"].exists)
        XCTAssertTrue(app.buttons["6 × 4.5"].exists)
        XCTAssertTrue(app.buttons["6 × 7"].exists)
        XCTAssertTrue(app.buttons["6 × 9"].exists)
        sixSixOption.tap()
        XCTAssertEqual(filmGateMenu.value as? String, "120 · 6 × 6")
        XCTAssertEqual(crop.frame.width / crop.frame.height, 1.0, accuracy: 0.02)
        XCTAssertFalse(app.buttons["crop.portrait"].exists)

        filmGateMenu.tap()
        XCTAssertTrue(app.buttons["Full frame"].waitForExistence(timeout: 5))
        app.buttons["Full frame"].tap()
        XCTAssertEqual(filmGateMenu.value as? String, "135 · Full frame")
        XCTAssertEqual(crop.frame.width, initial35Width, accuracy: 3)
        XCTAssertEqual(crop.frame.height, initial35Height, accuracy: 3)

        // Choose 120 6x7, position crop horizontally on the 4:3 frame, Done -> Darkroom, Clean Print -> Film Edge restores 120 6x7 without Crop.
        filmGateMenu.tap()
        XCTAssertTrue(app.buttons["6 × 7"].waitForExistence(timeout: 5))
        app.buttons["6 × 7"].tap()
        XCTAssertEqual(filmGateMenu.value as? String, "120 · 6 × 7")
        XCTAssertEqual(crop.frame.width / crop.frame.height, 69.5 / 56.0, accuracy: 0.03)
        let beforeMoveX = crop.frame.minX
        crop.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1,
            thenDragTo: crop.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)))
        let moved67MinX = crop.frame.minX
        XCTAssertNotEqual(moved67MinX, beforeMoveX)
        let gate = XCTAttachment(screenshot: app.screenshot())
        gate.name = "Crop Film frame picker on 120 6x7"
        gate.lifetime = .keepAlways
        add(gate)
        app.buttons["crop.done"].tap()
        XCTAssertTrue(app.buttons["darkroom.export"].waitForExistence(timeout: 10))

        // Clean Print -> Film Edge comparison keeps 120 6x7 and crop position without reopening Crop.
        app.buttons["darkroom.cleanPrint"].tap()
        XCTAssertTrue(app.buttons["darkroom.cleanPrint"].isSelected)
        app.buttons["darkroom.filmEdge"].tap()
        XCTAssertTrue(app.buttons["darkroom.export"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["crop.done"].exists, "Returning from Clean Print reopened Crop unexpectedly")
        app.buttons["darkroom.expand"].tap()
        let gateReadout = app.descendants(matching: .any)["darkroom.edge.gate"]
        XCTAssertTrue(gateReadout.waitForExistence(timeout: 5))
        XCTAssertTrue(gateReadout.label.contains("69.5 × 56"), "Clean Print comparison lost 120 6x7 gate: \(gateReadout.label)")

        // Reopen Adjust crop, verify 120 6x7 and positioned crop persisted, compare 120 6x9 vs 135 Full (both 3:2), then test perforations.
        app.buttons["darkroom.edge.adjustCrop"].tap()
        XCTAssertTrue(app.buttons["crop.done"].waitForExistence(timeout: 5))
        XCTAssertEqual(filmGateMenu.value as? String, "120 · 6 × 7")
        XCTAssertEqual(crop.frame.minX, moved67MinX, accuracy: 3)
        filmGateMenu.tap()
        XCTAssertTrue(app.buttons["6 × 9"].waitForExistence(timeout: 5))
        app.buttons["6 × 9"].tap()
        XCTAssertEqual(filmGateMenu.value as? String, "120 · 6 × 9")
        XCTAssertEqual(crop.frame.width / crop.frame.height, 1.5, accuracy: 0.02)
        filmGateMenu.tap()
        XCTAssertTrue(app.buttons["Full frame"].waitForExistence(timeout: 5))
        app.buttons["Full frame"].tap()
        XCTAssertEqual(filmGateMenu.value as? String, "135 · Full frame")
        XCTAssertEqual(crop.frame.width / crop.frame.height, 1.5, accuracy: 0.02)
        app.buttons["crop.portrait"].tap()
        XCTAssertEqual(crop.frame.width / crop.frame.height, 2.0 / 3, accuracy: 0.02)
        app.buttons["crop.landscape"].tap()
        app.buttons["crop.done"].tap()
        XCTAssertTrue(app.buttons["darkroom.export"].waitForExistence(timeout: 10))
        if app.buttons["darkroom.expand"].value as? String == "Collapsed" { app.buttons["darkroom.expand"].tap() }
        let auto = app.buttons["darkroom.edge.type.auto"]
        XCTAssertTrue(auto.waitForExistence(timeout: 10))
        XCTAssertTrue(auto.isSelected)
        let slide = app.buttons["darkroom.edge.type.reversalScan"]
        XCTAssertTrue(slide.waitForExistence(timeout: 5))
        slide.tap()
        XCTAssertTrue(slide.isSelected && !auto.isSelected)
        auto.tap()
        XCTAssertTrue(app.descendants(matching: .any)["darkroom.edge.resolved"].exists)
        slide.tap()
        XCTAssertTrue(app.buttons["darkroom.edge.type.reversalScan"].isSelected)
        app.buttons["darkroom.edge.adjustCrop"].tap()
        XCTAssertTrue(app.buttons["crop.done"].waitForExistence(timeout: 5))
        app.buttons["crop.done"].tap()
        XCTAssertTrue(app.buttons["darkroom.export"].waitForExistence(timeout: 10))
        if app.buttons["darkroom.expand"].value as? String == "Collapsed" { app.buttons["darkroom.expand"].tap() }
        app.buttons["darkroom.edge.format.roll120"].tap()
        if app.buttons["crop.done"].waitForExistence(timeout: 5) {
            XCTAssertEqual(crop.frame.width / crop.frame.height, 1.5, accuracy: 0.02)
            filmGateMenu.tap()
            XCTAssertTrue(app.buttons["6 × 6"].waitForExistence(timeout: 5))
            app.buttons["6 × 6"].tap()
            XCTAssertEqual(crop.frame.width / crop.frame.height, 1, accuracy: 0.02)
            XCTAssertFalse(app.buttons["crop.portrait"].exists)
            app.buttons["crop.done"].tap()
            XCTAssertTrue(app.buttons["darkroom.export"].waitForExistence(timeout: 10))
        }
        app.buttons["darkroom.edge.format.film35"].tap()
        if app.buttons["crop.done"].waitForExistence(timeout: 5) {
            app.buttons["crop.done"].tap()
            XCTAssertTrue(app.buttons["darkroom.export"].waitForExistence(timeout: 10))
        }
        if app.buttons["darkroom.expand"].value as? String == "Collapsed" { app.buttons["darkroom.expand"].tap() }
        XCTAssertTrue(app.descendants(matching: .any)["darkroom.gate.size"].exists, "Missing Gate size control")
        XCTAssertFalse(app.buttons["darkroom.gate.rough"].exists, "Rough gate option should be removed")
        let pending = app.progressIndicators["darkroom.edge.rendering"]
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: pending)
        waitForExpectations(timeout: 45)
        XCTAssertFalse(app.descendants(matching: .any)["darkroom.edge.failure"].exists)
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "Film edge manual slide scan and narrow 35 mm rebate"
        capture.lifetime = .keepAlways
        add(capture)
        app.buttons["darkroom.export"].tap()
        XCTAssertTrue(app.buttons["export.save"].waitForExistence(timeout: 45))
        XCTAssertTrue(app.buttons["export.save"].isEnabled)
        let exported = XCTAttachment(screenshot: app.screenshot())
        exported.name = "Film edge prepared export"
        exported.lifetime = .keepAlways
        add(exported)
        app.buttons["Done"].tap()
        app.buttons["darkroom.back"].tap()
        XCTAssertTrue(app.buttons["photo.develop"].waitForExistence(timeout: 15))
        app.terminate()
        app.launchArguments = ["--ui-test-library"]
        app.launch()
        XCTAssertTrue(libraryPhotos(app).firstMatch.waitForExistence(timeout: 15))
        libraryPhotos(app).firstMatch.tap()
        app.buttons["photo.develop"].tap()
        XCTAssertTrue(app.buttons["editor.export"].waitForExistence(timeout: 15))
        app.buttons["editor.export"].tap()
        XCTAssertTrue(app.buttons["darkroom.edge.type.reversalScan"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["darkroom.edge.type.reversalScan"].isSelected)
        XCTAssertTrue(app.buttons["darkroom.edge.format.film35"].isSelected)
    }

    @MainActor func testDarkroomChineseLargeText() {
        let app = importPhoto()
        app.terminate()
        app.launchArguments = ["--ui-test-library", "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityM"]
        app.launch()
        XCTAssertTrue(libraryPhotos(app).firstMatch.waitForExistence(timeout: 15))
        libraryPhotos(app).firstMatch.tap()
        app.buttons["photo.develop"].tap()
        XCTAssertTrue(app.buttons["editor.export"].waitForExistence(timeout: 15))
        app.buttons["editor.export"].tap()
        XCTAssertTrue(app.navigationBars["暗房"].waitForExistence(timeout: 5))
        app.buttons["8 × 10"].tap()
        app.buttons["darkroom.expand"].tap()
        XCTAssertEqual(app.buttons["darkroom.border.thin"].label, "极窄")
        XCTAssertEqual(app.buttons["darkroom.distress"].label, "做旧")
        let border = app.sliders["darkroom.border"]
        XCTAssertTrue(border.waitForExistence(timeout: 5))
        XCTAssertTrue(border.isHittable)
        XCTAssertLessThanOrEqual(border.frame.maxX, app.frame.width - 12)
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "Darkroom Chinese accessibility text"
        capture.lifetime = .keepAlways
        add(capture)
        app.buttons["darkroom.filmEdge"].tap()
        XCTAssertTrue(app.buttons["crop.done"].waitForExistence(timeout: 10))
        app.buttons["crop.done"].tap()
        XCTAssertTrue(app.buttons["darkroom.export"].waitForExistence(timeout: 10))
        app.buttons["darkroom.expand"].tap()
        XCTAssertTrue(app.buttons["darkroom.edge.type.negativePrint"].waitForExistence(timeout: 5))
        app.buttons["darkroom.edge.type.negativePrint"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["darkroom.easel.zoom"].exists, "Negative print did not show the easel")
        XCTAssertTrue(app.buttons["darkroom.edge.format.film35"].exists)
        XCTAssertEqual(app.buttons["darkroom.edge.perforations.stillKS"].label, "35 mm 静态 (KS)")
        app.buttons["darkroom.distress"].tap()
        let scrollView = app.scrollViews.firstMatch
        let inPhoto = app.buttons["darkroom.distress.scratchesInImage"]
        for _ in 0..<5 where !inPhoto.exists || !inPhoto.isHittable {
            scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).press(
                forDuration: 0.05,
                thenDragTo: scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)))
        }
        XCTAssertTrue(inPhoto.waitForExistence(timeout: 5))
        XCTAssertEqual(inPhoto.label, "画面内")
        XCTAssertEqual(inPhoto.value as? String, "关")
        let edgeCapture = XCTAttachment(screenshot: app.screenshot())
        edgeCapture.name = "Darkroom film edge Chinese accessibility text"
        edgeCapture.lifetime = .keepAlways
        add(edgeCapture)
    }

    @MainActor func testWorkspaceToolbarAndSharedPills() {
        let app = openPhoto(expanded: false)
        let camera = app.buttons["camera.open"]
        let cameraFrame = camera.frame
        let selectedPillHeight = app.buttons["develop.mode.spektrafilm"].frame.height
        let otherPillHeight = app.buttons["develop.mode.lut"].frame.height
        XCTAssertEqual(selectedPillHeight, otherPillHeight, accuracy: 1)
        app.buttons["develop.mode.lut"].tap()
        XCTAssertEqual(
            app.buttons["develop.mode.spektrafilm"].frame.height,
            app.buttons["develop.mode.lut"].frame.height, accuracy: 1)
        app.buttons["develop.mode.spektrafilm"].tap()
        XCTAssertEqual(
            app.buttons["develop.mode.spektrafilm"].frame.height,
            app.buttons["develop.mode.lut"].frame.height, accuracy: 1)
        func checkToolbar(close: String) {
            let history = app.buttons["editor.history"]
            XCTAssertTrue(camera.isHittable)
            XCTAssertTrue(history.isHittable)
            XCTAssertGreaterThan(camera.frame.midX, app.frame.width * 0.8)
            XCTAssertEqual(camera.frame.midX, cameraFrame.midX, accuracy: 1)
            XCTAssertGreaterThan(history.frame.minX, app.buttons[close].frame.maxX)
            XCTAssertLessThan(history.frame.maxX, app.frame.width / 2)
        }
        checkToolbar(close: "editor.back")
        let develop = XCTAttachment(screenshot: app.screenshot())
        develop.name = "Shared toolbar and Develop pills"
        develop.lifetime = .keepAlways
        add(develop)
        let editorExpand = app.buttons["editor.expand"]
        let expandCenter = editorExpand.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        for offset in [CGVector(dx: 18, dy: 0), CGVector(dx: -18, dy: 0), CGVector(dx: 0, dy: 18), CGVector(dx: 0, dy: -18)] {
            let before = editorExpand.value as? String
            expandCenter.withOffset(offset).tap()
            XCTAssertNotEqual(editorExpand.value as? String, before, "Expansion missed edge tap \(offset)")
        }
        if editorExpand.value as? String == "Expanded" { editorExpand.tap() }
        app.buttons["editor.tool.adjust"].tap()
        let adjustExposure = app.buttons["adjust.section.exposure"]
        let adjustLift = app.buttons["adjust.section.liftGain"]
        let adjustColor = app.buttons["adjust.section.color"]
        XCTAssertEqual(adjustExposure.frame.height, adjustLift.frame.height, accuracy: 1)
        XCTAssertEqual(adjustExposure.frame.height, adjustColor.frame.height, accuracy: 1)
        adjustColor.tap()
        XCTAssertTrue(adjustColor.isSelected)
        app.buttons["editor.export"].tap()
        XCTAssertTrue(app.buttons["darkroom.export"].waitForExistence(timeout: 5))
        checkToolbar(close: "darkroom.back")
        XCTAssertEqual(app.buttons["darkroom.cleanPrint"].frame.height, selectedPillHeight, accuracy: 1)
        XCTAssertEqual(app.buttons["darkroom.filmEdge"].frame.height, otherPillHeight, accuracy: 1)
        XCTAssertEqual(
            app.buttons["darkroom.cleanPrint"].frame.height,
            app.buttons["darkroom.filmEdge"].frame.height, accuracy: 1)
        XCTAssertGreaterThan(app.buttons["darkroom.export"].frame.minY, app.frame.height * 0.8)
        let darkroom = XCTAttachment(screenshot: app.screenshot())
        darkroom.name = "Darkroom shared pills camera and bottom Export"
        darkroom.lifetime = .keepAlways
        add(darkroom)
        camera.tap()
        XCTAssertTrue(app.buttons["camera.close"].waitForExistence(timeout: 10))
        app.buttons["camera.close"].tap()
        XCTAssertTrue(app.buttons["darkroom.export"].waitForExistence(timeout: 10))
        checkToolbar(close: "darkroom.back")
        app.buttons["darkroom.export"].tap()
        XCTAssertTrue(app.buttons["export.save"].waitForExistence(timeout: 30))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["darkroom.export"].waitForExistence(timeout: 10))
        app.buttons["editor.tool.crop"].tap()
        XCTAssertTrue(app.buttons["crop.done"].waitForExistence(timeout: 5))
        checkToolbar(close: "editor.back")
        let crop = XCTAttachment(screenshot: app.screenshot())
        crop.name = "Crop keeps camera at the trailing corner"
        crop.lifetime = .keepAlways
        add(crop)
        app.buttons["crop.done"].tap()
        app.buttons["editor.back"].tap()
        XCTAssertTrue(app.buttons["photo.develop"].waitForExistence(timeout: 15))
        XCTAssertEqual(camera.frame.midX, cameraFrame.midX, accuracy: 1)
    }

    @MainActor func testDarkroomResetLeakAndFullBleed() {
        let app = openPhoto(activateLook: false, expanded: false)
        app.buttons["editor.tool.adjust"].tap()
        let exposure = app.sliders["tone.exposure"]
        XCTAssertTrue(exposure.waitForExistence(timeout: 5))
        drag(exposure, to: 0.72)
        let savedExposure = app.buttons["tone.exposure.value"].value as? String
        XCTAssertNotEqual(savedExposure, "0.00 EV")

        app.buttons["editor.export"].tap()
        XCTAssertTrue(app.buttons["darkroom.export"].waitForExistence(timeout: 10))
        app.buttons["editor.history"].tap()
        let resetDarkroom = app.buttons["darkroom.reset"]
        XCTAssertTrue(resetDarkroom.waitForExistence(timeout: 5))
        XCTAssertFalse(resetDarkroom.isEnabled, "Reset Darkroom Edits must be disabled when Darkroom is neutral")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()

        if app.buttons["darkroom.expand"].exists && app.buttons["darkroom.expand"].value as? String == "Collapsed" {
            app.buttons["darkroom.expand"].tap()
        }
        app.buttons["8 × 10"].tap()
        let noBorder = app.buttons["darkroom.border.none"]
        XCTAssertTrue(noBorder.waitForExistence(timeout: 5))
        noBorder.tap()
        XCTAssertTrue(noBorder.isSelected)
        XCTAssertEqual(app.buttons["darkroom.fill"].value as? String, "On")

        app.buttons["darkroom.filmEdge"].tap()
        if app.buttons["crop.done"].waitForExistence(timeout: 4) {
            app.buttons["crop.done"].tap()
        }
        XCTAssertTrue(app.buttons["darkroom.export"].waitForExistence(timeout: 10))
        app.buttons["darkroom.distress"].tap()
        if app.buttons["darkroom.expand"].exists && app.buttons["darkroom.expand"].value as? String == "Collapsed" {
            app.buttons["darkroom.expand"].tap()
        }

        let scrollView = app.scrollViews.firstMatch
        let glow = app.buttons["darkroom.distress.shape.glow"]
        let streak = app.buttons["darkroom.distress.shape.streak"]
        let flare = app.buttons["darkroom.distress.shape.flare"]
        let burn = app.buttons["darkroom.distress.shape.burn"]
        for _ in 0..<5 where !burn.exists || !burn.isHittable {
            scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).press(
                forDuration: 0.05,
                thenDragTo: scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)))
        }
        XCTAssertTrue(burn.waitForExistence(timeout: 5))
        XCTAssertEqual(glow.value as? String, "Off")
        XCTAssertEqual(streak.value as? String, "Off")
        XCTAssertEqual(flare.value as? String, "Off")
        XCTAssertEqual(burn.value as? String, "Off")

        burn.tap()
        XCTAssertEqual(burn.value as? String, "On")
        XCTAssertEqual(app.buttons["darkroom.distress.leak.value"].value as? String, "30.0 %")
        let leakDice = app.buttons["darkroom.distress.leakSeed"]
        XCTAssertTrue(leakDice.exists)
        XCTAssertGreaterThanOrEqual(leakDice.frame.minX, burn.frame.maxX - 2, "Leak dice should sit to the right of Burn")
        let burnPosBefore = app.buttons["darkroom.distress.leakPosition.value"].value as? String
        leakDice.tap()
        XCTAssertNotEqual(app.buttons["darkroom.distress.leakPosition.value"].value as? String, burnPosBefore)
        burn.tap()
        XCTAssertEqual(burn.value as? String, "Off")
        XCTAssertEqual(app.buttons["darkroom.distress.leak.value"].value as? String, "0.0 %")
        streak.tap()
        XCTAssertEqual(streak.value as? String, "On")
        let streakPosBefore = app.buttons["darkroom.distress.leakPosition.value"].value as? String
        leakDice.tap()
        XCTAssertNotEqual(app.buttons["darkroom.distress.leakPosition.value"].value as? String, streakPosBefore)

        app.buttons["editor.history"].tap()
        XCTAssertTrue(resetDarkroom.waitForExistence(timeout: 5))
        XCTAssertTrue(resetDarkroom.isEnabled)
        resetDarkroom.tap()
        XCTAssertFalse(app.alerts.firstMatch.exists, "Reset Darkroom Edits should not prompt for confirmation")
        expectation(for: NSPredicate(format: "selected == true"), evaluatedWith: app.buttons["darkroom.cleanPrint"])
        waitForExpectations(timeout: 5)

        app.buttons["editor.history"].tap()
        app.buttons["Undo"].tap()
        expectation(for: NSPredicate(format: "selected == true"), evaluatedWith: app.buttons["darkroom.filmEdge"])
        waitForExpectations(timeout: 5)

        app.buttons["editor.history"].tap()
        app.buttons["Redo"].tap()
        expectation(for: NSPredicate(format: "selected == true"), evaluatedWith: app.buttons["darkroom.cleanPrint"])
        waitForExpectations(timeout: 5)

        app.buttons["editor.tool.adjust"].tap()
        XCTAssertTrue(app.buttons["tone.exposure.value"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["tone.exposure.value"].value as? String, savedExposure,
                       "Reset Darkroom Edits altered Develop adjustments")
    }

    @MainActor func testRecentlyDeletedLifecycle() {
        let app = openPhoto(activateLook: false, expanded: false)
        app.buttons["editor.tool.adjust"].tap()
        let exposure = app.sliders["tone.exposure"]
        XCTAssertTrue(exposure.waitForExistence(timeout: 5))
        drag(exposure, to: 0.75)
        let savedExposure = app.buttons["tone.exposure.value"].value as? String
        app.buttons["editor.back"].tap()
        XCTAssertTrue(app.buttons["photo.delete"].waitForExistence(timeout: 15))
        app.buttons["photo.delete"].tap()
        let deleteConfirmButton = app.buttons["Delete App Copy"]
        XCTAssertTrue(deleteConfirmButton.waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["photo.delete.card"].exists)
        deleteConfirmButton.tap()
        XCTAssertTrue(app.buttons["library.import"].waitForExistence(timeout: 10))
        XCTAssertEqual(libraryPhotos(app).count, 0)

        app.buttons["library.info"].tap()
        let row = app.descendants(matching: .any)["about.recentlyDeleted"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()

        let deletedTile = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'recentlyDeleted.photo.'")).firstMatch
        XCTAssertTrue(deletedTile.waitForExistence(timeout: 5))
        XCTAssertEqual(deletedTile.value as? String, "30 days remaining")

        deletedTile.tap()
        app.buttons["recentlyDeleted.recover"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["recentlyDeleted.empty"].waitForExistence(timeout: 5))

        // Navigate back to Info and dismiss sheet cleanly.
        if app.buttons["About"].exists {
            app.buttons["About"].tap()
        } else {
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()

        XCTAssertTrue(libraryPhotos(app).firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(libraryPhotos(app).count, 1)
        libraryPhotos(app).firstMatch.tap()
        XCTAssertTrue(app.buttons["photo.develop"].waitForExistence(timeout: 10))
        app.buttons["photo.develop"].tap()
        XCTAssertTrue(app.buttons["editor.tool.adjust"].waitForExistence(timeout: 20))
        app.buttons["editor.tool.adjust"].tap()
        XCTAssertEqual(app.buttons["tone.exposure.value"].value as? String, savedExposure)
        app.buttons["editor.back"].tap()
        XCTAssertTrue(app.buttons["photo.delete"].waitForExistence(timeout: 15))
        app.buttons["photo.delete"].tap()
        XCTAssertTrue(deleteConfirmButton.waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["photo.delete.card"].exists)
        deleteConfirmButton.tap()
        XCTAssertTrue(app.buttons["library.import"].waitForExistence(timeout: 10))

        app.buttons["library.info"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(deletedTile.waitForExistence(timeout: 5))
        app.buttons["recentlyDeleted.selectAll"].tap()
        app.buttons["recentlyDeleted.deletePermanently"].tap()
        let confirmPurgeButton = app.buttons.matching(
            NSPredicate(format: "label == 'Delete Permanently' AND identifier != 'recentlyDeleted.deletePermanently'")
        ).firstMatch
        XCTAssertTrue(confirmPurgeButton.waitForExistence(timeout: 5))
        confirmPurgeButton.tap()
        XCTAssertTrue(app.descendants(matching: .any)["recentlyDeleted.empty"].waitForExistence(timeout: 5))
    }

    @MainActor func testDarkroomLoupeNumericEntryAndPresetRetention() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let shotsDir = ProcessInfo.processInfo.environment["SPEKTRACAM_LAYOUT_SHOTS"]
        func saveShot(_ name: String, _ app: XCUIApplication) {
            #if !targetEnvironment(simulator)
                let attachment = XCTAttachment(screenshot: app.screenshot())
                attachment.name = name
                attachment.lifetime = .keepAlways
                self.add(attachment)
            #endif
            guard let shotsDir else { return }
            let url = URL(fileURLWithPath: shotsDir).appendingPathComponent(name + ".png")
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? app.screenshot().pngRepresentation.write(to: url)
        }

        let app = XCUIApplication(bundleIdentifier: "io.github.runzeni.spektracam")
        #if !targetEnvironment(simulator)
            var didCleanUpDeviceStore = false
            addTeardownBlock {
                MainActor.assumeIsolated {
                    guard !didCleanUpDeviceStore else { return }
                    let cleaner = XCUIApplication(bundleIdentifier: "io.github.runzeni.spektracam")
                    cleaner.terminate()
                    cleaner.launchArguments = ["--ui-test-library", "--cleanup-test-library"]
                    cleaner.launch()
                    _ = cleaner.buttons["library.import"].waitForExistence(timeout: 8)
                    cleaner.terminate()
                }
            }
        #endif
        var args = [
            "--ui-test-library", "--reset-test-library",
        ]
        if let brightPhoto = ProcessInfo.processInfo.environment["SPEKTRACAM_BRIGHT_PHOTO"] {
            args += ["--ui-test-import", brightPhoto, "--ui-test-synthetic-photo", "standard"]
        } else {
            args += [
                "--ui-test-synthetic-photo", "bright-sky",
                "--ui-test-synthetic-photo", "standard",
            ]
        }
        if let accent = ProcessInfo.processInfo.environment["SPEKTRACAM_ACCENT"] {
            args += ["-app.accent", accent]
        }
        app.launchArguments = args
        app.launch()

        let first = libraryPhotos(app).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 20))
        expectation(
            for: NSPredicate(format: "count >= 2"),
            evaluatedWith: libraryPhotos(app))
        waitForExpectations(timeout: 20)
        libraryPhotos(app).firstMatch.tap()

        // 1. Native Delete confirmation & uniform non-sticking circular buttons + restrained filmstrip.
        let exportBtn = app.buttons["photo.export"]
        let revertBtn = app.buttons["photo.revert"]
        let deleteBtn = app.buttons["photo.delete"]
        let cameraBtn = app.buttons["camera.open"]
        XCTAssertTrue(deleteBtn.waitForExistence(timeout: 10))
        for btn in [exportBtn, revertBtn, deleteBtn] {
            XCTAssertEqual(btn.frame.width, cameraBtn.frame.width, accuracy: 2.0, "Circular button width mismatch")
            XCTAssertEqual(btn.frame.height, cameraBtn.frame.height, accuracy: 2.0, "Circular button height mismatch")
        }
        XCTAssertGreaterThanOrEqual(revertBtn.frame.minX - exportBtn.frame.maxX, 10.0, "Export/Revert buttons fused")
        XCTAssertGreaterThanOrEqual(deleteBtn.frame.minX - revertBtn.frame.maxX, 10.0, "Revert/Delete buttons fused")
        let filmstripEl = app.descendants(matching: .any)["photo.filmstrip"]
        let firstThumb = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'photo.filmstrip.'")).firstMatch
        if filmstripEl.exists && firstThumb.exists {
            XCTAssertEqual(firstThumb.frame.height, 54.0, accuracy: 2.0)
            XCTAssertEqual(firstThumb.frame.width, 42.0, accuracy: 2.0)
        }
        saveShot("00_viewer_controls", app)

        deleteBtn.tap()
        XCTAssertTrue(app.buttons["Delete App Copy"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["photo.delete.card"].exists, "Custom delete card should be removed")
        saveShot("01_delete_native_dialog", app)
        if app.buttons["Cancel"].exists {
            app.buttons["Cancel"].tap()
        } else if app.otherElements["PopoverDismissRegion"].exists {
            app.otherElements["PopoverDismissRegion"].tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.20, dy: 0.35)).tap()
        }
        expectation(
            for: NSPredicate(format: "exists == false"),
            evaluatedWith: app.buttons["Delete App Copy"])
        waitForExpectations(timeout: 5)

        // 2. PhotoInfoPanel states over bright sky in Editor and Viewer.
        XCTAssertTrue(app.buttons["photo.develop"].waitForExistence(timeout: 5))
        app.buttons["photo.develop"].tap()
        XCTAssertTrue(app.buttons["editor.histogram"].waitForExistence(timeout: 30))
        saveShot("02_info_collapsed_bright", app)
        app.buttons["editor.info"].tap()
        let photoDetails = app.descendants(matching: .any).matching(identifier: "editor.photoDetails").firstMatch
        XCTAssertTrue(photoDetails.waitForExistence(timeout: 5))
        let colorRow = app.descendants(matching: .any)["editor.colorSpace"]
        if colorRow.exists {
            photoDetails.tap()
        }
        saveShot("03_info_expanded_clear_original_bright", app)
        app.buttons["editor.info"].tap()

        if app.buttons["develop.mode.spektrafilm"].exists {
            app.buttons["develop.mode.spektrafilm"].tap()
        }

        // Save a formula so FormulaStrip has pills/tiles, then verify all EXIF rows fit without scrolling.
        app.buttons["editor.info"].tap()
        let saveFormula = app.buttons["editor.formula.save"]
        if saveFormula.waitForExistence(timeout: 5) && saveFormula.isEnabled {
            saveFormula.tap()
            let nameField = app.textFields["formula.save.name"]
            if nameField.waitForExistence(timeout: 5) {
                nameField.typeText("Cocktail")
                app.buttons["formula.save.confirm"].tap()
            }
        }
        XCTAssertTrue(photoDetails.waitForExistence(timeout: 5))
        if colorRow.exists {
            photoDetails.tap()
        }
        saveShot("04_info_expanded_clear_with_formulae_bright", app)
        photoDetails.tap()
        XCTAssertTrue(colorRow.waitForExistence(timeout: 5))
        saveShot("05_info_expanded_photo_details_opaque", app)
        let detailsScroll = app.scrollViews["editor.details"]
        if detailsScroll.exists && app.frame.height >= 640 {
            XCTAssertLessThanOrEqual(
                colorRow.frame.maxY,
                detailsScroll.frame.maxY + 2,
                "Bottom EXIF row required scrolling inside PhotoInfoPanel"
            )
        }
        app.buttons["editor.info"].tap()

        // Also check PhotoDetailView's FormulaStrip tile and Photo Details fit.
        app.buttons["editor.back"].tap()
        XCTAssertTrue(app.buttons["photo.info"].waitForExistence(timeout: 15))
        app.buttons["photo.info"].tap()
        let viewerFormulaTile = app.buttons["photo.formula.Cocktail"]
        XCTAssertTrue(viewerFormulaTile.waitForExistence(timeout: 5))
        let viewerColorRow = app.descendants(matching: .any)["photo.colorSpace"]
        XCTAssertTrue(viewerColorRow.waitForExistence(timeout: 5))
        let viewerDetailsScroll = app.scrollViews["photo.details"]
        if viewerDetailsScroll.exists && app.frame.height >= 640 {
            XCTAssertLessThanOrEqual(
                viewerColorRow.frame.maxY,
                viewerDetailsScroll.frame.maxY + 2,
                "Bottom EXIF row required scrolling inside viewer PhotoInfoPanel"
            )
        }
        app.buttons["photo.info"].tap()

        // Switch to the 3000×2000 3:2 standard photo by deleting the first synthetic test copy.
        if !app.buttons["Delete App Copy"].exists {
            deleteBtn.tap()
            if app.buttons["Delete App Copy"].waitForExistence(timeout: 5) {
                app.buttons["Delete App Copy"].tap()
            }
        } else {
            app.buttons["Delete App Copy"].tap()
        }
        XCTAssertTrue(app.buttons["photo.develop"].waitForExistence(timeout: 10))
        app.buttons["photo.develop"].tap()
        XCTAssertTrue(app.buttons["develop.mode.spektrafilm"].waitForExistence(timeout: 20))
        app.buttons["develop.mode.spektrafilm"].tap()

        // 3. Darkroom: Thin 1% border preset, non-shrinking paper on expand, and Loupe concentric toggle + drag + numeric entry.
        app.buttons["editor.export"].tap()
        XCTAssertTrue(app.buttons["darkroom.export"].waitForExistence(timeout: 10))
        let previewEl = app.descendants(matching: .any)["darkroom.preview"]
        XCTAssertTrue(previewEl.waitForExistence(timeout: 5))
        let previewCollapsedFrame = previewEl.frame
        saveShot("06a_darkroom_collapsed", app)
        if app.buttons["darkroom.expand"].exists && app.buttons["darkroom.expand"].value as? String == "Collapsed" {
            app.buttons["darkroom.expand"].tap()
            XCTAssertEqual(previewEl.frame.height, previewCollapsedFrame.height, accuracy: 2.5, "Darkroom paper shrank when expanding inspector")
            XCTAssertEqual(previewEl.frame.width, previewCollapsedFrame.width, accuracy: 2.5, "Darkroom paper changed width when expanding inspector")
            saveShot("06b_darkroom_expanded_nonshrinking", app)
        }
        app.buttons["8 × 10"].tap()
        let thinBorder = app.buttons["darkroom.border.thin"]
        XCTAssertTrue(thinBorder.waitForExistence(timeout: 5))
        thinBorder.tap()
        XCTAssertTrue(thinBorder.isSelected)
        XCTAssertEqual(app.buttons["darkroom.border.value"].value as? String, "1.0 %")
        if app.buttons["darkroom.expand"].exists && app.buttons["darkroom.expand"].value as? String == "Expanded" {
            app.buttons["darkroom.expand"].tap()
        }

        let loupeToggle = app.buttons["darkroom.loupe.toggle"]
        XCTAssertTrue(loupeToggle.waitForExistence(timeout: 5))
        if !loupeToggle.isSelected {
            loupeToggle.tap()
        }
        let loupe = app.descendants(matching: .any)["darkroom.loupe"]
        XCTAssertTrue(loupe.waitForExistence(timeout: 5))
        XCTAssertEqual(loupe.frame.width, 156, accuracy: 3)
        XCTAssertEqual(loupe.frame.height, 156, accuracy: 3)

        // Drag the loupe away from its default upper-right anchor and verify its position persists across toggle & numeric entry.
        let initialLoupeFrame = loupe.frame
        let loupeCenterCoord = loupe.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        loupeCenterCoord.press(
            forDuration: 0.08,
            thenDragTo: loupeCenterCoord.withOffset(CGVector(dx: -68, dy: 42)))
        let draggedCleanLoupe = loupe.frame
        XCTAssertLessThan(draggedCleanLoupe.midX, initialLoupeFrame.midX - 30, "Loupe drag did not update anchor")

        loupeToggle.tap()
        XCTAssertTrue(loupe.waitForNonExistence(timeout: 3))
        loupeToggle.tap()
        XCTAssertTrue(loupe.waitForExistence(timeout: 3))
        XCTAssertEqual(loupe.frame.midX, draggedCleanLoupe.midX, accuracy: 2.5)
        XCTAssertEqual(loupe.frame.midY, draggedCleanLoupe.midY, accuracy: 2.5)
        saveShot("06_darkroom_loupe_before_numeric", app)

        let previewBeforeNumeric = previewEl.frame
        app.buttons["darkroom.border.value"].tap()
        let input = app.textFields["numeric.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        saveShot("07_darkroom_loupe_during_numeric", app)
        // Software keyboard must not collapse or shift the Darkroom light table or loupe.
        XCTAssertEqual(previewEl.frame.height, previewBeforeNumeric.height, accuracy: 2.5)
        XCTAssertEqual(loupe.frame.midX, draggedCleanLoupe.midX, accuracy: 2.5)
        XCTAssertEqual(loupe.frame.midY, draggedCleanLoupe.midY, accuracy: 2.5)
        if let current = input.value as? String, !current.isEmpty {
            input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        input.typeText("2.5")
        app.buttons["numeric.done"].tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: input)
        waitForExpectations(timeout: 5)
        saveShot("08_darkroom_loupe_after_numeric", app)
        XCTAssertEqual(app.buttons["darkroom.border.value"].value as? String, "2.5 %")
        XCTAssertEqual(loupe.frame.midX, draggedCleanLoupe.midX, accuracy: 2.5)
        XCTAssertEqual(loupe.frame.midY, draggedCleanLoupe.midY, accuracy: 2.5)

        // 4. Clean-print Distress + Film Edge Handling + 3rd Distress pill, plus Loupe persistence across Crop & Adjust -> Darkroom.
        let distressTab = app.buttons["darkroom.distress"]
        XCTAssertTrue(distressTab.waitForExistence(timeout: 5))
        distressTab.tap()
        let cleanDistressBtn = app.buttons["darkroom.distress.clean"]
        let leakyDistressBtn = app.buttons["darkroom.distress.leaky"]
        XCTAssertTrue(cleanDistressBtn.waitForExistence(timeout: 5))
        XCTAssertTrue(cleanDistressBtn.isSelected)
        let scrollView = app.scrollViews["darkroom.controls"]
        let inPhotoBtn = app.buttons["darkroom.distress.scratchesInImage"]
        for _ in 0..<6 where !inPhotoBtn.exists || !inPhotoBtn.isHittable {
            scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).press(
                forDuration: 0.05,
                thenDragTo: scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)))
        }
        XCTAssertTrue(inPhotoBtn.waitForExistence(timeout: 5))
        XCTAssertEqual(inPhotoBtn.label, "In photo")
        XCTAssertEqual(inPhotoBtn.value as? String, "Off")
        inPhotoBtn.tap()
        XCTAssertEqual(inPhotoBtn.value as? String, "On")
        saveShot("08c_clean_print_in_photo_scratches", app)
        inPhotoBtn.tap()
        XCTAssertEqual(inPhotoBtn.value as? String, "Off")
        for _ in 0..<6 where !leakyDistressBtn.isHittable {
            scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).press(
                forDuration: 0.05,
                thenDragTo: scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)))
        }
        leakyDistressBtn.tap()
        XCTAssertTrue(leakyDistressBtn.isSelected)
        let edgePending = app.progressIndicators["darkroom.edge.rendering"]
        _ = edgePending.waitForExistence(timeout: 1)
        if edgePending.exists {
            expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: edgePending)
            waitForExpectations(timeout: 30)
        }
        saveShot("08b_clean_print_distress", app)
        cleanDistressBtn.tap()
        XCTAssertTrue(cleanDistressBtn.isSelected)

        app.buttons["darkroom.filmEdge"].tap()
        if app.buttons["crop.done"].waitForExistence(timeout: 4) {
            let filmGateMenu = app.buttons["crop.filmGate"]
            XCTAssertTrue(filmGateMenu.waitForExistence(timeout: 5))
            XCTAssertEqual(filmGateMenu.value as? String, "135 · Full frame")
            let cropArea = app.descendants(matching: .any)["crop.area"]
            let w35 = cropArea.frame.width
            let h35 = cropArea.frame.height
            filmGateMenu.tap()
            XCTAssertTrue(app.buttons["6 × 6"].waitForExistence(timeout: 5))
            app.buttons["6 × 6"].tap()
            XCTAssertEqual(filmGateMenu.value as? String, "120 · 6 × 6")
            filmGateMenu.tap()
            XCTAssertTrue(app.buttons["Full frame"].waitForExistence(timeout: 5))
            app.buttons["Full frame"].tap()
            XCTAssertEqual(cropArea.frame.width, w35, accuracy: 3)
            XCTAssertEqual(cropArea.frame.height, h35, accuracy: 3)
            filmGateMenu.tap()
            XCTAssertTrue(app.buttons["6 × 7"].waitForExistence(timeout: 5))
            app.buttons["6 × 7"].tap()
            XCTAssertEqual(filmGateMenu.value as? String, "120 · 6 × 7")
            saveShot("08d_crop_film_frame_6x7", app)
            app.buttons["crop.done"].tap()
        }
        XCTAssertTrue(app.buttons["darkroom.export"].waitForExistence(timeout: 10))
        app.buttons["darkroom.cleanPrint"].tap()
        app.buttons["darkroom.filmEdge"].tap()
        XCTAssertFalse(app.buttons["crop.done"].exists, "Clean Print comparison reopened Crop on device")
        if app.buttons["darkroom.expand"].exists && !app.buttons["darkroom.edge.adjustCrop"].isHittable {
            app.buttons["darkroom.expand"].tap()
        }
        app.buttons["darkroom.edge.adjustCrop"].tap()
        XCTAssertTrue(app.buttons["crop.done"].waitForExistence(timeout: 5))
        app.buttons["crop.filmGate"].tap()
        XCTAssertTrue(app.buttons["Full frame"].waitForExistence(timeout: 5))
        app.buttons["Full frame"].tap()
        app.buttons["crop.done"].tap()
        XCTAssertTrue(app.buttons["darkroom.export"].waitForExistence(timeout: 10))
        XCTAssertTrue(loupe.exists, "Loupe disappeared when entering Film Edge Darkroom")

        if app.buttons["darkroom.expand"].exists && app.buttons["darkroom.expand"].value as? String == "Collapsed" {
            app.buttons["darkroom.expand"].tap()
        }
        if edgePending.exists {
            expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: edgePending)
            waitForExpectations(timeout: 30)
        }
        let handlingSeed = app.buttons["darkroom.handling.seed"]
        for _ in 0..<4 where !handlingSeed.exists {
            scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).press(
                forDuration: 0.05,
                thenDragTo: scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)))
        }
        XCTAssertTrue(handlingSeed.waitForExistence(timeout: 5), "Handling controls should live in Film edge")

        distressTab.tap()
        XCTAssertTrue(app.buttons["darkroom.distress.lab"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["darkroom.distress.lab"].isSelected)

        let fogValue = app.buttons["darkroom.distress.fog.value"]
        for _ in 0..<4 where !fogValue.exists {
            scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).press(
                forDuration: 0.05,
                thenDragTo: scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)))
        }
        XCTAssertTrue(fogValue.waitForExistence(timeout: 5))
        XCTAssertEqual(fogValue.value as? String, "20.0 %")

        let scratchesValue = app.buttons["darkroom.distress.scratches.value"]
        for _ in 0..<5 where !scratchesValue.exists {
            scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).press(
                forDuration: 0.05,
                thenDragTo: scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)))
        }
        XCTAssertTrue(scratchesValue.waitForExistence(timeout: 5))
        XCTAssertEqual(scratchesValue.value as? String, "10.0 %")

        // Numeric entry inside Film Edge with Loupe active + tap-outside commit.
        let expandedEdgeLoupe = loupe.frame
        scratchesValue.tap()
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        if let current = input.value as? String, !current.isEmpty {
            input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        input.typeText("20")
        if app.otherElements["PopoverDismissRegion"].exists {
            app.otherElements["PopoverDismissRegion"].tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.22)).tap()
        }
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: input)
        expectation(for: NSPredicate(format: "value == %@", "20.0 %"), evaluatedWith: scratchesValue)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(loupe.frame.midX, expandedEdgeLoupe.midX, accuracy: 2.5)
        XCTAssertEqual(loupe.frame.midY, expandedEdgeLoupe.midY, accuracy: 2.5)

        // Collapse Darkroom panel so we know the exact collapsed Film Edge loupe frame, then round-trip Adjust -> numeric -> Darkroom.
        if app.buttons["darkroom.expand"].exists && app.buttons["darkroom.expand"].value as? String == "Expanded" {
            app.buttons["darkroom.expand"].tap()
        }
        if edgePending.exists {
            expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: edgePending)
            waitForExpectations(timeout: 30)
        }
        let settledCollapsedLoupe = loupe.frame

        app.buttons["editor.tool.adjust"].tap()
        let evValue = app.buttons["tone.exposure.value"]
        XCTAssertTrue(evValue.waitForExistence(timeout: 5))
        evValue.tap()
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        if let current = input.value as? String, !current.isEmpty {
            input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        input.typeText("0.25")
        app.buttons["numeric.done"].tap()
        app.buttons["editor.export"].tap()
        XCTAssertTrue(app.buttons["darkroom.export"].waitForExistence(timeout: 5))
        // Immediately on returning to Darkroom AND after Film Edge re-renders, the loupe keeps its exact anchor without jumping.
        XCTAssertTrue(loupe.exists)
        XCTAssertEqual(loupe.frame.midX, settledCollapsedLoupe.midX, accuracy: 2.5, "Loupe jumped on entering Darkroom after numeric entry")
        XCTAssertEqual(loupe.frame.midY, settledCollapsedLoupe.midY, accuracy: 2.5, "Loupe jumped on entering Darkroom after numeric entry")
        if edgePending.exists {
            expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: edgePending)
            waitForExpectations(timeout: 30)
        }
        XCTAssertEqual(loupe.frame.midX, settledCollapsedLoupe.midX, accuracy: 2.5, "Loupe drifted after Film Edge preview settled")
        XCTAssertEqual(loupe.frame.midY, settledCollapsedLoupe.midY, accuracy: 2.5, "Loupe drifted after Film Edge preview settled")
        saveShot("09_darkroom_loupe_after_adjust_return", app)

        // Verify mid-render Crop 90° rotation -> immediate Darkroom return invalidates stale edgeImage cleanly, then restore orientation.
        app.buttons["editor.tool.crop"].tap()
        let rotateLeftBtn = app.buttons["Rotate Left"]
        if rotateLeftBtn.waitForExistence(timeout: 5) {
            rotateLeftBtn.tap()
            if app.buttons["crop.done"].exists {
                app.buttons["crop.done"].tap()
            } else {
                app.buttons["editor.export"].tap()
            }
            XCTAssertTrue(app.buttons["darkroom.export"].waitForExistence(timeout: 5))
            XCTAssertTrue(loupe.exists, "Loupe missing after Crop 90° rotation return to Darkroom")
            if edgePending.exists {
                expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: edgePending)
                waitForExpectations(timeout: 30)
            }
            XCTAssertEqual(loupe.frame.width, 156, accuracy: 3)
            XCTAssertEqual(loupe.frame.height, 156, accuracy: 3)
        }

        // 5. On physical device, also test real hardware camera capture into the isolated test library + Chinese strings, then clean up.
        #if !targetEnvironment(simulator)
            app.buttons["camera.open"].tap()
            let shutter = app.buttons["camera.shutter"]
            if shutter.waitForExistence(timeout: 8) {
                for _ in 0..<12 where !shutter.isEnabled {
                    Thread.sleep(forTimeInterval: 0.5)
                }
                if shutter.isEnabled {
                    shutter.tap()
                    let savedBadge = app.descendants(matching: .any)["camera.saved"]
                    _ = savedBadge.waitForExistence(timeout: 12)
                    app.buttons["camera.library"].tap()
                    expectation(
                        for: NSPredicate(format: "count >= 2"),
                        evaluatedWith: libraryPhotos(app))
                    waitForExpectations(timeout: 20)
                    let latestIndex = max(0, libraryPhotos(app).count - 1)
                    libraryPhotos(app).element(boundBy: latestIndex).tap()
                    XCTAssertTrue(app.buttons["photo.develop"].waitForExistence(timeout: 10))
                    app.buttons["photo.develop"].tap()
                    XCTAssertTrue(app.buttons["editor.export"].waitForExistence(timeout: 25))
                    app.buttons["editor.export"].tap()
                    XCTAssertTrue(app.buttons["darkroom.export"].waitForExistence(timeout: 10))
                    app.buttons["darkroom.filmEdge"].tap()
                    if app.buttons["crop.done"].waitForExistence(timeout: 4) {
                        app.buttons["crop.done"].tap()
                    }
                    XCTAssertTrue(loupe.waitForExistence(timeout: 5))
                    let hwLoupeFrame = loupe.frame
                    app.buttons["editor.tool.adjust"].tap()
                    XCTAssertTrue(evValue.waitForExistence(timeout: 5))
                    evValue.tap()
                    XCTAssertTrue(input.waitForExistence(timeout: 5))
                    if let current = input.value as? String, !current.isEmpty {
                        input.typeText(
                            String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count)
                        )
                    }
                    input.typeText("0.15")
                    app.buttons["numeric.done"].tap()
                    app.buttons["editor.export"].tap()
                    XCTAssertTrue(app.buttons["darkroom.export"].waitForExistence(timeout: 5))
                    XCTAssertEqual(loupe.frame.midX, hwLoupeFrame.midX, accuracy: 2.5)
                    XCTAssertEqual(loupe.frame.midY, hwLoupeFrame.midY, accuracy: 2.5)
                    if edgePending.exists {
                        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: edgePending)
                        waitForExpectations(timeout: 45)
                    }
                    XCTAssertEqual(loupe.frame.midX, hwLoupeFrame.midX, accuracy: 2.5)
                    XCTAssertEqual(loupe.frame.midY, hwLoupeFrame.midY, accuracy: 2.5)
                } else if app.buttons["camera.close"].exists {
                    app.buttons["camera.close"].tap()
                }
            }

            // Verify Simplified Chinese strings (`极窄` and `35 mm 静态 (KS)`), then wipe isolated test store.
            app.terminate()
            app.launchArguments = [
                "--ui-test-library", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
            ]
            app.launch()
            XCTAssertTrue(libraryPhotos(app).firstMatch.waitForExistence(timeout: 15))
            libraryPhotos(app).firstMatch.tap()
            XCTAssertTrue(app.buttons["photo.develop"].waitForExistence(timeout: 10))
            app.buttons["photo.develop"].tap()
            XCTAssertTrue(app.buttons["editor.export"].waitForExistence(timeout: 25))
            app.buttons["editor.export"].tap()
            XCTAssertTrue(app.navigationBars["暗房"].waitForExistence(timeout: 5))
            if app.buttons["darkroom.cleanPrint"].exists && !app.buttons["darkroom.cleanPrint"].isSelected {
                app.buttons["darkroom.cleanPrint"].tap()
            }
            if app.buttons["darkroom.expand"].exists && !app.buttons["8 × 10"].isHittable {
                app.buttons["darkroom.expand"].tap()
            }
            XCTAssertTrue(app.buttons["8 × 10"].waitForExistence(timeout: 5))
            app.buttons["8 × 10"].tap()
            if app.buttons["darkroom.expand"].exists && !app.buttons["darkroom.border.thin"].isHittable {
                app.buttons["darkroom.expand"].tap()
            }
            XCTAssertTrue(app.buttons["darkroom.border.thin"].waitForExistence(timeout: 5))
            XCTAssertEqual(app.buttons["darkroom.border.thin"].label, "极窄")
            XCTAssertEqual(app.buttons["darkroom.distress"].label, "做旧")
            app.buttons["darkroom.filmEdge"].tap()
            if !app.buttons["crop.done"].waitForExistence(timeout: 3) {
                if app.buttons["darkroom.expand"].exists && !app.buttons["darkroom.edge.adjustCrop"].isHittable {
                    app.buttons["darkroom.expand"].tap()
                }
                app.buttons["darkroom.edge.adjustCrop"].tap()
                XCTAssertTrue(app.buttons["crop.done"].waitForExistence(timeout: 5))
            }
            XCTAssertEqual(app.buttons["crop.filmGate"].label, "胶片画幅")
            XCTAssertEqual(app.buttons["crop.filmGate"].value as? String, "135 · 全画幅")
            saveShot("10_zh_crop_film_frame", app)
            app.buttons["crop.done"].tap()
            XCTAssertTrue(app.buttons["darkroom.export"].waitForExistence(timeout: 10))
            if app.buttons["darkroom.expand"].exists && !app.buttons["darkroom.edge.perforations.stillKS"].isHittable {
                app.buttons["darkroom.expand"].tap()
            }
            if app.buttons["darkroom.edge.format.film35"].exists && !app.buttons["darkroom.edge.format.film35"].isSelected {
                app.buttons["darkroom.edge.format.film35"].tap()
            }
            XCTAssertTrue(app.buttons["darkroom.edge.perforations.stillKS"].waitForExistence(timeout: 5))
            XCTAssertEqual(app.buttons["darkroom.edge.perforations.stillKS"].label, "35 mm 静态 (KS)")

            app.terminate()
            app.launchArguments = ["--ui-test-library", "--cleanup-test-library"]
            app.launch()
            XCTAssertTrue(app.buttons["library.import"].waitForExistence(timeout: 10))
            XCTAssertEqual(libraryPhotos(app).count, 0)
            didCleanUpDeviceStore = true
            app.terminate()
        #endif
    }

}
