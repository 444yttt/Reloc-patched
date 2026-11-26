import AVFoundation
import CoreLocation
import Foundation
import UIKit

/// Keeps Reloc genuinely alive in the background while injecting coordinates over 10.7.0.1
/// AND keeps `locationd` continuously subscribed (0xFFFA) to the external accessory GPS.
@MainActor
public final class BackgroundKeepAlive: NSObject, CLLocationManagerDelegate {
    private let locationManager = CLLocationManager()
    private var backgroundActivitySession: AnyObject?
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var audioPlayer: AVAudioPlayer?
    private var watchdogTimer: Timer?
    private var isActive = false
    private var locationSubscriptionActive = false
    private var wantSilentAudio = false
    private var observersInstalled = false
    private var hasRequestedAlwaysUpgrade = false
    private var lastAuthStatus: CLAuthorizationStatus?
    /// Set when Location Services becomes denied/restricted; consumed by a real OFF→ON refresh.
    private var locationServicesWereDisabled = false
    /// Timestamp for the start of the current denied/restricted period.
    /// A sub-second flicker must not be treated as a user Location Services toggle.
    private var locationServicesDisabledAt: Date?
    private var lastForceRefreshAt: Date?
    private let forceRefreshCooldown: TimeInterval = 2.0
    /// Minimum time Location Services must stay off before a forceRestart is allowed.
    private let sustainedLocationServicesOff: TimeInterval = 1.0
    public var onDiagnostic: ((String, [String: Any]) -> Void)?

    public override init() {
        super.init()
        locationManager.delegate = self
        // Keep-alive only needs an active CL consumer so locationd stays
        // subscribed (0xFFFA). Navigation-grade accuracy wakes onboard GNSS
        // and fights a long-distance accessory fix.
        applyKeepAliveAccuracy()
        locationManager.pausesLocationUpdatesAutomatically = false
    }

    /// Starts background keep-alive (audio + background task) WITHOUT waking internal GPS yet.
    /// Call `activateLocationSubscription()` right after iAP2 authentication (0xAA05) succeeds so
    /// `locationd` sees a fresh navigation consumer while the external MFi accessory is already ready.
    public func prepareForSession(useSilentAudio: Bool) {
        isActive = true
        locationSubscriptionActive = false
        wantSilentAudio = useSilentAudio
        lastAuthStatus = locationManager.authorizationStatus
        installObserversIfNeeded()

        renewBackgroundTask()
        startWatchdog()

        if useSilentAudio {
            startResilientAudioKeepAlive()
        } else {
            stopAudioKeepAlive()
        }
        emitStatus("keepalive_prepared")
    }

    /// Activates the navigation-grade CoreLocation subscription to trigger iAP2 0xFFFA immediately.
    public func activateLocationSubscription(forceRestart: Bool = true) {
        guard isActive else { return }
        locationSubscriptionActive = true
        renewBackgroundTask()
        startBackgroundLocation(forceRestart: forceRestart)
        if wantSilentAudio {
            startResilientAudioKeepAlive()
        }
        emitStatus("keepalive_location_activated")
    }

