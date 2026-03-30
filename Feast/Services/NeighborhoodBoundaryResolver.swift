import CoreLocation
import Foundation
import os

struct NeighborhoodBoundaryMatch: Equatable {
    let displayName: String
    let source: String
    let datasetName: String
}

enum NeighborhoodBoundaryResolver {
    /// Loads the bundled GeoJSON dataset at `Resources/NeighborhoodBoundaries/NYCNeighborhoodBoundaries.geojson`.
    /// The file is a GeoJSON FeatureCollection whose features contain a `name` property and
    /// Polygon/MultiPolygon coordinates in `[longitude, latitude]` order.
    nonisolated static let datasetResourcePath = "Resources/NeighborhoodBoundaries/NYCNeighborhoodBoundaries.geojson"

    nonisolated static func resolveNeighborhood(
        at coordinate: CLLocationCoordinate2D
    ) -> NeighborhoodBoundaryMatch? {
        sharedDataset?.resolveNeighborhood(at: coordinate)
    }

    nonisolated static func resolveNeighborhood(
        at coordinate: CLLocationCoordinate2D,
        in bundle: Bundle
    ) -> NeighborhoodBoundaryMatch? {
        if bundle.bundleURL == Bundle.main.bundleURL {
            return resolveNeighborhood(at: coordinate)
        }

        return loadDataset(from: bundle)?.resolveNeighborhood(at: coordinate)
    }

    nonisolated static func datasetURL(in bundle: Bundle = .main) -> URL? {
        findDatasetURL(in: bundle)
    }

    nonisolated private static let logger = Logger(
        subsystem: "com.jongalante.Feast",
        category: "NeighborhoodResolver"
    )

    nonisolated private static let sharedDataset = loadDataset(from: .main)

    nonisolated private static func loadDataset(from bundle: Bundle) -> NeighborhoodBoundaryDataset? {
        guard let datasetURL = findDatasetURL(in: bundle) else {
            #if DEBUG
            logger.debug(
                "Neighborhood boundary dataset missing at \(datasetResourcePath, privacy: .public)"
            )
            #endif
            return nil
        }

        do {
            let data = try Data(contentsOf: datasetURL)
            return try NeighborhoodBoundaryDataset(
                data: data,
                datasetName: "NYC Neighborhood Boundaries",
                source: "coordinateResolver.nycGeoJSON"
            )
        } catch {
            #if DEBUG
            logger.error(
                "Failed to load neighborhood boundary dataset \(datasetURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            #endif
            return nil
        }
    }

    nonisolated private static func findDatasetURL(in bundle: Bundle) -> URL? {
        let resourceName = "NYCNeighborhoodBoundaries"

        let directURL = bundle.url(
            forResource: resourceName,
            withExtension: "geojson",
            subdirectory: "Resources/NeighborhoodBoundaries"
        )
            ?? bundle.url(forResource: resourceName, withExtension: "geojson")

        if let directURL {
            return directURL
        }

        return bundle.urls(forResourcesWithExtension: "geojson", subdirectory: nil)?
            .first(where: { $0.lastPathComponent == "\(resourceName).geojson" })
    }
}

private struct NeighborhoodBoundaryDataset {
    let datasetName: String
    let source: String
    let boundaries: [NeighborhoodBoundary]

    nonisolated
    init(
        data: Data,
        datasetName: String,
        source: String
    ) throws {
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let features = root["features"] as? [Any]
        else {
            throw NeighborhoodBoundaryResolverError.invalidGeoJSON
        }

        let boundaries = features.compactMap(NeighborhoodBoundary.init(featureObject:))
            .sorted { lhs, rhs in
                if lhs.sortArea != rhs.sortArea {
                    return lhs.sortArea < rhs.sortArea
                }

                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }

        guard !boundaries.isEmpty else {
            throw NeighborhoodBoundaryResolverError.invalidGeoJSON
        }

        self.datasetName = datasetName
        self.source = source
        self.boundaries = boundaries
    }

    nonisolated
    func resolveNeighborhood(at coordinate: CLLocationCoordinate2D) -> NeighborhoodBoundaryMatch? {
        guard CLLocationCoordinate2DIsValid(coordinate) else {
            return nil
        }

        guard let boundary = boundaries.first(where: { $0.contains(coordinate) }) else {
            return nil
        }

        return NeighborhoodBoundaryMatch(
            displayName: boundary.name,
            source: source,
            datasetName: datasetName
        )
    }
}

private struct NeighborhoodBoundary {
    let name: String
    let polygons: [NeighborhoodPolygon]
    let bounds: NeighborhoodCoordinateBounds
    let sortArea: Double

    nonisolated
    init?(featureObject: Any) {
        guard
            let feature = featureObject as? [String: Any],
            let properties = feature["properties"] as? [String: Any],
            let rawName = properties["name"] as? String,
            let name = FeastNeighborhoodName.canonicalDisplayName(for: rawName),
            let geometry = feature["geometry"] as? [String: Any],
            let geometryType = geometry["type"] as? String
        else {
            return nil
        }

        let polygons: [NeighborhoodPolygon]
        switch geometryType {
        case "Polygon":
            guard let polygon = NeighborhoodPolygon(rawObject: geometry["coordinates"]) else {
                return nil
            }
            polygons = [polygon]
        case "MultiPolygon":
            guard
                let rawPolygons = geometry["coordinates"] as? [Any],
                !rawPolygons.isEmpty
            else {
                return nil
            }

            polygons = rawPolygons.compactMap { NeighborhoodPolygon(rawObject: $0) }
            guard !polygons.isEmpty else {
                return nil
            }
        default:
            return nil
        }

        guard let bounds = NeighborhoodCoordinateBounds(polygons: polygons) else {
            return nil
        }

        self.name = name
        self.polygons = polygons
        self.bounds = bounds
        self.sortArea = polygons.reduce(0) { $0 + $1.area }
    }

