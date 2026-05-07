//
//  OctopusSyncApp.swift
//  OctopusSync
//
//  Created by Dzmitry Sharko on 22.04.2026.
//

import SwiftUI
import AppKit

struct OctopusSyncApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            ContentView(appState: appState)
                .environmentObject(appState)
        } label: {
            MenuBarIconView()
        }
        .menuBarExtraStyle(.window)
    }
}

// Loads the menu bar icon from the main bundle as a raw PNG file, which works
// both with Xcode (xcassets) and SPM (plain Resources/) builds.
private struct MenuBarIconView: View {
    var body: some View {
        if let nsImage = NSImage(named: "MenuBarIcon") {
            // Xcode / xcassets path
            Image(nsImage: nsImage)
                .renderingMode(.template)
        } else if let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png"),
                  let nsImage = NSImage(contentsOf: url) {
            // SPM plain-PNG path
            Image(nsImage: configured(nsImage))
                .renderingMode(.template)
        } else {
            // Fallback: SF Symbol so the app is always visible
            Image(systemName: "arrow.left.arrow.right")
        }
    }

    private func configured(_ image: NSImage) -> NSImage {
        image.isTemplate = true
        return image
    }
}
