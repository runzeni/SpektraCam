import Combine
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Open the app-owned library. A failed database open never resets the user's data.
struct ContentView: View {
    @State private var library: PhotoLibrary?
    @State private var failure: String?
    @State private var showCamera = false
    @State private var libraryPath: [LibraryRoute] = []
    @State private var libraryScrollRequest = 0
    @State private var captureImportFailure: String?
    @State private var formulaArrival: FormulaArrival?
    @State private var formulaFailure: String?
    @Environment(\.scenePhase) private var scenePhase
    private var checkingCameraControl: Bool {
        #if DEBUG
            ProcessInfo.processInfo.arguments.contains("--ui-test-camera-controls")
        #else
            false
        #endif
    }
    var body: some View {
        Group {
            if checkingCameraControl {
                #if DEBUG
                    CameraExposureControlPreview()
                #endif
            } else if let library {
                LibraryView(library: library, path: $libraryPath, scrollToLatestRequest: libraryScrollRequest)
                    .environment(\.openCamera, { showCamera = true })
                    .fullScreenCover(isPresented: $showCamera) {
                        CameraView(library: library) {
                            do { try library.flushForLibrary() } catch {
                                library.saveFailure = error.localizedDescription
                            }
                            libraryPath.removeAll()
                            libraryScrollRequest += 1
                            showCamera = false
                        }
                    }
                    .task {
                        #if DEBUG
                            // Layout and device UI checks import a host file or in-app synthetic fixture into the isolated test library.
                            let arguments = ProcessInfo.processInfo.arguments
                            if arguments.contains("--ui-test-library"), library.photos.isEmpty {
                                for (index, argument) in arguments.enumerated()
                                where index + 1 < arguments.count {
                                    if argument == "--ui-test-import" {
                                        let hostURL = URL(fileURLWithPath: arguments[index + 1])
                                        if FileManager.default.fileExists(atPath: hostURL.path) {
                                            _ = try? await library.importPhoto(hostURL)
                                        } else if let synthetic = Self.makeUITestPhoto(
                                            kind: hostURL.lastPathComponent.localizedCaseInsensitiveContains("bright")
                                                ? "bright-sky" : "standard"
                                        ) {
                                            defer { try? FileManager.default.removeItem(at: synthetic) }
                                            _ = try? await library.importPhoto(synthetic)
                                        }
                                    } else if argument == "--ui-test-synthetic-photo",
                                        let synthetic = Self.makeUITestPhoto(kind: arguments[index + 1])
                                    {
                                        defer { try? FileManager.default.removeItem(at: synthetic) }
                                        _ = try? await library.importPhoto(synthetic)
                                    }
                                }
                            }
                        #endif
                        await library.purgeExpired()
                        await recoverCaptures(library)
                        try? await library.luts.load()
                        try? await library.formulae.load()
                        #if DEBUG
                            await FormulaValidation.run(library)
                        #endif
                        #if DEBUG && targetEnvironment(simulator)
                            await FormulaCardChecks.run(library)
                            // Stand in for the system pickers and "Open in SpektraCam".
                            let options = ProcessInfo.processInfo.arguments
                            for (index, option) in options.enumerated() where index + 1 < options.count {
                                let file = URL(fileURLWithPath: options[index + 1])
                                if option == "--ui-test-lut" { _ = try? await library.luts.importFile(file) }
                                if option == "--ui-test-open" { openFormula(file) }
                                if option == "--ui-test-open-link", let link = URL(string: options[index + 1]) {
                                    openFormula(link)
                                }
                            }
                        #endif
                        try? await library.repairRAWDimensions()
                        #if DEBUG || PERFORMANCE_CHECKS
                            await DarkroomOrientationChecks.run(library)
                            await RenderPerformanceChecks.run(library)
                            await ExportValidation.checkSDR(library)
                        #endif
                        #if DEBUG
                            await ExportValidation.checkBypass(library)
                            await ExportValidation.run(library)
                            if ProcessInfo.processInfo.arguments.contains("--ui-test-library"),
                               ProcessInfo.processInfo.arguments.contains("--exit-after-checks") {
                                print("UI_TEST_LIBRARY_EXIT_CLEAN")
                                fflush(stdout)
                                exit(0)
                            }
                        #endif
                    }
            } else if let failure {
                ContentUnavailableView {
                    Label(
                        String(
                            localized: "library.open_failed",
                            defaultValue: "Couldn’t open library"),
                        systemImage: "exclamationmark.triangle")
                } description: {
                    Text(failure)
                } actions: {
                    Button(
                        String(localized: "common.retry", defaultValue: "Retry"),
                        action: openLibrary)
                }
            } else {
                ProgressView(
                    String(localized: "library.opening", defaultValue: "Opening library…"))
            }
        }
        .task { if !checkingCameraControl && library == nil { openLibrary() } }
        .onOpenURL(perform: openFormula)
        .sheet(item: $formulaArrival) { arrival in
            if let library { FormulaImportSheet(library: library, arrival: arrival) }
        }
        .failureAlert(
            String(localized: "formula.import.failed", defaultValue: "Couldn’t Open Formula"),
            message: $formulaFailure)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            if let library {
                Task {
                    await library.images.discardMemory()
                    await library.files.discardPreparedPhoto()
                    LibraryImages.clearRenderingContextCaches()
                    await library.images.resources.releaseWorkingCachesIfLoaded()
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, let library {
                Task { await library.purgeExpired() }
            } else if phase == .background, let library {
                Task { await library.handleSceneBackground() }
            } else if phase != .active {
                library?.savePending()
            }
        }
        .alert(
            String(
                localized: "camera.import_failed", defaultValue: "Couldn’t import capture"),
            isPresented: Binding(
                get: { captureImportFailure != nil },
                set: { if !$0 { captureImportFailure = nil } }
            )
        ) {
            Button(String(localized: "common.retry", defaultValue: "Retry")) {
                if let library { Task { await recoverCaptures(library) } }
            }
            Button(String(localized: "common.later", defaultValue: "Later"), role: .cancel) {}
        } message: {
            Text(
                String(
                    localized: "camera.capture_kept_with_error",
                    defaultValue:
                        "The capture is kept on this device. \(captureImportFailure ?? "")"))
        }
        .alert(
            String(localized: "editor.couldn_t_save_edits", defaultValue: "Couldn’t save edits"),
            isPresented: Binding(
                get: { library?.saveFailure != nil },
                set: {
                    if !$0 { library?.saveFailure = nil }
                })
        ) {
            Button(String(localized: "common.retry", defaultValue: "Retry")) {
                library?.savePending()
            }
        } message: {
            Text(library?.saveFailure ?? "")
        }
    }
    /// A `.rnformula` opened from Files, Messages or AirDrop, or a link that carries a formula.
    /// It is shown first, never added unasked.
    private func openFormula(_ url: URL) {
        guard url.isFileURL || FormulaLink.claims(url.absoluteString) else { return }
        do {
            formulaArrival =
                try url.isFileURL ? FormulaArrival(url: url) : FormulaArrival(link: url.absoluteString)
        } catch {
            formulaFailure = error.localizedDescription
        }
    }
    private func recoverCaptures(_ library: PhotoLibrary) async {
        do {
            try await library.recoverCaptures()
            captureImportFailure = nil
        } catch { captureImportFailure = error.localizedDescription }
    }
    private func openLibrary() {
        do {
            #if DEBUG
                // UI checks use their own store. They cannot reset or touch the user's app library.
                if ProcessInfo.processInfo.arguments.contains("--ui-test-library") {
                    var base = URL.applicationSupportDirectory.appendingPathComponent(
                        "SpektraCamUITests")
                    let args = ProcessInfo.processInfo.arguments
                    let defaults = UserDefaults.standard
                    if args.contains("--cleanup-test-library") {
                        try? FileManager.default.removeItem(at: base)
                        if defaults.bool(forKey: "uitest.backup.saved") {
                            for (backup, real) in [
                                ("uitest.backup.detailsExpanded", PhotoInfoPanel.detailsExpandedKey),
                                ("uitest.backup.loupe", "darkroom.loupe"),
                            ] {
                                if let saved = defaults.object(forKey: backup) {
                                    defaults.set(saved, forKey: real)
                                } else {
                                    defaults.removeObject(forKey: real)
                                }
                                defaults.removeObject(forKey: backup)
                            }
                            defaults.removeObject(forKey: "uitest.backup.saved")
                        }
                        base = FileManager.default.temporaryDirectory.appendingPathComponent(
                            "SpektraCamUITestsCleanup")
                        try? FileManager.default.removeItem(at: base)
                        try? FileManager.default.removeItem(
                            at: URL.cachesDirectory.appendingPathComponent("formula-validation.json"))
                        try? FileManager.default.removeItem(
                            at: URL.cachesDirectory.appendingPathComponent("DarkroomOrientationChecks"))
                    } else if args.contains("--reset-test-library") {
                        try? FileManager.default.removeItem(at: base)
                        if !defaults.bool(forKey: "uitest.backup.saved") {
                            if let v = defaults.object(forKey: PhotoInfoPanel.detailsExpandedKey) {
                                defaults.set(v, forKey: "uitest.backup.detailsExpanded")
                            }
                            if let v = defaults.object(forKey: "darkroom.loupe") {
                                defaults.set(v, forKey: "uitest.backup.loupe")
                            }
                            defaults.set(true, forKey: "uitest.backup.saved")
                        }
                        defaults.removeObject(forKey: PhotoInfoPanel.detailsExpandedKey)
                        defaults.removeObject(forKey: "darkroom.loupe")
                    }
                    library = try PhotoLibrary(
                        root: base, cache: base.appendingPathComponent("Cache"))
                } else {
                    library = try PhotoLibrary()
                }
            #else
                library = try PhotoLibrary()
            #endif
            failure = nil
        } catch { failure = error.localizedDescription }
    }

    #if DEBUG
        private static func makeUITestPhoto(kind: String) -> URL? {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let isBrightSky = kind == "bright-sky"
            let size = isBrightSky ? CGSize(width: 1800, height: 2400) : CGSize(width: 3000, height: 2000)
            let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
                if isBrightSky {
                    UIColor(white: 0.14, alpha: 1).setFill()
                    ctx.fill(CGRect(origin: .zero, size: size))
                    // Blown-out bright window sky in the upper region matching IMG_1850.PNG.
                    UIColor.white.setFill()
                    ctx.fill(CGRect(x: 80, y: 0, width: 1220, height: 1120))
                    UIColor(red: 0.76, green: 0.84, blue: 0.94, alpha: 1).setFill()
                    ctx.fill(CGRect(x: 80, y: 1180, width: 1220, height: 520))
                    UIColor(red: 0.42, green: 0.46, blue: 0.44, alpha: 1).setFill()
                    ctx.fill(CGRect(x: 80, y: 1740, width: 1220, height: 520))
                } else {
                    UIColor(red: 0.44, green: 0.62, blue: 0.78, alpha: 1).setFill()
                    ctx.fill(CGRect(x: 0, y: 0, width: 3000, height: 1100))
                    UIColor(red: 0.23, green: 0.36, blue: 0.28, alpha: 1).setFill()
                    ctx.fill(CGRect(x: 0, y: 1100, width: 3000, height: 900))
                    UIColor(red: 0.88, green: 0.74, blue: 0.52, alpha: 1).setFill()
                    ctx.fill(CGRect(x: 360, y: 760, width: 780, height: 680))
                    UIColor(white: 0.92, alpha: 1).setStroke()
                    ctx.cgContext.setLineWidth(6)
                    for step in stride(from: 1400, through: 2760, by: 80) {
                        ctx.cgContext.move(to: CGPoint(x: step, y: 320))
                        ctx.cgContext.addLine(to: CGPoint(x: step, y: 1680))
                    }
                    ctx.cgContext.strokePath()
                }
            }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("spektracam-uitest-\(kind)-\(UUID().uuidString).jpg")
            guard let data = image.jpegData(compressionQuality: 0.92) else { return nil }
            do {
                try data.write(to: url, options: .atomic)
                return url
            } catch {
                return nil
            }
        }
    #endif
}

#Preview { ContentView() }
