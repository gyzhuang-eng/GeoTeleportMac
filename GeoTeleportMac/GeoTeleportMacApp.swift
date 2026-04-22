//
//  GeoTeleportMacApp.swift
//  GeoTeleportMac
//
//  Created by gyzhuang on 2025/12/19.
//

import SwiftUI
import Darwin

@main
struct GeoTeleportMacApp: App {
    init() {
        if V3DeviceAgentEntrypoint.runIfNeeded() {
            Darwin.exit(0)
        }
    }

    var body: some Scene {
        WindowGroup("GeoTeleportMac V3 Preview") {
            ContentView()
        }
    }
}
