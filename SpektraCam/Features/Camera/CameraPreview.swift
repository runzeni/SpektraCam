@preconcurrency import AVFoundation
import SwiftUI
import UIKit

/// Bridges `AVCapturePhotoOutputReadinessCoordinator` onto the main actor so shutter availability
/// updates synchronously on the main queue without `AsyncStream` ring-buffer drops.
nonisolated final class CameraReadinessBridge: NSObject,
    AVCapturePhotoOutputReadinessCoordinatorDelegate, @unchecked Sendable
{
    private let coordinator: AVCapturePhotoOutputReadinessCoordinator
    @MainActor private var onChange: ((AVCapturePhotoOutput.CaptureReadiness) -> Void)?

    init(output: AVCapturePhotoOutput) {
        self.coordinator = AVCapturePhotoOutputReadinessCoordinator(photoOutput: output)
        super.init()
    }

    @MainActor var currentReadiness: AVCapturePhotoOutput.CaptureReadiness {
        coordinator.captureReadiness
    }

    @MainActor func connect(
        onChange: @escaping (AVCapturePhotoOutput.CaptureReadiness) -> Void
    ) {
        self.onChange = onChange
        coordinator.delegate = self
        onChange(coordinator.captureReadiness)
    }

    @MainActor func disconnect() {
        coordinator.delegate = nil
        onChange = nil
    }

    func readinessCoordinator(
        _ coordinator: AVCapturePhotoOutputReadinessCoordinator,
        captureReadinessDidChange captureReadiness: AVCapturePhotoOutput.CaptureReadiness
    ) {
        MainActor.assumeIsolated {
            self.onChange?(captureReadiness)
        }
    }
}

/// Only the actor configures the session. This bridge attaches it to a main-thread preview.
nonisolated final class CameraPreviewSource: @unchecked Sendable {
    private let session: AVCaptureSession
    private let device: AVCaptureDevice
    @MainActor private var rotation: AVCaptureDevice.RotationCoordinator?
    @MainActor private var observation: NSKeyValueObservation?
    init(session: AVCaptureSession, device: AVCaptureDevice) {
        self.session = session
        self.device = device
    }
    @MainActor var captureRotation: CGFloat {
        rotation?.videoRotationAngleForHorizonLevelCapture ?? 90
    }
    @MainActor func connect(to view: CameraPreview.View) {
        if view.previewLayer.session !== session { view.previewLayer.session = session }
        view.previewLayer.videoGravity = .resizeAspect
        let coordinator = AVCaptureDevice.RotationCoordinator(
            device: device, previewLayer: view.previewLayer)
        rotation = coordinator
        observation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]
        ) { [weak view] coordinator, _ in
            // RotationCoordinator documents delivery on the main queue.
            MainActor.assumeIsolated {
                let angle = coordinator.videoRotationAngleForHorizonLevelPreview
                if let connection = view?.previewLayer.connection,
                    connection.isVideoRotationAngleSupported(angle)
                {
                    connection.videoRotationAngle = angle
                }
            }
        }
    }
    @MainActor func disconnect(from view: CameraPreview.View) {
        observation = nil
        rotation = nil
        view.previewLayer.session = nil
    }
}

