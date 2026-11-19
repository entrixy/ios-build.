import SwiftUI
import MapKit
import EntrixyCore

struct AutomationRouteMap: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var sensors: AutomationSensors
    @State var gate: AutomationGeoPoint?
    @State var routes: [[AutomationGeoPoint]]
    let readOnly: Bool
    let save: (AutomationGeoPoint?, [[AutomationGeoPoint]]) -> Void
    @State private var drawing = false
    @State private var relocating = false
    @State private var centerOnLocation = 0
    private func text(_ key: String) -> String { ProductText.string(key) }
    var body: some View {
        NavigationStack {
            RouteMapCanvas(gate: $gate, routes: $routes, drawing: $drawing, relocating: $relocating,
                readOnly: readOnly, location: sensors.location, centerRequest: centerOnLocation)
                .safeAreaInset(edge: .top) {
                    Text(hint).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14).background(.regularMaterial)
                }
                .safeAreaInset(edge: .bottom) { controls }
                .navigationTitle(text("corridor_title")).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(text("limit_dialog_close")) { dismiss() }.accessibilityIdentifier("route-map-close") }
                    if !readOnly {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(text("btn_save")) { save(gate, routes); dismiss() }.disabled(drawing).accessibilityIdentifier("route-map-save")
                        }
                    }
                }
        }
    }
    private var hint: String {
        if readOnly { return text("corridor_readonly") }
        if relocating { return text("corridor_hint_relocate") }
        if gate == nil { return text("corridor_hint_no_gate") }
        if drawing { return text("corridor_hint_drawing") }
        return routes.isEmpty ? text("corridor_hint_step2") : ProductText.string("corridor_hint_done_fmt", routes.count)
    }
    private var controls: some View {
        VStack(spacing: 10) {
            if !drawing {
                Button {
                    Task { if (try? await sensors.currentLocation()) != nil { centerOnLocation += 1 } }
                } label: { Label(text("corridor_my_location"), systemImage: "location") }.buttonStyle(SecondaryActionStyle())
            }
            Text(ProductText.string(readOnly ? "corridor_count_fmt" : "corridor_count_max_fmt", routes.count, 6))
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("route-map-count")
            if !readOnly {
                Button {
                    if drawing { drawing = false }
                    else if gate != nil && routes.count < 6 { drawing = true; relocating = false }
                } label: {
                    Label(text(drawing ? "corridor_cancel_draw" : routes.count >= 6 ? "corridor_limit_reached" : "corridor_draw"),
                        systemImage: drawing ? "xmark" : "pencil.tip")
                }.buttonStyle(PrimaryActionStyle()).disabled(!drawing && (gate == nil || routes.count >= 6)).accessibilityIdentifier("route-map-draw")
                if !drawing {
                    EqualActionRow {
                        Button(text("corridor_delete_route"), role: .destructive) { if !routes.isEmpty { routes.removeLast() } }
                            .buttonStyle(SecondaryActionStyle()).disabled(routes.isEmpty)
                        Button(text("corridor_move_gate")) { relocating = true }.buttonStyle(SecondaryActionStyle()).disabled(gate == nil)
                    }
                }
            }
        }.padding(14).background(.regularMaterial)
    }
}

private struct RouteMapCanvas: UIViewRepresentable {
    @Binding var gate: AutomationGeoPoint?
    @Binding var routes: [[AutomationGeoPoint]]
    @Binding var drawing: Bool
    @Binding var relocating: Bool
    let readOnly: Bool
    let location: CLLocation?
    let centerRequest: Int
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> MKMapView {
        let view = MKMapView(); view.delegate = context.coordinator; view.showsUserLocation = true
        view.accessibilityIdentifier = "automation-route-map"
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:)))
        tap.cancelsTouchesInView = false; view.addGestureRecognizer(tap)
        let stroke = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.stroke(_:)))
        view.addGestureRecognizer(stroke); context.coordinator.strokeGesture = stroke
        if let p = gate ?? location.map({ AutomationGeoPoint(lat: $0.coordinate.latitude, lon: $0.coordinate.longitude) }) {
            view.setRegion(MKCoordinateRegion(center: .init(latitude: p.lat, longitude: p.lon), latitudinalMeters: 600, longitudinalMeters: 600), animated: false)
        }
        return view
    }
    func updateUIView(_ view: MKMapView, context: Context) {
        let c = context.coordinator; c.parent = self
        c.strokeGesture?.isEnabled = drawing && !readOnly
        view.isScrollEnabled = !drawing; view.isZoomEnabled = !drawing
        let signature = String(describing: gate) + String(describing: routes)
        if c.signature != signature {
            c.signature = signature
            view.removeAnnotations(view.annotations.filter { !($0 is MKUserLocation) }); view.removeOverlays(view.overlays)
            if let gate {
                let pin = MKPointAnnotation(); pin.coordinate = .init(latitude: gate.lat, longitude: gate.lon)
                pin.title = ProductText.string("corridor_gate"); view.addAnnotation(pin)
            }
            for line in routes {
                let points = line.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
                view.addOverlay(MKPolyline(coordinates: points, count: points.count))
            }
        }
        if c.lastCenterRequest != centerRequest, let location {
            c.lastCenterRequest = centerRequest
            view.setRegion(MKCoordinateRegion(center: location.coordinate, latitudinalMeters: 400, longitudinalMeters: 400), animated: true)
        }
    }
    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: RouteMapCanvas
        var strokeGesture: UIPanGestureRecognizer?
        var signature = ""
        var lastCenterRequest = 0
        var points: [AutomationGeoPoint] = []
        private var lastPixel: CGPoint?
        private var temporary: MKPolyline?
        init(_ parent: RouteMapCanvas) { self.parent = parent }
        @objc func tap(_ gesture: UITapGestureRecognizer) {
            guard !parent.readOnly, !parent.drawing, parent.gate == nil || parent.relocating,
                  let map = gesture.view as? MKMapView else { return }
            let coordinate = map.convert(gesture.location(in: map), toCoordinateFrom: map)
            parent.gate = AutomationGeoPoint(lat: coordinate.latitude, lon: coordinate.longitude); parent.relocating = false
        }
        @objc func stroke(_ gesture: UIPanGestureRecognizer) {
            guard parent.drawing, !parent.readOnly, let map = gesture.view as? MKMapView else { return }
            if gesture.state == .began { points = []; lastPixel = nil }
            let pixel = gesture.location(in: map)
            if lastPixel.map({ hypot(pixel.x-$0.x, pixel.y-$0.y) >= 3 }) ?? true {
                let coordinate = map.convert(pixel, toCoordinateFrom: map)
                points.append(.init(lat: coordinate.latitude, lon: coordinate.longitude)); lastPixel = pixel
            }
            if let temporary { map.removeOverlay(temporary) }
            let coords = points.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
            if coords.count > 1 { let line = MKPolyline(coordinates: coords, count: coords.count); temporary = line; map.addOverlay(line) }
            if gesture.state == .ended || gesture.state == .cancelled {
                if gesture.state == .ended, parent.routes.count < 6 {
                    let line = GeoRouteGeometry.prepared(points, gate: parent.gate)
                    if line.count >= 2 { parent.routes.append(line) }
                }
                if let temporary { map.removeOverlay(temporary) }; temporary = nil; parent.drawing = false
            }
        }
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let line = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKPolylineRenderer(polyline: line); renderer.strokeColor = .systemOrange
            renderer.lineWidth = 5; renderer.lineCap = .round; renderer.lineJoin = .round
            return renderer
        }
    }
}
