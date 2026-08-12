//
//  LocationProvider.swift
//  samplewebview
//
//  CoreLocation wrapper with an async API. Requests "when in use"
//  authorization lazily, only when the web content actually asks for a fix.
//

import CoreLocation
import Foundation

/// Errors mapped onto the W3C `GeolocationPositionError` codes so they can be
/// handed straight back to `navigator.geolocation` callbacks.
enum GeolocationError: Error {
    case permissionDenied
    case positionUnavailable(String)
    case timeout

    /// 1 = PERMISSION_DENIED, 2 = POSITION_UNAVAILABLE, 3 = TIMEOUT
    var code: Int {
        switch self {
        case .permissionDenied: return 1
        case .positionUnavailable: return 2
        case .timeout: return 3
        }
    }

    var message: String {
        switch self {
        case .permissionDenied:
            return "Location permission was denied."
        case .positionUnavailable(let reason):
            return reason
        case .timeout:
            return "Timed out while acquiring a location."
        }
    }
}

@MainActor
final class LocationProvider: NSObject {

    private let manager = CLLocationManager()

    private var authorizationRequests: [CheckedContinuation<CLAuthorizationStatus, Never>] = []
    private var pendingFixes: [UUID: CheckedContinuation<CLLocation, Error>] = [:]
    private var timeoutTasks: [UUID: Task<Void, Never>] = [:]
    private var observers: [UUID: (Result<CLLocation, Error>) -> Void] = [:]
    private var highAccuracyRequests = 0
    private var isUpdating = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    var authorizationStatus: CLAuthorizationStatus {
        manager.authorizationStatus
    }

    var isDenied: Bool {
        let status = manager.authorizationStatus
        return status == .denied || status == .restricted
    }

    // MARK: - Authorization

    /// Prompts for permission when the status is still undetermined, then
    /// throws if the app is not allowed to read location.
    func ensureAuthorization() async throws {
        if manager.authorizationStatus == .notDetermined {
            _ = await requestAuthorization()
        }

        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            return
        case .denied, .restricted, .notDetermined:
            throw GeolocationError.permissionDenied
        @unknown default:
            throw GeolocationError.permissionDenied
        }
    }

    private func requestAuthorization() async -> CLAuthorizationStatus {
        await withCheckedContinuation { continuation in
            authorizationRequests.append(continuation)
            manager.requestWhenInUseAuthorization()
        }
    }

    // MARK: - One-shot fix

    /// Equivalent of `navigator.geolocation.getCurrentPosition`.
    func requestLocation(
        highAccuracy: Bool,
        maximumAge: TimeInterval,
        timeout: TimeInterval?
    ) async throws -> CLLocation {
        try await ensureAuthorization()

        if maximumAge > 0,
           let cached = manager.location,
           Date().timeIntervalSince(cached.timestamp) <= maximumAge {
            return cached
        }

        let id = UUID()
        if highAccuracy { highAccuracyRequests += 1 }

        return try await withCheckedThrowingContinuation { continuation in
            pendingFixes[id] = continuation

            if let timeout, timeout.isFinite, timeout > 0 {
                timeoutTasks[id] = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(timeout))
                    guard !Task.isCancelled else { return }
                    self?.fail(fix: id, with: GeolocationError.timeout)
                }
            }

            applyAccuracy()
            startUpdatesIfNeeded()
        }
    }

    // MARK: - Continuous updates

    /// Equivalent of `navigator.geolocation.watchPosition`. Authorization is
    /// resolved before the first callback is delivered.
    func addObserver(
        highAccuracy: Bool,
        onUpdate: @escaping (Result<CLLocation, Error>) -> Void
    ) -> UUID {
        let id = UUID()
        observers[id] = onUpdate
        if highAccuracy { highAccuracyRequests += 1 }
        applyAccuracy()

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.ensureAuthorization()
                guard self.observers[id] != nil else { return }
                self.startUpdatesIfNeeded()
                if let last = self.manager.location {
                    onUpdate(.success(last))
                }
            } catch {
                guard self.observers[id] != nil else { return }
                onUpdate(.failure(error))
            }
        }

        return id
    }

    func removeObserver(_ id: UUID, highAccuracy: Bool) {
        guard observers.removeValue(forKey: id) != nil else { return }
        if highAccuracy { highAccuracyRequests = max(0, highAccuracyRequests - 1) }
        applyAccuracy()
        stopUpdatesIfIdle()
    }

    // MARK: - Private

    private func applyAccuracy() {
        manager.desiredAccuracy = highAccuracyRequests > 0
            ? kCLLocationAccuracyBest
            : kCLLocationAccuracyHundredMeters
    }

    private func startUpdatesIfNeeded() {
        guard !isUpdating, !pendingFixes.isEmpty || !observers.isEmpty else { return }
        isUpdating = true
        manager.startUpdatingLocation()
    }

    private func stopUpdatesIfIdle() {
        guard isUpdating, pendingFixes.isEmpty, observers.isEmpty else { return }
        isUpdating = false
        manager.stopUpdatingLocation()
    }

    private func fail(fix id: UUID, with error: Error) {
        timeoutTasks.removeValue(forKey: id)?.cancel()
        guard let continuation = pendingFixes.removeValue(forKey: id) else { return }
        continuation.resume(throwing: error)
        stopUpdatesIfIdle()
    }

    private func deliver(_ location: CLLocation) {
        let fixes = pendingFixes
        pendingFixes.removeAll()
        for (id, continuation) in fixes {
            timeoutTasks.removeValue(forKey: id)?.cancel()
            continuation.resume(returning: location)
        }

        for observer in observers.values {
            observer(.success(location))
        }

        stopUpdatesIfIdle()
    }

    private func deliver(_ error: Error) {
        let fixes = pendingFixes
        pendingFixes.removeAll()
        for (id, continuation) in fixes {
            timeoutTasks.removeValue(forKey: id)?.cancel()
            continuation.resume(throwing: error)
        }

        for observer in observers.values {
            observer(.failure(error))
        }

        stopUpdatesIfIdle()
    }
}

// MARK: - CLLocationManagerDelegate

extension LocationProvider: CLLocationManagerDelegate {

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus

        // Fires once when the delegate is set; only resume on a real answer.
        guard status != .notDetermined else { return }

        let requests = authorizationRequests
        authorizationRequests.removeAll()
        for continuation in requests {
            continuation.resume(returning: status)
        }

        if status == .denied || status == .restricted {
            deliver(GeolocationError.permissionDenied)
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        deliver(latest)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let clError = error as? CLError

        // `.locationUnknown` is transient: CoreLocation keeps trying.
        if clError?.code == .locationUnknown { return }

        if clError?.code == .denied {
            deliver(GeolocationError.permissionDenied)
        } else {
            deliver(GeolocationError.positionUnavailable(error.localizedDescription))
        }
    }
}
