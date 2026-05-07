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

        guard centerChanged || spanChanged else { return }

        context.coordinator.lastSwiftUICenter = newCenter
        context.coordinator.lastSwiftUISpan = newSpan

        if let from = oldCenter,
           Coordinator.shouldFlyOver(from: from, to: newCenter, fromSpan: oldSpan, toSpan: newSpan) {
            context.coordinator.flyTo(mapView: nsView, fromSpan: oldSpan ?? newSpan, target: region)
        } else {
            nsView.setRegion(region, animated: true)
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    class Coordinator: NSObject, MKMapViewDelegate {
        var parent: NativeMapView
        var lastSwiftUICenter: CLLocationCoordinate2D?
        var lastSwiftUISpan: MKCoordinateSpan?

        // Multi-stage flight bookkeeping
        private var isFlying = false
        private var flightToken: UUID?
        private var animationTimer: Timer?

        // Tunables — adjust to taste.
        private let launchDuration: TimeInterval = 0.85
        private let baseCruiseDuration: TimeInterval = 1.9
        private let descentDuration: TimeInterval = 1.5
        private let frameInterval: TimeInterval = 1.0 / 60.0

        init(_ parent: NativeMapView) { self.parent = parent }

        // Treat as a long-haul jump when the great-circle distance is more than ~3 viewports away.
        static func shouldFlyOver(
            from: CLLocationCoordinate2D,
            to: CLLocationCoordinate2D,
            fromSpan: MKCoordinateSpan?,
            toSpan: MKCoordinateSpan
        ) -> Bool {
            let earthRadius = 6_371_000.0
            let lat1 = from.latitude * .pi / 180
            let lat2 = to.latitude * .pi / 180
            let dLat = (to.latitude - from.latitude) * .pi / 180
            let dLon = shortestLongitudeDelta(from: from.longitude, to: to.longitude) * .pi / 180
            let h = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
            let distance = 2 * earthRadius * atan2(sqrt(h), sqrt(1 - h))

            let span = fromSpan ?? toSpan
            // Latitudinal degree ≈ 111 km; use the larger span side as the rough viewport diameter.
            let viewport = max(span.latitudeDelta, span.longitudeDelta) * 111_000
            return distance > viewport * 3
        }

        // Three-stage "rocket flight": launch straight up over the source, cruise horizontally
        // at altitude, then descend onto the target. Center stays put during launch/descent so it
        // reads as a vertical lift-off and landing rather than a centered overview cross-fade.
        func flyTo(
            mapView: MKMapView,
            fromSpan: MKCoordinateSpan,
            target: MKCoordinateRegion
        ) {
            let from = mapView.region.center
            let lonDelta = Coordinator.shortestLongitudeDelta(from: from.longitude, to: target.center.longitude)

            // Apex span: ~0.8x angular distance keeps the source visible at lift-off and reveals
            // varied terrain during cruise instead of trying to fit both endpoints in one frame.
            let latApex = max(
                abs(target.center.latitude - from.latitude) * 0.8,
                fromSpan.latitudeDelta * 6,
                target.span.latitudeDelta * 6,
                4.0
            )
            let lonApex = max(
                abs(lonDelta) * 0.8,
                fromSpan.longitudeDelta * 6,
                target.span.longitudeDelta * 6,
                4.0
            )
            let apexSpan = MKCoordinateSpan(
                latitudeDelta: min(latApex, 140),
                longitudeDelta: min(lonApex, 300)
            )

            let launchEnd = MKCoordinateRegion(center: from, span: apexSpan)
            let cruiseEnd = MKCoordinateRegion(center: target.center, span: apexSpan)

            // Cruise duration scales with angular distance so short hops don't drag and trans-
            // oceanic flights don't blur past.
            let angularDistance = sqrt(
                pow(target.center.latitude - from.latitude, 2)
                + pow(lonDelta, 2)
            )
            let cruiseScale = min(max(angularDistance / 90.0, 0.65), 2.0)
            let cruiseDuration = baseCruiseDuration * cruiseScale

            let token = UUID()
            flightToken = token
            isFlying = true
            cancelTimer()

            let stage1Start = mapView.region

            // Stage 1 — launch: zoom out, center stays at source.
            animateRegion(
                mapView: mapView,
                from: stage1Start,
                to: launchEnd,
                duration: launchDuration,
                token: token
            ) { [weak self, weak mapView] in
                guard let self, let mapView, self.flightToken == token else { return }
                // Stage 2 — cruise: pan to target at apex altitude.
                self.animateRegion(
                    mapView: mapView,
                    from: launchEnd,
                    to: cruiseEnd,
                    duration: cruiseDuration,
                    token: token
                ) { [weak self, weak mapView] in
                    guard let self, let mapView, self.flightToken == token else { return }
                    // Stage 3 — descent: zoom in, center stays at target.
                    self.animateRegion(
                        mapView: mapView,
                        from: cruiseEnd,
                        to: target,
                        duration: self.descentDuration,
                        token: token
                    ) { [weak self, weak mapView] in
                        guard let self, let mapView, self.flightToken == token else { return }
                        self.isFlying = false
                        self.lastSwiftUICenter = mapView.region.center
                        self.lastSwiftUISpan = mapView.region.span
                        self.parent.region = mapView.region
                        self.parent.onRegionChange(mapView.centerCoordinate)
                    }
                }
            }
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            // Don't bounce the in-flight overview region back into SwiftUI — the binding still holds
            // the user-requested target, and overwriting it would kill the second-stage dive.
            guard !isFlying else { return }
            DispatchQueue.main.async {
                self.lastSwiftUICenter = mapView.region.center
                self.lastSwiftUISpan = mapView.region.span
                self.parent.region = mapView.region
                self.parent.onRegionChange(mapView.centerCoordinate)
            }
        }

        // MARK: - Manual region interpolation

        private func animateRegion(
            mapView: MKMapView,
            from start: MKCoordinateRegion,
            to end: MKCoordinateRegion,
            duration: TimeInterval,
            token: UUID,
            completion: @escaping () -> Void
        ) {
            cancelTimer()

            let startTime = CACurrentMediaTime()
            let lonDelta = Coordinator.shortestLongitudeDelta(from: start.center.longitude, to: end.center.longitude)
            // Interpolate span in log-space so perceived zoom rate stays uniform across big ratios.
            let logStartLat = log(max(start.span.latitudeDelta, 0.0001))
            let logEndLat = log(max(end.span.latitudeDelta, 0.0001))
            let logStartLon = log(max(start.span.longitudeDelta, 0.0001))
            let logEndLon = log(max(end.span.longitudeDelta, 0.0001))

            let timer = Timer(timeInterval: frameInterval, repeats: true) { [weak self, weak mapView] timer in
                guard let self, let mapView, self.flightToken == token else {
                    timer.invalidate()
                    return
                }
                let elapsed = CACurrentMediaTime() - startTime
                let progress = min(max(elapsed / duration, 0), 1)
                let eased = Coordinator.easeInOutCubic(progress)

                let lat = start.center.latitude + (end.center.latitude - start.center.latitude) * eased
                let lon = Coordinator.normalizeLongitude(start.center.longitude + lonDelta * eased)
                let latSpan = exp(logStartLat + (logEndLat - logStartLat) * eased)
                let lonSpan = exp(logStartLon + (logEndLon - logStartLon) * eased)

                mapView.setRegion(
                    MKCoordinateRegion(
                        center: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                        span: MKCoordinateSpan(latitudeDelta: latSpan, longitudeDelta: lonSpan)
                    ),
                    animated: false
                )

                if progress >= 1 {
                    timer.invalidate()
                    self.animationTimer = nil
                    completion()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            animationTimer = timer
        }

        private func cancelTimer() {
            animationTimer?.invalidate()
            animationTimer = nil
        }

        // MARK: - Math helpers

        // Pick the shorter east/west arc so antimeridian crossings (e.g. New York → Tokyo) fly the Pacific.
        static func shortestLongitudeDelta(from: Double, to: Double) -> Double {
            var delta = to - from
            if delta > 180 { delta -= 360 }
            if delta < -180 { delta += 360 }
            return delta
        }

        static func normalizeLongitude(_ longitude: Double) -> Double {
            var lon = longitude
            while lon > 180 { lon -= 360 }
            while lon < -180 { lon += 360 }
            return lon
        }

        // Smooth ease-in-out, gentler at both ends than MapKit's default.
        static func easeInOutCubic(_ t: Double) -> Double {
            let clamped = max(0, min(1, t))
            if clamped < 0.5 {
                return 4 * clamped * clamped * clamped
            }
            let p = 2 * clamped - 2
            return 0.5 * p * p * p + 1
        }
    }
}
