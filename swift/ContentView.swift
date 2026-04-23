//
//  ContentView.swift
//  OctopusSync
//
//  Created by Dzmitry Sharko on 22.04.2026.
//

import SwiftUI

struct ContentView: View {
    @ObservedObject var appState: AppState
    @State private var showingPermissionsAlert = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("OctopusSync")
                    .font(.headline)
                Spacer()
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
            }
            .padding(.bottom, 4)

            Text("Status: \(appState.connectionStatus.rawValue)")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Devices")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if appState.availableDevices.isEmpty {
                    Text("No HID devices found")
                        .font(.caption2)
                        .italic()
                        .foregroundColor(.gray)
                } else {
                    ForEach(appState.availableDevices) { device in
                        Toggle(isOn: Binding(
                            get: { device.isSelected },
                            set: { _ in appState.toggleDeviceSelection(device) }
                        )) {
                            HStack {
                                Image(systemName: iconForDevice(device.type))
                                Text(device.name)
                                    .lineLimit(1)
                            }
                        }
                        .toggleStyle(SwitchToggleStyle(tint: .blue))
                    }
                }
            }

            Divider()

            Toggle("Launch at Login", isOn: Binding(
                get: { appState.launchAtLogin },
                set: { _ in appState.toggleLaunchAtLogin() }
            ))
            .toggleStyle(SwitchToggleStyle(tint: .blue))

            Toggle("Sharing Active", isOn: Binding(
                get: { appState.isSharingActive },
                set: { _ in 
                    if PermissionsHelper.checkAndPromptAccessibilityPermission() {
                        appState.toggleSharing()
                    } else {
                        showingPermissionsAlert = true
                    }
                }
            ))
            .toggleStyle(SwitchToggleStyle(tint: .green))
            .disabled(appState.connectionStatus != .connected)

            Divider()

            HStack {
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(PlainButtonStyle())
                .foregroundColor(.red)
                
                Spacer()
                
                Button(action: {
                    if appState.connectionStatus == .disconnected {
                        appState.networkManager.start()
                    } else {
                        appState.networkManager.stop()
                    }
                }) {
                    Text(appState.connectionStatus == .disconnected ? "Start Network" : "Stop Network")
                }
            }
        }
        .padding()
        .frame(width: 250)
        .alert(isPresented: $showingPermissionsAlert) {
            Alert(
                title: Text("Accessibility Access Required"),
                message: Text("OctopusSync requires Accessibility permissions to capture and inject keyboard/mouse events.\n\nClick 'Open Settings' to open System Settings -> Privacy & Security -> Accessibility, then turn on the toggle next to OctopusSync (or use the + button to add it if it's missing)."),
                primaryButton: .default(Text("Open Settings"), action: {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                }),
                secondaryButton: .cancel(Text("Later"))
            )
        }
        .onAppear {
            if !PermissionsHelper.checkAndPromptAccessibilityPermission() {
                showingPermissionsAlert = true
            }
            appState.networkManager.start()
        }
    }

    private var statusColor: Color {
        switch appState.connectionStatus {
        case .disconnected: return .red
        case .lookingForHost, .hosting: return .yellow
        case .connected: return .green
        }
    }
    
    private func iconForDevice(_ type: BluetoothDevice.DeviceType) -> String {
        switch type {
        case .keyboard: return "keyboard"
        case .mouse: return "computermouse"
        case .touchpad: return "magicmouse"
        case .other: return "questionmark.circle"
        }
    }
}
