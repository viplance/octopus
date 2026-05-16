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

            if !appState.isInputMonitoringGranted {
                Button(action: {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    Label("Input Monitoring access required", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
                .buttonStyle(PlainButtonStyle())
                .help("Required for shortcuts and input capture to work")
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

            // ── Shortcut ──────────────────────────────────────────────────────
            ShortcutSectionView(shortcut: appState.shortcutManager)

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
        .onAppear {}
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            appState.networkManager.stop()
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
                    if monitor.config.isMasterForSmartThings {
                        // Master: full configuration, owns all SmartThings requests
                        SmartThingsTokenView(
                            monitor: monitor,
                            automation: monitor.tokenAutomation
                        )

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

                        HStack {
                            Text("My Input:")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text(monitor.config.myInputSource.isEmpty ? "—" : monitor.config.myInputSource)
                                .font(.caption2)
                                .fontWeight(.medium)
                        }

                        HStack {
                            Text("Peer's Input:")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text(monitor.config.peerInputSource.isEmpty
                                 ? "Waiting for peer…"
                                 : monitor.config.peerInputSource)
                                .font(.caption2)
                                .fontWeight(.medium)
                                .foregroundColor(monitor.config.peerInputSource.isEmpty ? .gray : .primary)
                                .italic(monitor.config.peerInputSource.isEmpty)
                        }
                    } else {
                        // Slave: SmartThings managed by master, no local config needed
                        HStack(spacing: 6) {
                            Image(systemName: "link")
                                .font(.caption2)
                                .foregroundColor(.blue)
                            Text("SmartThings managed by master Mac")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }

                        HStack {
                            Text("My Input:")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text(monitor.config.myInputSource.isEmpty ? "Detecting…" : monitor.config.myInputSource)
                                .font(.caption2)
                                .fontWeight(.medium)
                                .foregroundColor(monitor.config.myInputSource.isEmpty ? .gray : .primary)
                                .italic(monitor.config.myInputSource.isEmpty)
                        }
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

// MARK: - Shortcut Section

struct ShortcutSectionView: View {
    @ObservedObject var shortcut: ShortcutManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Toggle Shortcut")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack {
                Button(action: {
                    shortcut.isRecording.toggle()
                }) {
                    Text(shortcut.isRecording ? "Press a key... (Esc to cancel)" : shortcut.config.displayString)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.bordered)
                .foregroundColor(shortcut.isRecording ? .orange : .primary)

                Button(action: {
                    shortcut.isRecording = false
                    shortcut.config = .ejectKey
                }) {
                    Image(systemName: "eject.fill")
                        .font(.caption)
                }
                .help("Use Eject key")
                .disabled(shortcut.config.isEjectKey && !shortcut.isRecording)
            }

            Text("Press this key on either Mac to switch input control. Eject ⏏ is supported.")
                .font(.caption2)
                .foregroundColor(.gray)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - SmartThings Token (manual PAT + Safari auto-refresh)

struct SmartThingsTokenView: View {
    @ObservedObject var monitor: MonitorManager
    @ObservedObject var automation: SmartThingsTokenAutomation

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Auto refresh token", isOn: Binding(
                get: { monitor.config.autoRefreshTokenEnabled },
                set: { monitor.config.autoRefreshTokenEnabled = $0 }
            ))
            .toggleStyle(SwitchToggleStyle(tint: .orange))
            .font(.caption2)

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
                .disabled(monitor.config.autoRefreshTokenEnabled)
            }

            if monitor.config.autoRefreshTokenEnabled {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Google Account (for SSO)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    TextField("optional — leave empty for first listed", text: Binding(
                        get: { monitor.config.googleAccountEmail },
                        set: { monitor.config.googleAccountEmail = $0 }
                    ))
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .font(.caption2)
                }

                HStack {
                    Button(action: { Task { await automation.refreshNow() } }) {
                        HStack(spacing: 4) {
                            if automation.isRunning { ProgressView().scaleEffect(0.6) }
                            Text(automation.isRunning ? "Refreshing…" : "Refresh now")
                        }
                    }
                    .disabled(automation.isRunning)
                    .font(.caption)
                    Spacer()
                }
                statusLine
                Text("Opens Safari at account.smartthings.com/tokens and generates a fresh 24h token. If logged out, signs you in via Google SSO. You must be logged in to Google in Safari.")
                    .font(.caption2)
                    .foregroundColor(.gray)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if automation.isRunning && !automation.lastStep.isEmpty {
            HStack(spacing: 4) {
                ProgressView().scaleEffect(0.5)
                Text("Step: \(automation.lastStep)…")
            }
            .font(.caption2)
            .foregroundColor(.gray)
        } else if let err = automation.lastError {
            VStack(alignment: .leading, spacing: 2) {
                Text(err).font(.caption2).foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
                if !automation.lastStep.isEmpty {
                    Text("Stuck at: \(automation.lastStep)")
                        .font(.caption2).foregroundColor(.orange)
                }
            }
        } else if let issued = monitor.config.tokenIssuedAt {
            let expiry = issued.addingTimeInterval(SmartThingsTokenAutomation.tokenLifetime)
            HStack(spacing: 4) {
                Circle().fill(Color.green).frame(width: 6, height: 6)
                Text(expiryDescription(expiry))
            }
            .font(.caption2)
            .foregroundColor(.gray)
        }
    }

    private func expiryDescription(_ date: Date) -> String {
        let seconds = date.timeIntervalSinceNow
        if seconds <= 0 { return "Token expired — refreshing soon" }
        let hours = Int(seconds / 3600)
        let minutes = Int(seconds.truncatingRemainder(dividingBy: 3600) / 60)
        return hours > 0
            ? "Token expires in \(hours)h \(minutes)m"
            : "Token expires in \(minutes)m"
    }
}
