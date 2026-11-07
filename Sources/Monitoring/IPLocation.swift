import Foundation
import CoreLocation

/// Geolocation of a public IP (ipapi.co, HTTPS, no key). Cached per host for the app lifetime.
struct IPLocation: Sendable {
    let ip: String, city: String, region: String, country: String, countryCode: String, org: String
    let coordinate: CLLocationCoordinate2D

    var flag: String {
        countryCode.uppercased().unicodeScalars.compactMap { UnicodeScalar(127397 + $0.value).map(String.init) }.joined()
    }

    private static let cache = Cache()
    private actor Cache {
        var values: [String: IPLocation] = [:]
        func get(_ k: String) -> IPLocation? { values[k] }
        func set(_ k: String, _ v: IPLocation) { values[k] = v }
    }

    static func lookup(host: String) async -> IPLocation? {
        if let hit = await cache.get(host) { return hit }
        guard let url = URL(string: "https://ipapi.co/\(host)/json/") else { return nil }
        var request = URLRequest(url: url); request.timeoutInterval = 10
        request.setValue("SwiftPulse", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let lat = json["latitude"] as? Double, let lon = json["longitude"] as? Double else { return nil }
        let loc = IPLocation(ip: json["ip"] as? String ?? host, city: json["city"] as? String ?? "", region: json["region"] as? String ?? "",
                             country: json["country_name"] as? String ?? "", countryCode: json["country_code"] as? String ?? "",
                             org: json["org"] as? String ?? "", coordinate: .init(latitude: lat, longitude: lon))
        await cache.set(host, loc)
        return loc
    }
}
