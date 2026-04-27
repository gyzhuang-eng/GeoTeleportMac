import SwiftUI
import MapKit
import AppKit

// 原生地图引擎封装 (AppKit MKMapView)
struct NativeMapView: NSViewRepresentable {
    @Binding var region: MKCoordinateRegion
    var onRegionChange: (CLLocationCoordinate2D) -> Void
    func makeNSView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.mapType = .mutedStandard
        mapView.showsUserLocation = false
        mapView.isRotateEnabled = false
        mapView.isPitchEnabled = false
        mapView.showsZoomControls = true
        mapView.showsCompass = true
        mapView.showsScale = true
        mapView.appearance = NSAppearance(named: .vibrantDark)
        return mapView
    }
    func updateNSView(_ nsView: MKMapView, context: Context) {
        // Only jump the map if the region was explicitly updated by SwiftUI (e.g., search, preset click)
        // rather than by the map's own scrolling/zooming events.
        let oldCenter = context.coordinator.lastSwiftUICenter
        let oldSpan = context.coordinator.lastSwiftUISpan
        
        let newCenter = region.center
        let newSpan = region.span
        
        let centerChanged = oldCenter == nil || abs(oldCenter!.latitude - newCenter.latitude) > 0.0001 || abs(oldCenter!.longitude - newCenter.longitude) > 0.0001
        let spanChanged = oldSpan == nil || abs(oldSpan!.latitudeDelta - newSpan.latitudeDelta) > 0.001
        
        if centerChanged || spanChanged {
            context.coordinator.lastSwiftUICenter = newCenter
            context.coordinator.lastSwiftUISpan = newSpan
            nsView.setRegion(region, animated: true)
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    class Coordinator: NSObject, MKMapViewDelegate {
        var parent: NativeMapView
        var lastSwiftUICenter: CLLocationCoordinate2D?
        var lastSwiftUISpan: MKCoordinateSpan?
        
        init(_ parent: NativeMapView) { self.parent = parent }
        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            DispatchQueue.main.async {
                // When the map finishes moving, update the tracked SwiftUI state
                // to prevent updateNSView from bouncing it back to the old location
                self.lastSwiftUICenter = mapView.region.center
                self.lastSwiftUISpan = mapView.region.span
                self.parent.region = mapView.region
                self.parent.onRegionChange(mapView.centerCoordinate)
            }
        }
    }
}