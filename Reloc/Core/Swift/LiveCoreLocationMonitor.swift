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
@MainActor
public final class LiveCoreLocationMonitor: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published public private(set) var latest: LiveLocationTelemetry?
    @Published public private(set) var isMonitoring = false
    @Published public private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined

    private let manager = CLLocationManager()

    public override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .otherNavigation
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
