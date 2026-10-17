import CoreLocation

/// Where you are, so the globe can turn to you and work out passes. Asks for
/// "while using the app" only, and only while the app is on screen.
@MainActor
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    var onLocation: ((CLLocation) -> Void)?
    /// Called when the answer to "may Orbit use your location" is known or changes.
    var onAccess: ((Bool) -> Void)?

    private let manager = CLLocationManager()
    private var wanted = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 10
    }

    func start() {
        wanted = true
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways: manager.startUpdatingLocation()
        default: break
        }
    }

    func stop() {
        wanted = false
        manager.stopUpdatingLocation()
    }

    // CLLocationManager calls its delegate on the thread it was made on, which
    // is the main one.

    nonisolated func locationManagerDidChangeAuthorization(_: CLLocationManager) {
        MainActor.assumeIsolated {
            switch manager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways:
                onAccess?(true)
                if wanted { manager.startUpdatingLocation() }
            case .denied, .restricted:
                onAccess?(false)
            default:
                break
            }
        }
    }

    nonisolated func locationManager(_: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated {
            if let last = locations.last { onLocation?(last) }
        }
    }

    nonisolated func locationManager(_: CLLocationManager, didFailWithError error: Error) {
        // No fix yet (indoors, or the simulator has no location set). It keeps trying.
    }
}
