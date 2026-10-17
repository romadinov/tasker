import CoreLocation
import MapKit
import SwiftUI
import TaskerCore

/// Nearby perspective: map + actions whose tags have a location, nearest first ("Here" on top).
struct NearbyView: View {
    @Environment(AppModel.self) private var model
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    @State private var nearby = NearbyModel.shared
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)

    var locationTags: [Tag] { model.snapshot.tags.values.filter { $0.location != nil && $0.status != .dropped } }

    var body: some View {
        @Bindable var model = model
        let s = model.snapshot
        let tags = locationTags.sorted { (nearby.distance(to: $0) ?? .infinity, $0.name) < (nearby.distance(to: $1) ?? .infinity, $1.name) }
        VStack(spacing: 0) {
            map(tags)
                .frame(minHeight: 220, idealHeight: 320, maxHeight: 360)
            List(selection: $model.selection) {
                if !compact {
                    PerspectiveHeader(sections: [OutlineSection(id: "n", title: "", rows: model.flat(tags.flatMap(items(for:))))])
                        .listRowSeparator(.hidden).selectionDisabled()
                }
                if tags.isEmpty {
                    Text("No tags have a location yet. In Tags, select a tag and set its Location — a specific place, or a kind of place such as “shopping centre” or “supermarket”.")
                        .foregroundStyle(.secondary).selectionDisabled()
                } else if !nearby.hasAccess {
                    Button("Allow Location Access…") { nearby.requestAccess() }.selectionDisabled()
                }
                let here = tags.filter { nearby.hereTagIDs.contains($0.id) }
                if !here.isEmpty {
                    Section {
                        ForEach(here) { tag in
                            HStack {
                                Image(systemName: "tag.fill").foregroundStyle(Palette.tag)
                                Text(tag.name).font(.subheadline.weight(.semibold))
                                if let place = placeName(tag) { Text("at \(place)").font(.subheadline).foregroundStyle(.secondary) }
                                Spacer()
                                if items(for: tag).isEmpty { Text("nothing available").font(.caption).foregroundStyle(.secondary) }
                            }
                            .selectionDisabled()
                            rows(for: tag)
                        }
                    } header: {
                        Label("Here now", systemImage: "location.fill").foregroundStyle(.green)
                    }
                }
                ForEach(tags.filter { !nearby.hereTagIDs.contains($0.id) }) { tag in
                    let ids = items(for: tag)
                    if !ids.isEmpty {
                        Section {
                            rows(for: tag)
                        } header: {
                            HStack {
                                Text(tag.name)
                                if let place = placeName(tag) { Text("· \(place)").foregroundStyle(.secondary) }
                                Spacer()
                                if let d = nearby.distance(to: tag) { Text(d.friendly).monospacedDigit().foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
            }
            #if os(macOS)
            .listStyle(.inset)
            #else
            .listStyle(.plain)
            #endif
            .contextMenu(forSelectionType: String.self) { ids in ItemContextMenu(ids: Array(ids)) }
        }
        .onAppear {
            nearby.startIfNeeded()
            Task { await nearby.refresh(force: true) }
        }
        .navigationTitle("Nearby")
    }

    var compact: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
    }

    func items(for tag: Tag) -> [String] {
        let s = model.snapshot
        return PerspectiveEngine(s).sort((s.tasksByTag[tag.id] ?? []).filter { s.info[$0]?.isAvailable == true && s.tasks[$0]?.isProject == false }, by: .manual)
    }

    @ViewBuilder
    func rows(for tag: Tag) -> some View {
        ForEach(model.flat(items(for: tag))) { row in TaskRow(row: row).tag(row.id) }
    }

    func placeName(_ tag: Tag) -> String? {
        guard let loc = tag.location else { return nil }
        if loc.kind == .kind { return nearby.matches[tag.id]?.first?.name ?? loc.query }
        return loc.name.isEmpty ? loc.address : loc.name
    }

    func map(_ tags: [Tag]) -> some View {
        Map(position: $camera) {
            UserAnnotation()
            ForEach(tags) { tag in
                if let loc = tag.location {
                    if loc.kind == .place, let lat = loc.latitude, let lon = loc.longitude {
                        let c = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                        Marker(tag.name, systemImage: "tag.fill", coordinate: c)
                            .tint(nearby.hereTagIDs.contains(tag.id) ? .green : .purple)
                        MapCircle(center: c, radius: loc.radius)
                            .foregroundStyle(.purple.opacity(0.12))
                            .stroke(.purple.opacity(0.5), lineWidth: 1)
                    } else {
                        ForEach(nearby.matches[tag.id]?.prefix(5).map { $0 } ?? []) { m in
                            Marker("\(tag.name): \(m.name)", systemImage: "cart.fill", coordinate: m.coordinate)
                                .tint(nearby.hereTagIDs.contains(tag.id) && m.id == nearby.matches[tag.id]?.first?.id ? .green : .orange)
                        }
                    }
                }
            }
        }
        .mapControls {
            MapUserLocationButton()
            MapCompass()
            MapScaleView()
        }
    }
}

// MARK: - Tag inspector with Location

struct TagInspector: View {
    @Environment(AppModel.self) private var model
    let id: String

    var body: some View {
        if let tag = model.snapshot.tags[id] {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Well {
                        CommitField(label: "Tag name", value: tag.name) { v in model.perform("Rename Tag") { $0.set(.tag, id, F.name, .string(v)) } }
                            .textFieldStyle(.plain)
                    }
                    .padding(.bottom, 8)
                    InspectorSection(title: "Status", trailing: tag.status.label) {
                        IconSegments(options: [(TagStatus.active, "play.circle", "Active"), (.onHold, "pause.circle", "On Hold"), (.dropped, "minus.circle", "Dropped")],
                                     selection: tag.status) { v in model.perform("Tag Status") { $0.setTagStatus(id, v) } }
                    }
                    InspectorSection(title: "Location", trailing: tag.location.map { $0.kind == .kind ? "Kind of place" : "Specific place" } ?? "None") {
                        TagLocationEditor(tag: tag)
                    }
                }
                .padding(14)
            }
        }
    }
}

struct TagLocationEditor: View {
    @Environment(AppModel.self) private var model
    let tag: Tag
    @State private var nearby = NearbyModel.shared
    @State private var completer = PlaceSearch()
    @State private var testResult: String?
    @State private var queryText = ""

    static let categories: [(MKPointOfInterestCategory, String, String)] = [
        (.store, "Shops", "bag"), (.foodMarket, "Supermarkets", "cart"), (.pharmacy, "Pharmacies", "cross.case"),
        (.bakery, "Bakeries", "birthday.cake"), (.gasStation, "Petrol", "fuelpump"), (.bank, "Banks", "building.columns"),
        (.atm, "ATMs", "banknote"), (.postOffice, "Post", "envelope"), (.library, "Libraries", "books.vertical"),
        (.cafe, "Cafés", "cup.and.saucer"), (.fitnessCenter, "Gyms", "dumbbell"), (.hospital, "Hospitals", "cross"),
    ]

    var body: some View {
        let loc = tag.location
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: Binding(get: { loc?.kind.rawValue ?? "none" }, set: { k in
                switch k {
                case "place": save(TagLocation(kind: .place, name: "", radius: TagLocation.small))
                case "kind": save(TagLocation(kind: .kind, name: tag.name, query: tag.name, radius: 300))
                default: save(nil)
                }
            })) {
                Text("None").tag("none"); Text("Specific place").tag("place"); Text("Kind of place").tag("kind")
            }
            .pickerStyle(.segmented).labelsHidden()

            if let loc {
                if loc.kind == .place { placeEditor(loc) } else { kindEditor(loc) }

                Picker("Range", selection: Binding(get: { loc.radius < 300 ? TagLocation.small : (loc.radius < 1000 ? TagLocation.medium : TagLocation.large) },
                                                   set: { r in var l = loc; l.radius = loc.kind == .kind && r == TagLocation.small ? 300 : r; save(l) })) {
                    Text("Small · block").tag(TagLocation.small)
                    Text("Medium · neighbourhood").tag(TagLocation.medium)
                    Text("Large · city").tag(TagLocation.large)
                }
                Picker("Notify", selection: Binding(get: { loc.trigger }, set: { t in
                    var l = loc; l.trigger = t; save(l)
                    if t != .none { NearbyModel.requestNotifications() }
                })) {
                    Text("Never").tag(TagLocation.Trigger.none)
                    Text("When arriving").tag(TagLocation.Trigger.arriving)
                    Text("When leaving").tag(TagLocation.Trigger.leaving)
                }
                #if os(macOS)
                Text("Notifications are delivered on iPhone and iPad; the Mac shows Nearby items.").font(.caption).foregroundStyle(.secondary)
                #endif
            }
        }
        .onAppear { queryText = loc?.query ?? "" }
    }

    @ViewBuilder
    func placeEditor(_ loc: TagLocation) -> some View {
        if let lat = loc.latitude, let lon = loc.longitude {
            let c = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            VStack(alignment: .leading, spacing: 4) {
                Text(loc.name.isEmpty ? "Pinned location" : loc.name).font(.body.weight(.medium))
                if let a = loc.address { Text(a).font(.caption).foregroundStyle(.secondary) }
            }
            MapReader { proxy in
                Map(initialPosition: .region(MKCoordinateRegion(center: c, latitudinalMeters: max(loc.radius * 4, 800), longitudinalMeters: max(loc.radius * 4, 800)))) {
                    Marker(tag.name, coordinate: c)
                    MapCircle(center: c, radius: loc.radius).foregroundStyle(.purple.opacity(0.15)).stroke(.purple, lineWidth: 1)
                }
                .onTapGesture { p in
                    // Tap the map to move the pin.
                    if let coord = proxy.convert(p, from: .local) {
                        var l = loc; l.latitude = coord.latitude; l.longitude = coord.longitude; l.name = "Dropped pin"; l.address = nil
                        save(l)
                    }
                }
            }
            .frame(height: 180)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            Text("Tap the map to move the pin.").font(.caption).foregroundStyle(.secondary)
        }
        TextField("Search places or addresses", text: $completer.query, prompt: Text("Search a shop, address or place"))
            .textFieldStyle(.roundedBorder)
        if !completer.results.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(completer.results.prefix(6), id: \.self) { r in
                    Button {
                        Task {
                            if let item = await completer.resolve(r) {
                                let c = item.placemark.coordinate
                                var l = loc
                                l.name = item.name ?? r.title; l.latitude = c.latitude; l.longitude = c.longitude
                                l.address = item.placemark.title
                                save(l)
                                completer.query = ""
                            }
                        }
                    } label: {
                        VStack(alignment: .leading) {
                            Text(r.title)
                            if !r.subtitle.isEmpty { Text(r.subtitle).font(.caption).foregroundStyle(.secondary) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        Button {
            nearby.requestAccess()
            Task {
                guard let here = nearby.location else { return }
                var l = loc
                l.latitude = here.coordinate.latitude; l.longitude = here.coordinate.longitude
                let placemark = try? await CLGeocoder().reverseGeocodeLocation(here).first
                l.name = placemark?.name ?? "Current location"
                l.address = [placemark?.thoroughfare, placemark?.locality].compactMap { $0 }.joined(separator: ", ")
                save(l)
            }
        } label: { Label("Use Current Location", systemImage: "location") }
        .disabled(nearby.location == nil && nearby.hasAccess)
    }

    @ViewBuilder
    func kindEditor(_ loc: TagLocation) -> some View {
        Text("Matches the nearest place on Apple Maps wherever you are — e.g. “shopping centre”, “Woolworths”, “Bunnings” — and/or categories.")
            .font(.caption).foregroundStyle(.secondary)
        TextField("Search term", text: $queryText, prompt: Text("e.g. shopping centre, Woolworths"))
            .textFieldStyle(.roundedBorder)
            .onSubmit { var l = loc; l.query = queryText; l.name = queryText.isEmpty ? tag.name : queryText; save(l) }
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(Self.categories, id: \.0.rawValue) { cat, label, icon in
                let on = loc.categories.contains(cat.rawValue)
                Button {
                    var l = loc
                    if on { l.categories.removeAll { $0 == cat.rawValue } } else { l.categories.append(cat.rawValue) }
                    save(l)
                } label: {
                    Label(label, systemImage: icon).font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 6).fill(on ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.08)))
                }
                .buttonStyle(.plain)
            }
        }
        HStack {
            Button("Test Here") {
                var l = loc; l.query = queryText
                testResult = "Searching…"
                Task {
                    nearby.startIfNeeded()
                    if let m = await nearby.test(l) {
                        testResult = "Nearest: \(m.name) — \(m.distance.friendly)" + (m.distance <= l.radius ? " (you're there)" : "")
                    } else {
                        testResult = nearby.hasAccess ? "No match nearby" : "Allow location access to test"
                    }
                }
            }
            if let testResult { Text(testResult).font(.caption).foregroundStyle(.secondary) }
        }
    }

    func save(_ l: TagLocation?) {
        model.perform("Tag Location") { $0.set(.tag, tag.id, F.location, l.map { JSON(encoding: $0) } ?? .null) }
        NearbyModel.shared.startIfNeeded()
        Task { await NearbyModel.shared.refresh(force: true) }
    }
}

/// MKLocalSearchCompleter wrapper for the place search field.
@MainActor @Observable
final class PlaceSearch: NSObject, MKLocalSearchCompleterDelegate {
    @ObservationIgnored private let completer = MKLocalSearchCompleter()
    var results: [MKLocalSearchCompletion] = []
    var query = "" {
        didSet {
            if query.isEmpty { results = [] } else { completer.queryFragment = query }
        }
    }

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.pointOfInterest, .address]
        if let here = NearbyModel.shared.location {
            completer.region = MKCoordinateRegion(center: here.coordinate, latitudinalMeters: 50_000, longitudinalMeters: 50_000)
        }
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let r = completer.results
        Task { @MainActor in self.results = r }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {}

    func resolve(_ completion: MKLocalSearchCompletion) async -> MKMapItem? {
        try? await MKLocalSearch(request: MKLocalSearch.Request(completion: completion)).start().mapItems.first
    }
}
