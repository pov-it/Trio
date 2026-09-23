//
//  AIInsights_LocationService.swift
//  Trio
//
//  One-shot CoreLocation fix + reverse-geocode + MapKit POI refinement.
//  Injects venue/locality context into the AI chat prompt.
//  Ported from Loop PowerPack (FoodFinder_LocationService.swift), adapted to Trio.
//

import Combine
import CoreLocation
import Foundation
import MapKit
import os.log

/// Captures venue-level location, reverse-geocodes it to a restaurant/business name,
/// and produces a prompt-injectable context snippet.
///
/// Privacy-first:
/// - Off by default. Gated by `TrioSettings.aiLocationContextEnabled`.
/// - One-shot `requestLocation()` — not continuous tracking.
/// - `kCLLocationAccuracyHundredMeters` — venue-level, not GPS-precise.
/// - Coordinates stay on-device; only a venue/city/country label reaches the AI prompt.
final class AIInsights_LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {

    static let shared = AIInsights_LocationService()

    @Published private(set) var latitude: Double?
    @Published private(set) var longitude: Double?
    @Published private(set) var locationName: String?
    @Published private(set) var cityName: String?
    @Published private(set) var countryName: String?
    @Published private(set) var isResolving: Bool = false

    private let locationManager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private let log = OSLog(subsystem: "Trio.AIInsights", category: "Location")

    /// Settings provider closure — set during boot if you want to consult `TrioSettings`.
    /// Defaults to permissive (caller still gates via `isEnabled` check before use).
    var isEnabledProvider: () -> Bool = { false }

    private var isEnabled: Bool { isEnabledProvider() }

    private override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    // MARK: - Public API

    /// Trigger a one-shot location fix if enabled and permitted. Idempotent — skips when
    /// a fresh fix already exists.
    func requestLocationIfEnabled() {
        guard isEnabled else { return }
        guard locationName == nil && cityName == nil && !isResolving else { return }

        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            beginLocationRequest()
        case .denied, .restricted:
            os_log("Location permission denied/restricted — skipping", log: log, type: .info)
        @unknown default:
            break
        }
    }

    /// Clear captured data; call on view dismiss or settings disable.
    func clearLocation() {
        latitude = nil
        longitude = nil
        locationName = nil
        cityName = nil
        countryName = nil
        isResolving = false
    }

    /// Prompt-injectable context snippet. Empty when feature off or no data.
    func locationContextForPrompt() -> String {
        guard isEnabled else { return "" }

        var regionParts: [String] = []
        if let city = cityName, !city.isEmpty { regionParts.append(city) }
        if let country = countryName, !country.isEmpty { regionParts.append(country) }
        let region = regionParts.isEmpty ? nil : regionParts.joined(separator: ", ")
        let venueName = (locationName?.isEmpty == false) ? locationName : nil

        guard venueName != nil || region != nil else { return "" }

        var ctx = "## Location Context\n"
        if let venue = venueName, let reg = region {
            ctx += "User's device GPS places them at or near \"\(venue)\" in \(reg).\n"
        } else if let venue = venueName {
            ctx += "User's device GPS places them at or near \"\(venue)\".\n"
        } else if let reg = region {
            ctx += "User's device GPS places them in \(reg).\n"
        }
        ctx += "Use regional context where relevant (local meals, typical eating hours, climate effects on insulin sensitivity). Do not surface raw coordinates to the user.\n"
        return ctx
    }

    // MARK: - Internals

    private func beginLocationRequest() {
        isResolving = true
        locationManager.requestLocation()
    }

    private func reverseGeocode(_ location: CLLocation) {
        geocoder.reverseGeocodeLocation(location) { [weak self] placemarks, error in
            guard let self else { return }
            DispatchQueue.main.async {
                if let error {
                    os_log("Reverse geocode failed: %{public}@", log: self.log, type: .error, error.localizedDescription)
                    self.isResolving = false
                    return
                }

                if let placemark = placemarks?.first {
                    var name = placemark.name ?? placemark.areasOfInterest?.first

                    if let n = name, let street = placemark.thoroughfare, n == street {
                        name = nil
                    }
                    if let n = name, let street = placemark.thoroughfare,
                       n.hasPrefix(street) || n.hasSuffix(street) {
                        name = nil
                    }

                    self.locationName = name
                    self.cityName = placemark.locality
                    self.countryName = placemark.country
                }

                self.searchNearbyFoodVenues(location)
            }
        }
    }

    private func searchNearbyFoodVenues(_ location: CLLocation) {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = "restaurant"
        request.region = MKCoordinateRegion(
            center: location.coordinate,
            latitudinalMeters: 100,
            longitudinalMeters: 100
        )
        request.resultTypes = .pointOfInterest

        MKLocalSearch(request: request).start { [weak self] response, _ in
            guard let self else { return }
            DispatchQueue.main.async {
                defer { self.isResolving = false }
                guard let items = response?.mapItems, !items.isEmpty else { return }

                let closest = items
                    .compactMap { item -> (name: String, distance: CLLocationDistance)? in
                        guard let name = item.name, !name.isEmpty else { return nil }
                        let itemLoc = CLLocation(
                            latitude: item.placemark.coordinate.latitude,
                            longitude: item.placemark.coordinate.longitude
                        )
                        return (name, location.distance(from: itemLoc))
                    }
                    .sorted { $0.distance < $1.distance }
                    .first

                if let match = closest, self.locationName != match.name {
                    self.locationName = match.name
                }
            }
        }
    }

    // MARK: - CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.first else { return }
        latitude = location.coordinate.latitude
        longitude = location.coordinate.longitude
        reverseGeocode(location)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        os_log("Location request failed: %{public}@", log: log, type: .error, error.localizedDescription)
        isResolving = false
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedWhenInUse
            || manager.authorizationStatus == .authorizedAlways {
            beginLocationRequest()
        }
    }
}
