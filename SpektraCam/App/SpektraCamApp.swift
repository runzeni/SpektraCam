import SwiftUI
import UIKit

@main
struct SpektraCamApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        WindowGroup {
            ContentView()
                .appAccent()
                .background(AppHingeProbe().allowsHitTesting(false))
        }
    }
}

/// Registers a root-level hinge observer on launch so iPhone Duo is recognized even when folded
/// before `CameraView` is ever presented.
private struct AppHingeProbe: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        if #available(iOS 27.1, *) {
            let hinge = UIHingeInteraction { [weak view] _, update in
                if update.hinge != nil {
                    AppDelegate.setHasHinge(true, in: view?.window)
                }
            }
            view.addInteraction(hinge)
        }
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

/// While the camera is open on a standard iPhone, the interface stays locked in portrait and
/// only the glyphs turn in place. iPad and iPhone Duo keep free rotation.
final class AppDelegate: NSObject, UIApplicationDelegate {
    private(set) static var cameraActive = false
    private(set) static var hasHinge = false

    static func setHasHinge(_ hinged: Bool, in window: UIWindow?) {
        guard hasHinge != hinged else { return }
        hasHinge = hinged
        if cameraActive { applyOrientationPolicy(in: window) }
    }

    static var defaultLocksCameraToPortrait: Bool {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window =
            scenes.flatMap(\.windows).first(where: \.isKeyWindow)
            ?? scenes.first?.windows.first
        return locksCameraToPortrait(in: window)
    }

    /// True on all iPhones except iPhone Duo.
    static func locksCameraToPortrait(in window: UIWindow?) -> Bool {
        guard UIDevice.current.userInterfaceIdiom == .phone, !hasHinge else { return false }
        if #available(iOS 27.1, *), let traits = window?.traitCollection {
            if traits.verticalBarEdge != .unspecified { return false }
            if traits.horizontalSizeClass == .regular && traits.verticalSizeClass == .regular {
                return false
            }
        }
        if let bounds = window?.bounds, min(bounds.width, bounds.height) > 500 {
            return false
        }
        return true
    }

    func application(
        _ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        if Self.cameraActive && Self.locksCameraToPortrait(in: window) {
            return .portrait
        }
        return UIDevice.current.userInterfaceIdiom == .pad ? .all : .allButUpsideDown
    }

    static func setCameraActive(
        _ active: Bool, in window: UIWindow? = nil,
        preferredDeviceOrientation: UIDeviceOrientation = .unknown
    ) {
        cameraActive = active
        applyOrientationPolicy(in: window, preferredDeviceOrientation: preferredDeviceOrientation)
    }

    static func applyOrientationPolicy(
        in targetWindow: UIWindow? = nil,
        preferredDeviceOrientation: UIDeviceOrientation = .unknown
    ) {
        let scenes: [UIWindowScene]
        if let scene = targetWindow?.windowScene {
            scenes = [scene]
        } else {
            scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        }
        for scene in scenes {
            let window = targetWindow ?? scene.keyWindow ?? scene.windows.first
            let lockPortrait = cameraActive && locksCameraToPortrait(in: window)
            let allowed: UIInterfaceOrientationMask =
                UIDevice.current.userInterfaceIdiom == .pad ? .all : .allButUpsideDown
            for candidate in scene.windows {
                var controller = candidate.rootViewController
                while let current = controller {
                    current.setNeedsUpdateOfSupportedInterfaceOrientations()
                    controller = current.presentedViewController
                }
            }
            if lockPortrait {
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { _ in }
            } else if cameraActive || !locksCameraToPortrait(in: window) {
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: allowed)) { _ in }
            } else {
                let current = UIDevice.current.orientation
                let effective =
                    current.isValidInterfaceOrientation ? current : preferredDeviceOrientation
                let desired: UIInterfaceOrientationMask
                switch effective {
                case .landscapeLeft: desired = .landscapeRight
                case .landscapeRight: desired = .landscapeLeft
                case .portraitUpsideDown where UIDevice.current.userInterfaceIdiom == .pad:
                    desired = .portraitUpsideDown
                case .portrait: desired = .portrait
                default: desired = allowed
                }
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: desired.intersection(allowed))) { _ in }
            }
        }
    }
}
