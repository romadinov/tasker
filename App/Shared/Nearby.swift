import CoreLocation
import MapKit
import Observation
import SwiftUI
import TaskerCore
import UserNotifications

/// Works out which location tags apply where you are.
/// - Specific places: distance from you ≤ the tag's radius.
/// - Kinds of place ("shopping centre", "Woolworths", store / food market categories): Apple Maps
///   is searched around you; you're "there" when the nearest match is within the radius.
///   This is OmniFocus's search-term location, which "becomes the nearest search result".
@MainActor @Observable
final class NearbyModel: NSObject, CLLocationManagerDelegate {
    static let shared = NearbyModel()

    struct Match: Identifiable, Hashable {
        let id: String
        let name: String
        let coordinate: CLLocationCoordinate2D
        let distance: CLLocationDistance
        static func == (a: Match, b: Match) -> Bool { a.id == b.id }
        func hash(into h: inout Hasher) { h.combine(id) }
    }

    @ObservationIgnored private let manager = CLLocationManager()
    private(set) var authorization: CLAuthorizationStatus = .notDetermined
    private(set) var location: CLLocation?
    /// Tags whose location applies right now.
    private(set) var hereTagIDs: Set<String> = []
    /// Nearest matches per kind-of-place tag (for the map and distances).
    private(set) var matches: [String: [Match]] = [:]
    private(set) var lastError: String?
    private(set) var isSearching = false

    @ObservationIgnored private var lastLookup: [String: (CLLocation, Date, String)] = [:]
    @ObservationIgnored private var started = false