struct CameraPreview: UIViewRepresentable {
    let source: CameraPreviewSource
    var onFocus: ((CGPoint, CGPoint) -> Void)?
    func makeUIView(context: Context) -> View {
        let view = View()
        source.connect(to: view)
        context.coordinator.source = source
        context.coordinator.onFocus = onFocus
        view.addGestureRecognizer(
            UITapGestureRecognizer(
                target: context.coordinator, action: #selector(Coordinator.focus(_:))))
        return view
    }
    func updateUIView(_ view: View, context: Context) {
        context.coordinator.onFocus = onFocus
        if context.coordinator.source !== source {
            source.connect(to: view)
            context.coordinator.source = source
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    static func dismantleUIView(_ view: View, coordinator: Coordinator) {
        coordinator.source?.disconnect(from: view)
        coordinator.onFocus = nil
    }
    final class Coordinator: NSObject {
        var source: CameraPreviewSource?
        var onFocus: ((CGPoint, CGPoint) -> Void)?
        @objc func focus(_ tap: UITapGestureRecognizer) {
            guard let view = tap.view as? View else { return }
            let point = tap.location(in: view)
            onFocus?(
                view.convert(point, to: nil),
                view.previewLayer.captureDevicePointConverted(fromLayerPoint: point))
        }
    }
    final class View: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}

/// The preview remains borderless. Grid marks do not intercept touch or accessibility.
struct CameraViewfinder<Status: SwiftUI.View>: SwiftUI.View {
    let model: CameraModel
    /// The sensor's long side follows the long side of the space.
    var landscape = false
    /// Shown inside the frame while there is no live view: starting, on hold, unavailable.
    @ViewBuilder var status: Status
    @State private var focusPoint: CGPoint?
    @State private var focusRevision = UUID()
    private var showsDemoScene: Bool {
        #if DEBUG && targetEnvironment(simulator)
            return CameraModel.demo && model.state == .ready
                && (CameraModel.demoScene || CameraModel.demoSceneImagePath != nil)
        #else
            return false
        #endif
    }
    var body: some SwiftUI.View {
        Group {
            if let source = model.source {
                CameraPreview(source: source) { point, devicePoint in
                    guard model.state == .ready, !model.busy else { return }
                    focusPoint = point
                    focusRevision = UUID()
                    Task { await model.focus(at: devicePoint) }
                }.accessibilityHidden(true)
            } else if showsDemoScene {
                demoPreviewContent
                    .accessibilityHidden(true)
            } else {
                Color.black
            }
        }
        .aspectRatio(landscape ? 4.0 / 3 : 3.0 / 4, contentMode: .fit)
        .overlay {
            if model.source != nil || showsDemoScene {
                GeometryReader { proxy in
                    Path { path in
                        for fraction in [1.0 / 3, 2.0 / 3] {
                            let x = proxy.size.width * fraction
                            let y = proxy.size.height * fraction
                            path.move(to: CGPoint(x: x, y: 0))
                            path.addLine(to: CGPoint(x: x, y: proxy.size.height))
                            path.move(to: CGPoint(x: 0, y: y))
                            path.addLine(to: CGPoint(x: proxy.size.width, y: y))
                        }
                    }.stroke(.white.opacity(0.22), lineWidth: 0.5)
                }.allowsHitTesting(false)
            }
        }
        .overlay {
            if let point = focusPoint, model.state == .ready {
                GeometryReader { proxy in
                    let origin = proxy.frame(in: .global).origin
                    let x = min(max(point.x - origin.x, 30), proxy.size.width - 30)
                    let y = min(max(point.y - origin.y, 30), proxy.size.height - 30)
                    Rectangle().stroke(.yellow, lineWidth: 1)
                        .frame(width: 56, height: 56).position(x: x, y: y)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
        }
        .overlay { status }
        .clipShape(.rect(cornerRadius: 20))
        .background {
            RoundedRectangle(cornerRadius: 21)
                .strokeBorder(.white.opacity(0.24), lineWidth: 1)
                .padding(-1)
                .overlay {
                    RoundedRectangle(cornerRadius: 22)
                        .strokeBorder(.black.opacity(0.85), lineWidth: 1)
                        .padding(-2)
                }
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("camera.viewfinder")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: model.selectedLens?.id) { _, _ in focusPoint = nil }
        .task(id: focusRevision) {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            focusPoint = nil
        }
    }

    @ViewBuilder private var demoPreviewContent: some SwiftUI.View {
        #if DEBUG && targetEnvironment(simulator)
            DemoViewfinderScene(imagePath: CameraModel.demoSceneImagePath)
        #else
            Color.black
        #endif
    }
}

#if DEBUG && targetEnvironment(simulator)
/// Fixed asymmetric UI-test scene with four corner marks and an upright orientation cue.
private struct DemoViewfinderScene: SwiftUI.View {
    let imagePath: String?
    private var loadedImage: UIImage? {
        guard let imagePath, !imagePath.isEmpty else { return nil }
        return UIImage(contentsOfFile: imagePath)
    }

    var body: some SwiftUI.View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                if let image = loadedImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: size.width, height: size.height)
                        .clipped()
                } else {
                    Canvas { context, canvasSize in
                        let w = canvasSize.width
                        let h = canvasSize.height
                        let sky = Path(CGRect(x: 0, y: 0, width: w, height: h * 0.62))
                        context.fill(
                            sky,
                            with: .linearGradient(
                                Gradient(colors: [
                                    Color(red: 0.72, green: 0.78, blue: 0.80),
                                    Color(red: 0.56, green: 0.63, blue: 0.66),
                                ]),
                                startPoint: .zero,
                                endPoint: CGPoint(x: 0, y: h * 0.62)))
                        let road = Path(CGRect(x: 0, y: h * 0.62, width: w, height: h * 0.38))
                        context.fill(
                            road,
                            with: .linearGradient(
                                Gradient(colors: [
                                    Color(red: 0.24, green: 0.27, blue: 0.29),
                                    Color(red: 0.14, green: 0.16, blue: 0.18),
                                ]),
                                startPoint: CGPoint(x: 0, y: h * 0.62),
                                endPoint: CGPoint(x: 0, y: h)))
                        var buildingLeft = Path()
                        buildingLeft.addRect(CGRect(x: w * 0.14, y: h * 0.18, width: w * 0.22, height: h * 0.44))
                        context.fill(buildingLeft, with: .color(Color(red: 0.34, green: 0.39, blue: 0.42)))
                        var buildingRight = Path()
                        buildingRight.addRect(CGRect(x: w * 0.70, y: h * 0.14, width: w * 0.24, height: h * 0.48))
                        context.fill(buildingRight, with: .color(Color(red: 0.45, green: 0.50, blue: 0.53)))
                        var beam = Path()
                        beam.move(to: CGPoint(x: 0, y: 0))
                        beam.addLine(to: CGPoint(x: w * 0.52, y: 0))
                        beam.addLine(to: CGPoint(x: 0, y: h * 0.34))
                        beam.closeSubpath()
                        context.fill(beam, with: .color(Color(red: 0.08, green: 0.09, blue: 0.10)))
                        var truck = Path()
                        truck.addRoundedRect(
                            in: CGRect(x: w * 0.16, y: h * 0.50, width: w * 0.30, height: h * 0.13),
                            cornerSize: CGSize(width: 4, height: 4))
                        context.fill(truck, with: .color(Color(red: 0.72, green: 0.20, blue: 0.18)))
                        for step in 0..<3 {
                            let fx = CGFloat(step)
                            let cx = w * (0.20 + 0.14 * fx)
                            let cy = h * (0.72 + 0.07 * fx)
                            var cone = Path()
                            cone.move(to: CGPoint(x: cx, y: cy - 12))
                            cone.addLine(to: CGPoint(x: cx - 7, y: cy + 8))
                            cone.addLine(to: CGPoint(x: cx + 7, y: cy + 8))
                            cone.closeSubpath()
                            context.fill(cone, with: .color(Color(red: 0.88, green: 0.36, blue: 0.16)))
                        }
                    }
                    VStack {
                        HStack {
                            Text(verbatim: "L").padding(.leading, 18)
                            Spacer()
                            Text(verbatim: "TOP ▲")
                            Spacer()
                            Text(verbatim: "R").padding(.trailing, 18)
                        }
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.75))
                        .padding(.top, 10)
                        Spacer()
                    }
                }
                DemoCornerMarks()
            }
        }
    }
}