    nonisolated
    func contains(_ coordinate: CLLocationCoordinate2D) -> Bool {
        guard bounds.contains(coordinate) else {
            return false
        }

        return polygons.contains { $0.contains(coordinate) }
    }
}

private struct NeighborhoodPolygon {
    let outerRing: [CLLocationCoordinate2D]
    let interiorRings: [[CLLocationCoordinate2D]]
    let bounds: NeighborhoodCoordinateBounds
    let area: Double

    nonisolated
    init?(rawObject: Any?) {
        guard
            let rawRings = rawObject as? [Any],
            !rawRings.isEmpty
        else {
            return nil
        }

        var parsedRings: [[CLLocationCoordinate2D]] = []
        for rawRing in rawRings {
            guard let ring = Self.parseRing(from: rawRing) else {
                continue
            }

            parsedRings.append(ring)
        }

        guard
            let outerRing = parsedRings.first,
            let bounds = NeighborhoodCoordinateBounds(points: outerRing)
        else {
            return nil
        }

        self.outerRing = outerRing
        self.interiorRings = Array(parsedRings.dropFirst())
        self.bounds = bounds
        self.area = Self.area(of: outerRing)
    }

    nonisolated
    func contains(_ coordinate: CLLocationCoordinate2D) -> Bool {
        guard bounds.contains(coordinate) else {
            return false
        }

        guard Self.pointInPolygon(coordinate, ring: outerRing) else {
            return false
        }

        for interiorRing in interiorRings where Self.pointInPolygon(coordinate, ring: interiorRing) {
            return false
        }

        return true
    }

    nonisolated private static func parseRing(from rawObject: Any) -> [CLLocationCoordinate2D]? {
        guard let rawPoints = rawObject as? [Any] else {
            return nil
        }

        var points: [CLLocationCoordinate2D] = []

        for rawPoint in rawPoints {
            guard
                let pointValues = rawPoint as? [Any],
                pointValues.count >= 2,
                let longitude = numericValue(from: pointValues[0]),
                let latitude = numericValue(from: pointValues[1])
            else {
                continue
            }

            let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            guard CLLocationCoordinate2DIsValid(coordinate) else {
                continue
            }

            points.append(coordinate)
        }

        if let first = points.first, let last = points.last, first.latitude == last.latitude, first.longitude == last.longitude {
            points.removeLast()
        }

        return points.count >= 3 ? points : nil
    }

    nonisolated private static func numericValue(from rawValue: Any) -> Double? {
        if let value = rawValue as? Double {
            return value
        }

        if let value = rawValue as? NSNumber {
            return value.doubleValue
        }

        return nil
    }

    nonisolated private static func area(of ring: [CLLocationCoordinate2D]) -> Double {
        guard ring.count >= 3 else {
            return 0
        }

        var area = 0.0
        for index in ring.indices {
            let current = ring[index]
            let next = ring[(index + 1) % ring.count]
            area += (current.longitude * next.latitude) - (next.longitude * current.latitude)
        }

        return abs(area) / 2
    }

    nonisolated private static func pointInPolygon(
        _ coordinate: CLLocationCoordinate2D,
        ring: [CLLocationCoordinate2D]
    ) -> Bool {
        guard ring.count >= 3 else {
            return false
        }

        let x = coordinate.longitude
        let y = coordinate.latitude
        var contains = false
        var previousIndex = ring.count - 1

        for index in ring.indices {
            let current = ring[index]
            let previous = ring[previousIndex]
            let intersects = ((current.latitude > y) != (previous.latitude > y))
                && (
                    x < (previous.longitude - current.longitude)
                        * (y - current.latitude)
                        / ((previous.latitude - current.latitude) == 0 ? .leastNonzeroMagnitude : (previous.latitude - current.latitude))
                        + current.longitude
                )

            if intersects {
                contains.toggle()
            }

            previousIndex = index
        }

        return contains
    }
}

private struct NeighborhoodCoordinateBounds {
    let minLatitude: Double
    let maxLatitude: Double
    let minLongitude: Double
    let maxLongitude: Double

    nonisolated
    init?(points: [CLLocationCoordinate2D]) {
        guard !points.isEmpty else {
            return nil
        }

        minLatitude = points.map(\.latitude).min() ?? 0
        maxLatitude = points.map(\.latitude).max() ?? 0
        minLongitude = points.map(\.longitude).min() ?? 0
        maxLongitude = points.map(\.longitude).max() ?? 0
    }

    nonisolated
    init?(polygons: [NeighborhoodPolygon]) {
        guard !polygons.isEmpty else {
            return nil
        }

        minLatitude = polygons.map(\.bounds.minLatitude).min() ?? 0
        maxLatitude = polygons.map(\.bounds.maxLatitude).max() ?? 0
        minLongitude = polygons.map(\.bounds.minLongitude).min() ?? 0
        maxLongitude = polygons.map(\.bounds.maxLongitude).max() ?? 0
    }

    nonisolated
    func contains(_ coordinate: CLLocationCoordinate2D) -> Bool {
        coordinate.latitude >= minLatitude
            && coordinate.latitude <= maxLatitude
            && coordinate.longitude >= minLongitude
            && coordinate.longitude <= maxLongitude
    }
}

private enum NeighborhoodBoundaryResolverError: Error {
    case invalidGeoJSON
}