    override private init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 50
        authorization = manager.authorizationStatus
    }

    var hasAccess: Bool {
        #if os(macOS)
        authorization == .authorizedAlways || authorization == .authorized
        #else
        authorization == .authorizedWhenInUse || authorization == .authorizedAlways
        #endif
    }

    /// Location tags exist → start tracking (asks for permission the first time).
    func startIfNeeded() {
        let tags = AppModel.shared.snapshot.tags.values.filter { $0.location != nil }
        guard !tags.isEmpty else { return }
        if authorization == .notDetermined {
            #if os(iOS)
            manager.requestAlwaysAuthorization()
            #else
            manager.requestWhenInUseAuthorization()
            #endif
        }
        guard hasAccess, !started else { return }
        started = true
        manager.startUpdatingLocation()
        #if os(iOS)
        if authorization == .authorizedAlways {
            // Wakes the app when you move ~500 m, so arriving at a shop can notify you.
            manager.startMonitoringSignificantLocationChanges()
        }
        #endif
        registerRegions()
    }

    func requestAccess() {
        #if os(iOS)
        manager.requestAlwaysAuthorization()
        #else
        manager.requestWhenInUseAuthorization()
        #endif
    }

    // MARK: CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorization = status
            self.started = false
            self.startIfNeeded()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in
            self.location = loc
            await self.refresh()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let msg = error.localizedDescription
        Task { @MainActor in self.lastError = msg }
    }

    #if os(iOS)
    nonisolated func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        let id = region.identifier
        Task { @MainActor in self.regionEvent(tagID: id, arriving: true) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        let id = region.identifier
        Task { @MainActor in self.regionEvent(tagID: id, arriving: false) }
    }
    #endif

    // MARK: Matching

    func refresh(force: Bool = false) async {
        guard let here = location else { return }
        let snapshot = AppModel.shared.snapshot
        var now = Set<String>()
        for tag in snapshot.tags.values {
            guard let loc = tag.location, tag.status != .dropped else { continue }
            switch loc.kind {
            case .place:
                guard let lat = loc.latitude, let lon = loc.longitude else { continue }
                if here.distance(from: CLLocation(latitude: lat, longitude: lon)) <= loc.radius { now.insert(tag.id) }
            case .kind:
                let found = await nearest(for: tag, loc, around: here, force: force)
                matches[tag.id] = found
                if let first = found.first, first.distance <= loc.radius { now.insert(tag.id) }
            }
        }
        let arrived = now.subtracting(hereTagIDs), left = hereTagIDs.subtracting(now)
        hereTagIDs = now
        for id in arrived { notifyIfWanted(tagID: id, arriving: true) }
        for id in left { notifyIfWanted(tagID: id, arriving: false) }
        registerRegions()
    }

    /// Searches Apple Maps near you. Re-uses the last answer unless you've moved ~150 m, five
    /// minutes passed, or the search changed (MapKit throttles frequent requests).
    private func nearest(for tag: Tag, _ loc: TagLocation, around here: CLLocation, force: Bool) async -> [Match] {
        let signature = "\(loc.query ?? "")|\(loc.categories.joined(separator: ","))"
        if !force, let last = lastLookup[tag.id], last.2 == signature,
           here.distance(from: last.0) < 150, Date().timeIntervalSince(last.1) < 300 {
            return (matches[tag.id] ?? []).map { m in
                Match(id: m.id, name: m.name, coordinate: m.coordinate,
                      distance: here.distance(from: CLLocation(latitude: m.coordinate.latitude, longitude: m.coordinate.longitude)))
            }.sorted { $0.distance < $1.distance }
        }
        isSearching = true
        defer { isSearching = false }
        var items: [MKMapItem] = []
        let searchRadius = max(loc.radius * 4, 2000)
        let cats = loc.categories.map { MKPointOfInterestCategory(rawValue: $0) }
        if let q = loc.query?.trimmingCharacters(in: .whitespaces), !q.isEmpty {
            let req = MKLocalSearch.Request()
            req.naturalLanguageQuery = q
            req.region = MKCoordinateRegion(center: here.coordinate, latitudinalMeters: searchRadius * 2, longitudinalMeters: searchRadius * 2)
            req.resultTypes = .pointOfInterest
            if !cats.isEmpty { req.pointOfInterestFilter = MKPointOfInterestFilter(including: cats) }
            items = (try? await MKLocalSearch(request: req).start().mapItems) ?? []
        } else if !cats.isEmpty {
            let req = MKLocalPointsOfInterestRequest(center: here.coordinate, radius: min(searchRadius, 3000))
            req.pointOfInterestFilter = MKPointOfInterestFilter(including: cats)
            items = (try? await MKLocalSearch(request: req).start().mapItems) ?? []
        }
        lastLookup[tag.id] = (here, Date(), signature)
        return items.compactMap { item -> Match? in
            let c = item.placemark.coordinate
            let d = here.distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude))
            return Match(id: "\(item.name ?? "")@\(c.latitude),\(c.longitude)", name: item.name ?? loc.name, coordinate: c, distance: d)
        }
        .sorted { $0.distance < $1.distance }
        .prefix(10).map { $0 }
    }

    /// Distance from you to a tag's location (nearest match for kinds of place).
    func distance(to tag: Tag) -> CLLocationDistance? {
        guard let here = location, let loc = tag.location else { return nil }
        switch loc.kind {
        case .place:
            guard let lat = loc.latitude, let lon = loc.longitude else { return nil }
            return here.distance(from: CLLocation(latitude: lat, longitude: lon))
        case .kind:
            return matches[tag.id]?.first?.distance
        }
    }

    /// One-off search used by the tag inspector's "Test" button.
    func test(_ loc: TagLocation) async -> Match? {
        guard let here = location ?? manager.location else { return nil }
        var t = Tag(id: "test-\(UUID().uuidString)")
        t.location = loc
        return await nearest(for: t, loc, around: here, force: true).first
    }

    // MARK: Notifications (iOS region monitoring + in-app arrival/leaving)

    private func registerRegions() {
        #if os(iOS)
        guard authorization == .authorizedAlways, CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else { return }
        let snapshot = AppModel.shared.snapshot
        var wanted: [String: CLCircularRegion] = [:]
        for tag in snapshot.tags.values {
            guard let loc = tag.location, loc.trigger != .none else { continue }
            var center: CLLocationCoordinate2D?
            if loc.kind == .place, let lat = loc.latitude, let lon = loc.longitude { center = .init(latitude: lat, longitude: lon) }
            else if loc.kind == .kind { center = matches[tag.id]?.first?.coordinate } // nearest match, refreshed as you move
            guard let c = center else { continue }
            let r = CLCircularRegion(center: c, radius: min(max(loc.radius, 100), manager.maximumRegionMonitoringDistance), identifier: tag.id)
            r.notifyOnEntry = loc.trigger == .arriving
            r.notifyOnExit = loc.trigger == .leaving
            wanted[tag.id] = r
        }
        for region in manager.monitoredRegions where wanted[region.identifier] == nil { manager.stopMonitoring(for: region) }
        for (_, r) in wanted.prefix(20) { manager.startMonitoring(for: r) } // iOS limit: 20 regions
        #endif
    }

    private func regionEvent(tagID: String, arriving: Bool) {
        if arriving { hereTagIDs.insert(tagID) } else { hereTagIDs.remove(tagID) }
        notifyIfWanted(tagID: tagID, arriving: arriving)
    }

    @ObservationIgnored private var lastNotified: [String: Date] = [:]

    private func notifyIfWanted(tagID: String, arriving: Bool) {
        let s = AppModel.shared.snapshot
        guard let tag = s.tags[tagID], let loc = tag.location else { return }
        guard (arriving && loc.trigger == .arriving) || (!arriving && loc.trigger == .leaving) else { return }
        if let last = lastNotified[tagID], Date().timeIntervalSince(last) < 1800 { return } // no repeat within 30 min
        let items = (s.tasksByTag[tagID] ?? []).compactMap { s.tasks[$0] }.filter { s.info[$0.id]?.isAvailable == true }
        guard !items.isEmpty else { return }
        lastNotified[tagID] = Date()
        let place = loc.kind == .kind ? (matches[tagID]?.first?.name ?? loc.name) : loc.name
        let content = UNMutableNotificationContent()
        content.title = arriving ? "At \(place)" : "Leaving \(place)"
        content.body = items.prefix(4).map(\.title).joined(separator: "\n") + (items.count > 4 ? "\n+\(items.count - 4) more" : "")
        content.subtitle = "\(items.count) \(tag.name) action\(items.count == 1 ? "" : "s")"
        content.sound = .default
        let req = UNNotificationRequest(identifier: "nearby-\(tagID)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    static func requestNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }
}

extension CLLocationDistance {
    var friendly: String {
        let f = MKDistanceFormatter()
        f.unitStyle = .abbreviated
        return f.string(fromDistance: self)
    }
}