    /// Pulses CoreLocation (stop -> brief pause -> restart + requestLocation) to nudge `locationd`
    /// into sending `0xFFFA` or re-evaluating the external MFi GPS provider automatically.
    public func pulseLocationSubscription() {
        guard isActive else { return }
        locationSubscriptionActive = true
        locationManager.stopUpdatingLocation()
        (backgroundActivitySession as? CLBackgroundActivitySession)?.invalidate()
        backgroundActivitySession = nil

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.isActive, self.locationSubscriptionActive else { return }
            self.startBackgroundLocation(forceRestart: false)
            let status = self.locationManager.authorizationStatus
            if status == .authorizedAlways || status == .authorizedWhenInUse {
                self.locationManager.requestLocation()
            }
            self.emitStatus("keepalive_location_pulsed")
        }
    }

    public func start(useSilentAudio: Bool) {
        isActive = true
        locationSubscriptionActive = true
        wantSilentAudio = useSilentAudio
        lastAuthStatus = locationManager.authorizationStatus
        installObserversIfNeeded()

        renewBackgroundTask()
        startBackgroundLocation(forceRestart: true)
        startWatchdog()

        if useSilentAudio {
            startResilientAudioKeepAlive()
        } else {
            stopAudioKeepAlive()
        }
        emitStatus("keepalive_started")
    }

    public func stop() {
        isActive = false
        locationSubscriptionActive = false
        wantSilentAudio = false
        stopWatchdog()

        locationManager.stopUpdatingLocation()
        locationManager.allowsBackgroundLocationUpdates = false

        (backgroundActivitySession as? CLBackgroundActivitySession)?.invalidate()
        backgroundActivitySession = nil

        stopAudioKeepAlive()
        endBackgroundTask()
    }

    /// Call after global Location Services is toggled OFF -> ON, because that invalidates
    /// the previous CLBackgroundActivitySession. Must not be used for a routine 0xFFFC→0xFFFA
    /// (including pulses from auto_lock_nudge), or forceRestart retriggers 0xFFFC and self-oscillates.
    public func refreshAfterLocationToggle() {
        guard isActive else { return }
        let now = Date()
        if let last = lastForceRefreshAt, now.timeIntervalSince(last) < forceRefreshCooldown {
            return
        }
        lastForceRefreshAt = now
        locationServicesWereDisabled = false
        locationServicesDisabledAt = nil
        renewBackgroundTask()
        startBackgroundLocation(forceRestart: true)
        if wantSilentAudio {
            startResilientAudioKeepAlive()
        }
        emitStatus("keepalive_refreshed")
    }

    /// A 0xFFFA arrived after a 0xFFFC. Only force-restart CoreLocation when Location Services
    /// actually returned from denied/restricted; otherwise just renew the background task.
    public func noteLocationSubscriptionResumed() {
        guard isActive, locationSubscriptionActive else { return }
        let status = locationManager.authorizationStatus
        let authorized = status == .authorizedAlways || status == .authorizedWhenInUse
        // Only rebuild the CL session after a *sustained* Location Services
        // OFF→ON (the 一鍵 refresh). A routine 0xFFFC→0xFFFA, or a sub-second
        // authorization flicker, must not forceRestart and emit keepalive_refreshed.
        if authorized, didObserveSustainedLocationServicesOff {
            refreshAfterLocationToggle()
            return
        }
        locationServicesWereDisabled = false
        locationServicesDisabledAt = nil
        renewBackgroundTask()
        emitStatus("keepalive_resume_noted")
    }

    private var didObserveSustainedLocationServicesOff: Bool {
        guard locationServicesWereDisabled, let disabledAt = locationServicesDisabledAt else {
            return false
        }
        return Date().timeIntervalSince(disabledAt) >= sustainedLocationServicesOff
    }

    private func applyKeepAliveAccuracy() {
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        locationManager.distanceFilter = kCLDistanceFilterNone
        locationManager.activityType = .other
    }

    // MARK: - Background Location Keep-Alive

    private func startBackgroundLocation(forceRestart: Bool = false) {
        let status = locationManager.authorizationStatus
        if status == .notDetermined {
            locationManager.requestAlwaysAuthorization()
        } else if status == .authorizedWhenInUse, !hasRequestedAlwaysUpgrade {
            hasRequestedAlwaysUpgrade = true
            locationManager.requestAlwaysAuthorization()
        }

        if forceRestart {
            locationManager.stopUpdatingLocation()
            (backgroundActivitySession as? CLBackgroundActivitySession)?.invalidate()
            backgroundActivitySession = nil
        }

        if backgroundActivitySession == nil {
            backgroundActivitySession = CLBackgroundActivitySession()
        }

        if status == .authorizedWhenInUse || status == .authorizedAlways {
            locationManager.allowsBackgroundLocationUpdates = true
            locationManager.pausesLocationUpdatesAutomatically = false
            locationManager.showsBackgroundLocationIndicator = true
            applyKeepAliveAccuracy()
            locationManager.startUpdatingLocation()
        }
    }

    private func emitStatus(_ event: String) {
        let statusName: String
        switch locationManager.authorizationStatus {
        case .authorizedAlways: statusName = "always"
        case .authorizedWhenInUse: statusName = "when_in_use"
        case .denied: statusName = "denied"
        case .restricted: statusName = "restricted"
        case .notDetermined: statusName = "not_determined"
        @unknown default: statusName = "unknown"
        }
        onDiagnostic?(event, [
            "auth": statusName,
            "audio_playing": audioPlayer?.isPlaying ?? false,
            "app_state": UIApplication.shared.applicationState == .background ? "background" : "foreground",
        ])
    }

    // MARK: - Resilient Low-Level Audio Keep-Alive

    private func startResilientAudioKeepAlive() {
        if let player = audioPlayer, player.isPlaying {
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            // Use a 20 Hz sub-audible PCM waveform (+/-6 LSB) with volume = 0.5 -> +/-3 LSB (~ -81 dBFS):
            // completely silent to humans and iPhone speakers, yet guaranteed non-zero after 16-bit mixing
            // so iOS mediaserverd never suspends the app even while global Location Services is toggled.
            let wavData = Self.makeInaudibleKeepAliveWAV(durationSeconds: 4, sampleRate: 8000)
            let player = try AVAudioPlayer(data: wavData)
            player.numberOfLoops = -1
            player.volume = 0.5
            player.prepareToPlay()
            player.play()
            audioPlayer = player
        } catch {
            audioPlayer = nil
        }
    }

    private func stopAudioKeepAlive() {
        audioPlayer?.stop()
        audioPlayer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Background Task & Interruption Recovery

    private func renewBackgroundTask() {
        endBackgroundTask()
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "Reloc.iAP2Session") { [weak self] in
            Task { @MainActor in
                self?.endBackgroundTask()
            }
        }
    }

    private func endBackgroundTask() {
        if backgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }
    }

    private func startWatchdog() {
        stopWatchdog()
        let timer = Timer(timeInterval: 10.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isActive else { return }
                if self.locationSubscriptionActive {
                    self.startBackgroundLocation()
                }
                if self.wantSilentAudio, !(self.audioPlayer?.isPlaying ?? false) {
                    self.startResilientAudioKeepAlive()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdogTimer = timer
    }

    private func stopWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
    }

    private func installObserversIfNeeded() {
        guard !observersInstalled else { return }
        observersInstalled = true

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMediaServicesReset),
            name: AVAudioSession.mediaServicesWereResetNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWillEnterForeground),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    @objc private func handleAudioInterruption(_ notification: Notification) {
        guard isActive, wantSilentAudio,
              let info = notification.userInfo,
              let typeRaw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
        if type == .began {
            emitStatus("audio_interrupted")
        } else if type == .ended {
            startResilientAudioKeepAlive()
            emitStatus("audio_resumed")
        }
    }

    @objc private func handleMediaServicesReset() {
        guard isActive, wantSilentAudio else { return }
        audioPlayer = nil
        startResilientAudioKeepAlive()
    }

    @objc private func handleDidEnterBackground() {
        guard isActive else { return }
        renewBackgroundTask()
        if locationSubscriptionActive {
            startBackgroundLocation()
        }
        if wantSilentAudio {
            startResilientAudioKeepAlive()
        }
        emitStatus("app_background")
    }

    @objc private func handleWillEnterForeground() {
        guard isActive else { return }
        if locationSubscriptionActive {
            startBackgroundLocation()
        }
        if wantSilentAudio, !(audioPlayer?.isPlaying ?? false) {
            startResilientAudioKeepAlive()
        }
        emitStatus("app_foreground")
    }

    // MARK: - CLLocationManagerDelegate

    public nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard self.isActive else { return }
            let newStatus = manager.authorizationStatus
            if newStatus == .denied || newStatus == .restricted {
                self.locationServicesWereDisabled = true
                if self.locationServicesDisabledAt == nil {
                    self.locationServicesDisabledAt = Date()
                }
            }
            let recovered = (self.lastAuthStatus == .denied || self.lastAuthStatus == .restricted)
                && (newStatus == .authorizedAlways || newStatus == .authorizedWhenInUse)
            self.lastAuthStatus = newStatus
            if recovered, self.didObserveSustainedLocationServicesOff {
                self.refreshAfterLocationToggle()
            } else if recovered {
                // Transient denied→authorized flicker: do not forceRestart.
                self.locationServicesWereDisabled = false
                self.locationServicesDisabledAt = nil
                if self.locationSubscriptionActive {
                    self.startBackgroundLocation(forceRestart: false)
                }
                self.emitStatus("keepalive_auth_recovered_skipped")
            } else if self.locationSubscriptionActive {
                // Do not forceRestart here — a routine auth callback must not stop CoreLocation.
                self.startBackgroundLocation(forceRestart: false)
            }
        }
    }

    public nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // Active subscription keeps Reloc alive in background and keeps locationd subscribed to iAP2 0xFFFA.
    }

    public nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Ignore transient CoreLocation errors while keep-alive runs.
    }

    private static func makeInaudibleKeepAliveWAV(durationSeconds: Int, sampleRate: UInt32) -> Data {
        let numSamples = Int(sampleRate) * max(1, durationSeconds)
        let dataSize = UInt32(numSamples * 2)
        let riffSize = UInt32(36) + dataSize
        let byteRate = sampleRate * 2

        var data = Data(capacity: 44 + Int(dataSize))
        func appendLE<T: FixedWidthInteger>(_ value: T) {
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }

        data.append(contentsOf: "RIFF".utf8)
        appendLE(riffSize)
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        appendLE(UInt32(16))
        appendLE(UInt16(1))
        appendLE(UInt16(1))
        appendLE(sampleRate)
        appendLE(byteRate)
        appendLE(UInt16(2))
        appendLE(UInt16(16))
        data.append(contentsOf: "data".utf8)
        appendLE(dataSize)

        // 20 Hz (+/-6 out of 32767) scaled by volume 0.5 -> +/-3 LSB (~ -81 dBFS):
        // completely inaudible to humans yet non-zero after integer mixing.
        for i in 0..<numSamples {
            let sample: Int16 = (i % 400 < 200) ? 6 : -6
            appendLE(sample)
        }
        return data
    }
}
