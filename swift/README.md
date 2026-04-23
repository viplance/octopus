# OctopusSync (macOS Swift App)

OctopusSync is a native macOS utility that allows you to seamlessly share your MacBook's keyboard, mouse, and trackpad with another MacBook over a local Wi-Fi or Ethernet network.

Built entirely in Swift, OctopusSync uses low-level macOS APIs (`IOKit`, `CoreGraphics`) to intercept your physical keystrokes and cursor movements, and beams them over a low-latency network connection to be replicated on the target machine.

## Features

- **Hardware Discovery**: Automatically detects built-in and externally connected Apple Keyboards, Magic Mice, and Magic Trackpads using `IOKit.hid`.
- **Zero-Config Networking**: Uses Apple's Bonjour (mDNS) network discovery to automatically find and connect to other MacBooks running OctopusSync on the same local network.
- **Low-Latency Transmission**: Transmits intercepted input events via standard network sockets for real-time responsiveness.
- **Global Shortcut Toggle**: Instantly switch control between your local Mac and the remote Mac using a global keyboard shortcut.

## Prerequisites

- **macOS**: macOS 10.15+ (Catalina) or later.
- **Xcode**: Required to build the `.xcodeproj`.
- **Permissions**: OctopusSync requires explicit `Accessibility` and `Input Monitoring` permissions to intercept and inject system-wide inputs.

## Setup & Installation

1. Open the project in Xcode:

   ```bash
   open OctopusSync.xcodeproj
   ```

2. Select your Mac as the active build destination in the top toolbar.

3. Click the **Run** button (or press `Cmd + R`) to build and launch the application.

4. **Permissions Configuration**:
   When you first run the application, it will attempt to create an Event Tap. You will be prompted by macOS to grant permissions.
   - Go to **System Settings > Privacy & Security > Accessibility** and toggle on `OctopusSync`.
   - Go to **System Settings > Privacy & Security > Input Monitoring** and toggle on `OctopusSync`.
   - Restart the app.

## Usage

1. Launch OctopusSync on **both** MacBooks. Ensure they are connected to the same Wi-Fi/Local network.
2. The UI will display a list of your discovered HID devices.
3. The Network Manager will automatically discover the other MacBook via Bonjour and establish a peer-to-peer connection.
4. Once connected, press the configured global shortcut to activate **Sync Mode**.
5. Your local inputs will now be intercepted and routed to the second MacBook. Press the shortcut again to return control to your local machine.

## Architecture & Core Files

- `DeviceManager.swift`: Handles querying the `IOHIDManager` to enumerate available HID devices.
- `InputManager.swift`: Manages the `CGEventTap` to intercept global system inputs and uses `CGEventPost` to inject received inputs.
- `NetworkManager.swift`: Handles Bonjour network discovery and low-latency data transmission.
- `ShortcutManager.swift`: Registers global hotkeys for toggling sync mode on and off.
- `AppState.swift` & `ContentView.swift`: Manage the application state and render the SwiftUI user interface.

---

**Note:** An experimental headless Node.js version of this tool is also available. See the `/nodejs/README.md` file for more details.
