import Foundation

/// Where a tag "is":
/// - `.place`: a specific spot (searched business, address, dropped pin or "here").
/// - `.kind`: a kind of place, matched against Apple Maps around you ("shopping centre",
///   "Woolworths", or point-of-interest categories such as store / foodMarket). Like a
///   search-term locations, it becomes the nearest match for wherever you are.
public struct TagLocation: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case place, kind }
    public enum Trigger: String, Codable, Sendable, CaseIterable { case none, arriving, leaving }

    public var kind: Kind
    public var name: String
    public var latitude: Double?
    public var longitude: Double?
    public var address: String?
    /// Search phrase for `.kind` locations ("supermarket", "Westfield").
    public var query: String?
    /// MKPointOfInterestCategory raw values for `.kind` locations.
    public var categories: [String]
    /// Metres. Presets: small 200, medium 500, large 10 000.
    public var radius: Double
    public var trigger: Trigger

    public init(kind: Kind, name: String, latitude: Double? = nil, longitude: Double? = nil, address: String? = nil,
                query: String? = nil, categories: [String] = [], radius: Double = 200, trigger: Trigger = .none) {
        self.kind = kind; self.name = name; self.latitude = latitude; self.longitude = longitude; self.address = address
        self.query = query; self.categories = categories; self.radius = radius; self.trigger = trigger
    }

    enum CodingKeys: String, CodingKey { case kind, name, latitude, longitude, address, query, categories, radius, trigger }
    public init(from decoder: Decoder) throws {
        let k = try decoder.container(keyedBy: CodingKeys.self)
        kind = try k.decodeIfPresent(Kind.self, forKey: .kind) ?? .place
        name = try k.decodeIfPresent(String.self, forKey: .name) ?? ""
        latitude = try k.decodeIfPresent(Double.self, forKey: .latitude)
        longitude = try k.decodeIfPresent(Double.self, forKey: .longitude)
        address = try k.decodeIfPresent(String.self, forKey: .address)
        query = try k.decodeIfPresent(String.self, forKey: .query)
        categories = try k.decodeIfPresent([String].self, forKey: .categories) ?? []
        radius = try k.decodeIfPresent(Double.self, forKey: .radius) ?? 200
        trigger = try k.decodeIfPresent(Trigger.self, forKey: .trigger) ?? .none
    }

    public static let small = 200.0, medium = 500.0, large = 10_000.0

    public var radiusLabel: String {
        switch radius {
        case ..<300: "Small (~200 m)"
        case ..<1000: "Medium (~500 m)"
        default: "Large (~10 km)"
        }
    }
}
