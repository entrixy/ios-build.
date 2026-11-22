import SwiftUI
import MapKit
import EntrixyCore

private struct RouteControlsHeight: PreferenceKey {
    static var defaultValue:CGFloat = 0
    static func reduce(value:inout CGFloat,nextValue:()->CGFloat) { value = max(value,nextValue()) }
}

struct AutomationRouteMap: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var sensors: AutomationSensors
    @State var gate: AutomationGeoPoint?
    @State var routes: [[AutomationGeoPoint]]
    let readOnly: Bool
    let save: (AutomationGeoPoint?, [[AutomationGeoPoint]]) -> Void
    @State private var drawing = false
    @State private var relocating = false
    @State private var expanded = false
    @State private var controlsHeight:CGFloat = 0
    @State private var centerOnLocation = 0
    private func text(_ key: String) -> String { ProductText.string(key) }
    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                VStack(spacing:0) {
                    if !expanded { heading }
                    mapSurface
                    if !expanded { inlineControls(maximumHeight:proxy.size.height*0.44) }
                }.background(Color(uiColor:.systemGroupedBackground))
            }.toolbar(.hidden,for:.navigationBar)
        }
    }
    private var heading: some View {
        VStack(spacing:0) {
            TaskSheetHeader(title:text("corridor_title")) { EmptyView() }
            EqualActionRow {
                Button(text("limit_dialog_close")) { dismiss() }
                    .buttonStyle(SecondaryActionStyle()).accessibilityIdentifier("route-map-close")
                if !readOnly {
                    Button(text("btn_save")) { save(gate,routes);dismiss() }
                        .buttonStyle(PrimaryActionStyle()).disabled(drawing)
                        .accessibilityIdentifier("route-map-save")
                }
            }.padding(.horizontal,DesignMetrics.pageInset).padding(.bottom,12)
            Text(hint).font(.subheadline).frame(maxWidth:.infinity,alignment:.leading)
                .padding(.horizontal,DesignMetrics.pageInset).padding(.bottom,12)
        }
    }
    private var mapSurface: some View {
        ZStack {
            // One live MKMapView survives expand/collapse and retains its
            // viewport, unsaved gate and drawn corridors.
            RouteMapCanvas(gate:$gate,routes:$routes,drawing:$drawing,relocating:$relocating,
                readOnly:readOnly,location:sensors.location,centerRequest:centerOnLocation)
                .ignoresSafeArea(edges:expanded ? .all : [])
        }.frame(maxWidth:.infinity,maxHeight:.infinity)
            .overlay(alignment:.topTrailing) {
                Button { expanded.toggle() } label: {
                    Image(systemName:expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .resizable().scaledToFit().frame(width:24,height:24)
                }.buttonStyle(SquareIconActionStyle())
                    .accessibilityLabel(text(expanded ? "ios_map_collapse" : "ios_map_expand"))
                    .accessibilityIdentifier(expanded ? "route-map-collapse" : "route-map-expand")
                    .padding(12)
            }
            .overlay(alignment:.topLeading) {
                if !drawing {
                    Button { Task { if (try? await sensors.currentLocation()) != nil { centerOnLocation += 1 } } } label: {
                        Image(systemName:"location").resizable().scaledToFit().frame(width:24,height:24)
                    }.buttonStyle(SquareIconActionStyle()).accessibilityLabel(text("corridor_my_location")).padding(12)
                }
            }
            .overlay(alignment:.bottom) {
                if expanded {
                    VStack(alignment:.leading,spacing:10) {
                        Text(hint).font(.subheadline)
                        routeCount
                        if !readOnly { drawingAction }
                    }.padding(14).background(.regularMaterial,in:RoundedRectangle(cornerRadius:16))
                        .padding(.horizontal,DesignMetrics.pageInset).padding(.bottom,12)
                }
            }
    }
    private func inlineControls(maximumHeight:CGFloat) -> some View {
        ScrollView {
            controls.fixedSize(horizontal:false,vertical:true)
                .background(GeometryReader { bounds in Color.clear.preference(key:RouteControlsHeight.self,value:bounds.size.height) })
        }.scrollIndicators(.hidden)
            .frame(height:min(controlsHeight > 0 ? controlsHeight : maximumHeight,maximumHeight))
            .onPreferenceChange(RouteControlsHeight.self) { if abs(controlsHeight-$0)>0.5 { controlsHeight=$0 } }
    }
    private var hint: String {
        if readOnly { return text("corridor_readonly") }
        if relocating { return text("corridor_hint_relocate") }
        if gate == nil { return text("corridor_hint_no_gate") }
        if drawing { return text("corridor_hint_drawing") }
        return routes.isEmpty ? text("ios_map_draw_hint") : ProductText.string("corridor_hint_done_fmt",routes.count)
    }
    private var routeCount: some View {
        Text(ProductText.string(readOnly ? "corridor_count_fmt" : "corridor_count_max_fmt",routes.count,6))
            .frame(maxWidth:.infinity,alignment:.leading).accessibilityIdentifier("route-map-count")
    }
    @ViewBuilder private var drawingAction: some View {
        if drawing {
            Button { drawing=false } label: {
                LeadingActionLabel(title:text("corridor_cancel_draw"),systemImage:"xmark")
            }.buttonStyle(SecondaryActionStyle()).accessibilityIdentifier("route-map-draw")
        } else {
            Button {
                if gate != nil && routes.count < 6 { drawing=true;relocating=false }
            } label: {
                LeadingActionLabel(title:text(routes.count >= 6 ? "corridor_limit_reached" : "ios_map_draw_corridor"),systemImage:"scribble.variable")
            }.buttonStyle(PrimaryActionStyle()).disabled(gate == nil || routes.count >= 6)
                .accessibilityIdentifier("route-map-draw")
        }
    }
    private var controls: some View {
        VStack(spacing:12) {
            routeCount
            if !readOnly {
                drawingAction
                if !drawing {
                    EqualActionRow {
                        Button(text("corridor_delete_route"),role:.destructive) { if !routes.isEmpty { routes.removeLast() } }
                            .buttonStyle(SecondaryActionStyle()).disabled(routes.isEmpty)
                        Button(text("corridor_move_gate")) { relocating=true }.buttonStyle(SecondaryActionStyle()).disabled(gate == nil)
                    }
                }
            }
        }.padding(DesignMetrics.pageInset)
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
        if !drawing { c.clearStroke(in:view) }
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
        func clearStroke(in map:MKMapView) {
            if let temporary { map.removeOverlay(temporary) }
            temporary=nil;points=[];lastPixel=nil
        }
        @objc func stroke(_ gesture: UIPanGestureRecognizer) {
            guard parent.drawing, !parent.readOnly, let map = gesture.view as? MKMapView else { return }
            let pixel = gesture.location(in: map)
            if gesture.state == .began {
                // UIPan begins only after movement crosses its threshold. Keep
                // the touch origin too, as Android's onDragStart does, so a
                // quick stroke with coalesced move events still has endpoints.
                let translation = gesture.translation(in:map)
                let start = CGPoint(x:pixel.x-translation.x,y:pixel.y-translation.y)
                let coordinate = map.convert(start,toCoordinateFrom:map)
                points = [.init(lat:coordinate.latitude,lon:coordinate.longitude)]
                lastPixel = start
            }
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
