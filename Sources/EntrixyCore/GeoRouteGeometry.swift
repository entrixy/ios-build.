import Foundation

/// CorridorMapScreen's local projection, variable Douglas–Peucker tolerance,
/// orientation and 5 m endpoint snapping. The stored path runs toward the gate.
public enum GeoRouteGeometry {
    public static func distance(_ a: AutomationGeoPoint, _ b: AutomationGeoPoint) -> Double {
        hypot((a.lon-b.lon) * 111320 * cos(b.lat * .pi / 180), (a.lat-b.lat) * 111320)
    }
    public static func prepared(_ points: [AutomationGeoPoint], gate: AutomationGeoPoint?) -> [AutomationGeoPoint] {
        guard points.count >= 2, points.allSatisfy(\.valid) else { return [] }
        let reference = gate ?? points[0]
        let scale = 111320 * cos(reference.lat * .pi / 180)
        let x = points.map { ($0.lon-reference.lon) * scale }, y = points.map { ($0.lat-reference.lat) * 111320 }
        var keep = Set([0, points.count-1]), stack = [(0, points.count-1)]
        while let (low, high) = stack.popLast() {
            guard high-low >= 2 else { continue }
            let dx = x[high]-x[low], dy = y[high]-y[low], length = dx*dx+dy*dy
            var furthest: Int?, deviation = 0.0
            for i in (low+1)..<high {
                let t = length <= 1e-9 ? 0 : ((x[i]-x[low])*dx+(y[i]-y[low])*dy)/length
                let d = hypot(x[i]-(x[low]+t*dx), y[i]-(y[low]+t*dy))
                if d > deviation { deviation = d; furthest = i }
            }
            if let index = furthest {
                let tolerance = 2 + 10 * min(1, max(0, hypot(x[index],y[index])/120))
                if deviation > tolerance { keep.insert(index); stack.append((low,index)); stack.append((index,high)) }
            }
        }
        var result = keep.sorted().map { points[$0] }
        if let gate {
            if distance(result[0],gate) < distance(result[result.count-1],gate) { result.reverse() }
            if distance(result[result.count-1],gate) <= 5 { result[result.count-1] = gate }
        }
        return result
    }
}