private struct DemoCornerMarks: SwiftUI.View {
    var body: some SwiftUI.View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height
            let inset: CGFloat = 10
            let arm: CGFloat = 16
            Path { path in
                // Top-left
                path.move(to: CGPoint(x: inset, y: inset + arm))
                path.addLine(to: CGPoint(x: inset, y: inset))
                path.addLine(to: CGPoint(x: inset + arm, y: inset))
                // Top-right
                path.move(to: CGPoint(x: w - inset - arm, y: inset))
                path.addLine(to: CGPoint(x: w - inset, y: inset))
                path.addLine(to: CGPoint(x: w - inset, y: inset + arm))
                // Bottom-left
                path.move(to: CGPoint(x: inset, y: h - inset - arm))
                path.addLine(to: CGPoint(x: inset, y: h - inset))
                path.addLine(to: CGPoint(x: inset + arm, y: h - inset))
                // Bottom-right
                path.move(to: CGPoint(x: w - inset - arm, y: h - inset))
                path.addLine(to: CGPoint(x: w - inset, y: h - inset))
                path.addLine(to: CGPoint(x: w - inset, y: h - inset - arm))
            }
            .stroke(Color.yellow, lineWidth: 2)
        }
        .allowsHitTesting(false)
    }
}
#endif

struct CameraHistogram: SwiftUI.View {
    let model: CameraModel
    var body: some SwiftUI.View {
        let bins = model.readings.histogram
        Canvas { context, size in
            var path = Path()
            path.move(to: CGPoint(x: 0, y: size.height))
            for (index, value) in bins.enumerated() {
                path.addLine(
                    to: CGPoint(
                        x: CGFloat(index) / CGFloat(bins.count - 1) * size.width,
                        y: (1 - value) * size.height))
            }
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.closeSubpath()
            context.fill(path, with: .color(.white.opacity(0.75)))
        }
        .accessibilityLabel(
            String(
                localized: "camera.histogram",
                defaultValue: "Preview brightness histogram")
        )
        .accessibilityHint(
            String(
                localized: "camera.histogram_hint",
                defaultValue: "Shows the processed camera preview, not RAW clipping."))
    }
}

struct CameraExposureReadout: SwiftUI.View {
    let model: CameraModel
    static func primaryLine(_ reading: CameraReadings) -> String {
        let apertureText = reading.aperture > 0
            ? "ƒ\(reading.aperture.formatted(.number.precision(.fractionLength(1))))"
            : "ƒ—"
        let shutterText = reading.seconds > 0
            ? (reading.seconds < 1
                ? "1/\(Int((1 / reading.seconds).rounded())) s"
                : "\(reading.seconds.formatted(.number.precision(.fractionLength(1)))) s")
            : "— s"
        return "\(apertureText) | \(shutterText)"
    }
    var body: some SwiftUI.View {
        let reading = model.readings
        VStack(alignment: .trailing, spacing: 0) {
            Text(Self.primaryLine(reading))
            Text(
                reading.iso > 0
                    ? String(
                        localized: "camera.iso",
                        defaultValue: "ISO \(Int(reading.iso.rounded()))")
                    : String(localized: "camera.iso_unknown", defaultValue: "ISO —"))
        }
        .font(.caption2.weight(.medium)).monospacedDigit().lineLimit(1).foregroundStyle(.secondary)
        .dynamicTypeSize(...DynamicTypeSize.large)
        .accessibilityElement(children: .combine)
    }
}
