//
//  OctopusSyncApp.swift
//  OctopusSync
//
//  Created by Dzmitry Sharko on 22.04.2026.
//

import SwiftUI

@main
struct OctopusSyncApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra("OctopusSync", image: "MenuBarIcon") {
            ContentView(appState: appState)
                .environmentObject(appState)
        }
        .menuBarExtraStyle(.window)
    }
}
