import SwiftUI
import UIKit

@main
struct SpektraCamApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        WindowGroup {
            ContentView().appAccent()
        }
    }
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

    /// True on all iPhones except iPhone Duo.
    static func locksCameraToPortrait(in window: UIWindow?) -> Bool {
        guard UIDevice.current.userInterfaceIdiom == .phone, !hasHinge else { return false }
        if #available(iOS 27.1, *), let traits = window?.traitCollection {
            if traits.verticalBarEdge != .unspecified { return false }
            if traits.horizontalSizeClass == .regular && traits.verticalSizeClass == .regular {
                return false
            }
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

    static func setCameraActive(_ active: Bool, in window: UIWindow? = nil) {
        cameraActive = active
        applyOrientationPolicy(in: window)
    }

    static func applyOrientationPolicy(in targetWindow: UIWindow? = nil) {
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
            } else {
                let desired: UIInterfaceOrientationMask
                switch UIDevice.current.orientation {
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
