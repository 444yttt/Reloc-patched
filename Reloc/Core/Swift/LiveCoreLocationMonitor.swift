import CoreLocation
import Foundation

public struct LiveLocationTelemetry: Equatable, Sendable {
    public let latitude: Double
    public let longitude: Double
    public let altitude: Double
    public let horizontalAccuracy: Double
    public let isSimulatedBySoftware: Bool?
    public let isProducedByAccessory: Bool?
    public let timestamp: Date
}

/// Lightweight CoreLocation observer used for "fly to current location" and live
/// inspection of iOS CLLocationSourceInformation flags (isSimulatedBySoftware / isProducedByAccessory).
///
/// Accuracy is fixed for the life of the manager. Mid-session changes to
/// `desiredAccuracy` / `distanceFilter` caused locationd to emit a burst of
/// `0xFFFC`→`0xFFFA` after the third patch.
@MainActor
public final class LiveCoreLocationMonitor: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published public private(set) var latest: LiveLocationTelemetry?
    @Published public private(set) var isMonitoring = false
    @Published public private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined

    private let manager = CLLocationManager()

    public override init() {
        super.init()
        manager.delegate = self
        // Fixed session configuration: 10m is enough to confirm an accessory
        // fix without requesting BestForNavigation, and is never retuned later.
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .other
        manager.pausesLocationUpdatesAutomatically = false
        authorizationStatus = manager.authorizationStatus
    }

    public func requestAndStart() {
        authorizationStatus = manager.authorizationStatus
        if manager.authorizationStatus == .notDetermined {
            manager.requestAlwaysAuthorization()
        }
        manager.startUpdatingLocation()
        isMonitoring = true
    }

    public func pulseForAccessoryLock() {
        authorizationStatus = manager.authorizationStatus
        manager.stopUpdatingLocation()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.isMonitoring else { return }
            self.manager.startUpdatingLocation()
            self.manager.requestLocation()
        }
    }

    public func requestOneShot() {
        authorizationStatus = manager.authorizationStatus
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        manager.requestLocation()
    }

    public func stop() {
        manager.stopUpdatingLocation()
        isMonitoring = false
    }

    public nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorizationStatus = status
            if self.isMonitoring, status == .authorizedAlways || status == .authorizedWhenInUse {
                self.manager.startUpdatingLocation()
            }
        }
    }

    public nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        let snap = LiveLocationTelemetry(
            latitude: loc.coordinate.latitude,
            longitude: loc.coordinate.longitude,
            altitude: loc.altitude,
            horizontalAccuracy: loc.horizontalAccuracy,
            isSimulatedBySoftware: loc.sourceInformation?.isSimulatedBySoftware,
            isProducedByAccessory: loc.sourceInformation?.isProducedByAccessory,
            timestamp: loc.timestamp
        )
        Task { @MainActor in
            self.latest = snap
        }
    }

    public nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Ignore transient CoreLocation failures.
    }
}
