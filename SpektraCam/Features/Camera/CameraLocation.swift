import CoreLocation
import Foundation
import ImageIO

/// A fresh, optional fix. Coordinates stay on device and are written only to captured files.
nonisolated struct CaptureLocation: Sendable {
    let latitude: Double, longitude: Double, accuracy: Double
    let altitude: Double?
    let date: Date
    init?(_ fix: CLLocation, now: Date = Date(), maxAge: TimeInterval = 60) {
        guard fix.horizontalAccuracy.isFinite, fix.horizontalAccuracy >= 0,
            abs(fix.timestamp.timeIntervalSince(now)) < maxAge,
            CLLocationCoordinate2DIsValid(fix.coordinate)
        else { return nil }
        latitude = fix.coordinate.latitude
        longitude = fix.coordinate.longitude
        accuracy = fix.horizontalAccuracy
        altitude = fix.verticalAccuracy >= 0 && fix.altitude.isFinite ? fix.altitude : nil
        date = fix.timestamp
    }
    var gps: [String: Any] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy:MM:dd"
        let day = formatter.string(from: date)
        formatter.dateFormat = "HH:mm:ss.SSS"
        var result: [String: Any] = [
            kCGImagePropertyGPSLatitude as String: abs(latitude),
            kCGImagePropertyGPSLatitudeRef as String: latitude < 0 ? "S" : "N",
            kCGImagePropertyGPSLongitude as String: abs(longitude),
            kCGImagePropertyGPSLongitudeRef as String: longitude < 0 ? "W" : "E",
            kCGImagePropertyGPSHPositioningError as String: accuracy,
            kCGImagePropertyGPSDateStamp as String: day,
            kCGImagePropertyGPSTimeStamp as String: formatter.string(from: date),
        ]
        if let altitude {
            result[kCGImagePropertyGPSAltitude as String] = abs(altitude)
            result[kCGImagePropertyGPSAltitudeRef as String] = altitude < 0 ? 1 : 0
        }
        return result
    }
}

@MainActor final class CameraLocation: NSObject, @MainActor CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var active = false
    private var fix: CLLocation?
    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = kCLDistanceFilterNone
    }
    var captureLocation: CaptureLocation? {
        if let fix {
            if let fresh = CaptureLocation(fix) { return fresh }
            if active, abs(fix.timestamp.timeIntervalSinceNow) > 45 {
                switch manager.authorizationStatus {
                case .authorizedWhenInUse, .authorizedAlways: manager.requestLocation()
                default: break
                }
            }
            if let relaxed = CaptureLocation(fix, maxAge: 180) { return relaxed }
        }
        guard active else { return nil }
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            if let cached = manager.location, let valid = CaptureLocation(cached, maxAge: 180) {
                fix = cached
                return valid
            }
            manager.requestLocation()
        default: break
        }
        return nil
    }
    func setActive(_ active: Bool) {
        self.active = active
        if !active {
            manager.stopUpdatingLocation()
            return
        }
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            if let cached = manager.location, CaptureLocation(cached, maxAge: 180) != nil {
                fix = cached
            }
            manager.startUpdatingLocation()
            if fix.map({ abs($0.timestamp.timeIntervalSinceNow) > 45 }) ?? true {
                manager.requestLocation()
            }
        default: break
        }
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if active { setActive(true) }
        if manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted { fix = nil }
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        fix = locations.last
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // A missing location never prevents capture.
    }
}
