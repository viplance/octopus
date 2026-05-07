//
//  ContentView.swift
//  OctopusSync
//
//  Created by Dzmitry Sharko on 22.04.2026.
//

import SwiftUI

struct ContentView: View {
    @ObservedObject var appState: AppState

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

            if !appState.isAccessibilityGranted {
                Button(action: {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    Label("Accessibility access required", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
                .buttonStyle(PlainButtonStyle())
            }

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

            Divider()

            // ── Footer ────────────────────────────────────────────────────────
            HStack {
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(PlainButtonStyle())
                .foregroundColor(.red)

                Spacer()
            }
        }
        .padding()
        .frame(width: 290)
        .alert("Connection Lost", isPresented: $appState.showConnectionLostAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The peer Mac is not connected. Sharing has been paused. Reconnect and try again.")
        }
        .onAppear {
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
                // ── Mode picker ────────────────────────────────────────────
                VStack(alignment: .leading, spacing: 4) {
                    Text("Mode")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Picker("", selection: Binding(
                        get: { monitor.config.monitorMode },
                        set: { monitor.config.monitorMode = $0 }
                    )) {
                        ForEach(MonitorManager.MonitorMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(MenuPickerStyle())

                    Group {
                        switch monitor.config.monitorMode {
                        case .direct:
                            Text("When you give focus to the peer, this Mac sleeps its display output. The monitor auto-switches to the other Mac's signal.")
                        case .smartThings:
                            Text("Sends an explicit input source command via SmartThings. Required for Samsung M7/M8 and monitors that don't auto-switch.")
                        }
                    }
                    .font(.caption2)
                    .foregroundColor(.gray)
                    .fixedSize(horizontal: false, vertical: true)
                }

                // ── SmartThings fields (only in SmartThings mode) ──────────
                if monitor.config.monitorMode == .smartThings {
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
                    } else {
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

                        Text("Monitor switches to this input when you gain focus.")
                            .font(.caption2)
                            .foregroundColor(.gray)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

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
