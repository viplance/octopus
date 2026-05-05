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
    @State private var showMonitorSetup = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // ── Header ──────────────────────────────────────────────────────
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

            // ── Devices ──────────────────────────────────────────────────────
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

            // ── Monitor switching ─────────────────────────────────────────────
            MonitorSectionView(monitor: appState.monitorManager)

            Divider()

            // ── Global toggles ────────────────────────────────────────────────
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

            // ── Footer ────────────────────────────────────────────────────────
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
        .frame(width: 290)
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

// MARK: - Monitor Section

struct MonitorSectionView: View {
    @ObservedObject var monitor: MonitorManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Monitor Switch")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { monitor.config.enabled },
                    set: { monitor.config.enabled = $0 }
                ))
                .toggleStyle(SwitchToggleStyle(tint: .orange))
                .labelsHidden()
            }

            if monitor.config.enabled {
                // Token input
                VStack(alignment: .leading, spacing: 4) {
                    Text("SmartThings Token")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    SecureField("Personal Access Token", text: Binding(
                        get: { monitor.config.personalAccessToken },
                        set: { monitor.config.personalAccessToken = $0 }
                    ))
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .font(.caption2)
                }

                // Discover monitors button
                HStack {
                    Button(action: { monitor.discoverDevices() }) {
                        HStack(spacing: 4) {
                            if monitor.isQuerying {
                                ProgressView().scaleEffect(0.6)
                            } else {
                                Image(systemName: "magnifyingglass")
                            }
                            Text("Detect Monitors")
                        }
                    }
                    .disabled(monitor.isQuerying || monitor.config.personalAccessToken.isEmpty)
                    .font(.caption)

                    Spacer()
                }

                // Device picker (auto-populated after detection)
                if !monitor.detectedDevices.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Monitor Device")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Picker("", selection: Binding(
                            get: { monitor.config.deviceId },
                            set: {
                                monitor.config.deviceId = $0
                                monitor.fetchSupportedInputSources()
                            }
                        )) {
                            ForEach(monitor.detectedDevices) { device in
                                Text(device.label).tag(device.id)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(MenuPickerStyle())
                    }
                } else if !monitor.config.deviceId.isEmpty {
                    // Manual device ID when auto-detection was not used
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Device ID (manual)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        TextField("SmartThings Device ID", text: Binding(
                            get: { monitor.config.deviceId },
                            set: { monitor.config.deviceId = $0 }
                        ))
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .font(.caption2)
                    }
                } else {
                    // Prompt to either detect or enter manually
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Device ID (manual)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        TextField("SmartThings Device ID", text: Binding(
                            get: { monitor.config.deviceId },
                            set: { monitor.config.deviceId = $0 }
                        ))
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .font(.caption2)
                    }
                }

                // Input source picker
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("This Mac's Input")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Spacer()
                        Button(action: { monitor.fetchSupportedInputSources() }) {
                            Image(systemName: "arrow.clockwise")
                                .font(.caption2)
                        }
                        .disabled(monitor.isQuerying || monitor.config.deviceId.isEmpty)
                        .help("Refresh supported input sources from monitor")
                    }
                    Picker("", selection: Binding(
                        get: { monitor.config.myInputSource },
                        set: { monitor.config.myInputSource = $0 }
                    )) {
                        ForEach(monitor.availableInputSources, id: \.self) { source in
                            Text(source).tag(source)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(MenuPickerStyle())

                    Text("Monitor switches to this input when you toggle sync ON.")
                        .font(.caption2)
                        .foregroundColor(.gray)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Error display
                if let err = monitor.lastError {
                    Text(err)
                        .font(.caption2)
                        .foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
