# OctopusSync Implementation Plan

## 1. Project Overview
OctopusSync is a macOS application designed to seamlessly share an external Bluetooth keyboard, mouse, or touchpad between two MacBooks over a local network. It fulfills the provided requirements by allowing users to toggle control of a second MacBook using a global keyboard shortcut (default: `Eject`), effectively functioning as a software KVM switch. 

## 2. Technology Stack
*   **Platform:** macOS 13.0+ (Modern macOS)
*   **Language:** Swift 5.x
*   **UI Framework:** SwiftUI (for a lightweight, native GUI)
*   **Networking:** Apple `Network` Framework (`NWBrowser`, `NWListener`, `NWConnection`) for robust, zero-configuration local networking (Wi-Fi, Ethernet) using Bonjour/mDNS.
*   **Input Capture & Injection:**
    *   `IOKit` / `IOHIDManager`: For enumerating connected Bluetooth HID devices and capturing their input selectively.
    *   `CoreGraphics` (`CGEventTap` / `CGEvent`): For simulating/injecting input on the receiving MacBook and optionally capturing global shortcuts.
*   **System Integration:**
    *   `ServiceManagement` (`SMAppService`): For the "start automatically on mac startup" requirement.
    *   `Carbon` or `NSEvent` global monitors: For intercepting the `Eject` shortcut globally.

### 2.1. Xcode Project Configuration
*   **Template:** macOS App.
*   **Background Agent Mode:** The `Info.plist` must include the `Application is agent (UIElement)` (or `LSUIElement`) key set to `YES` to hide the app from the Dock and Application Switcher, ensuring it runs silently in the background.
*   **App Entry Point:** The SwiftUI `@main` struct must use `MenuBarExtra` instead of `WindowGroup` to restrict the UI exclusively to a menu bar dropdown.

## 3. Architecture & Core Modules

### 3.1. Network & Discovery Layer
*   **Discovery:** The app will use Bonjour to broadcast a custom service type (e.g., `_octopussync._tcp`). MacBooks running the app on the same network will discover each other automatically.
*   **Connection:** A direct TCP connection will be established. TCP is chosen over UDP for its reliability, which is crucial for keyboard input, while latency over local Wi-Fi/Ethernet is negligible for smooth mouse reproduction.
*   **Message Protocol:** A lightweight binary or JSON payload defining event type (MouseMove, MouseClick, KeyDown, KeyUp, Scroll) and parameters (X/Y delta, keycode, button state).

### 3.2. Device Detection & Selection
*   The application will use `IOBluetoothDevice` and `IOHIDManager` to fetch a list of connected devices.
*   It will filter for Human Interface Devices (HID) to specifically identify keyboards, mice, and touchpads.
*   These devices will be displayed in the SwiftUI interface for the user to select which ones should be shared.

### 3.3. Input Capture & Routing (The Server)
*   When sharing is **Active**:
    *   The app reads raw input directly from the selected `IOHIDDevice`s.
    *   To prevent the input from moving the cursor/typing on the *local* machine while controlling the remote machine, the app will establish a `CGEventTap` to intercept and suppress events matching the external devices, OR acquire exclusive access via `IOHIDManager`.
    *   Events are serialized and transmitted over the TCP connection.

### 3.4. Input Reproduction (The Client)
*   The receiving instance parses incoming network packets.
*   It reconstructs the actions using `CGEvent(keyboardEventSource:...)` and `CGEvent(mouseEventSource:...)`.
*   It posts the events to the system using `CGEvent.post(tap: .cghidEventTap, ...)`.
*   Note: Mouse movement will be relative (delta X/Y) rather than absolute to ensure smooth scaling across different screen resolutions.

### 3.5. Global Shortcut Management
*   The app must intercept the `Eject` key even when it is not in focus.
*   Since the `Eject` key is a media key, standard `Carbon` hotkeys might not suffice. A `CGEventTap` filtering for `NSSystemDefined` events (subtype 8, which corresponds to media keys including Eject) will be implemented to reliably toggle the active/inactive sharing state.

### 3.6. User Interface (SwiftUI)
*   **App Style:** A Menu Bar Extra (Status Bar app) to remain unobtrusive but easily accessible.
*   **Main View:**
    *   Connection Status: Shows the paired MacBook.
    *   Device List: A dynamic list of Bluetooth keyboards/mice with checkboxes.
    *   Sharing Status: A visual indicator (and manual toggle) of whether inputs are currently being sent to the remote machine.
*   **Preferences/Settings:**
    *   Toggle for "Launch at login".
    *   Customizable shortcut input (allowing changes from the default `Eject` key).

## 4. Security & System Permissions
To function, macOS requires explicit user consent for:
1.  **Accessibility / Input Monitoring:** Essential for `CGEventTap` and `IOHIDManager` to read external hardware input and simulate keystrokes/mouse movements. The app will include a helper function to prompt the user to enable these in System Settings if not already granted.
2.  **Local Network:** Required by macOS to allow the app to discover and connect to other MacBooks via Bonjour.

## 5. Implementation Phases

*   **Phase 1: Project Setup & UI Foundation**
    *   Initialize SwiftUI Xcode project with Menu Bar extra.
    *   Build the settings and device list UI mockups.
*   **Phase 2: Networking & Discovery**
    *   Implement `NWListener` and `NWBrowser`.
    *   Achieve successful connection and test basic message passing between two instances.
*   **Phase 3: Device Enumeration & Event Capture**
    *   Implement `IOHIDManager` to discover Bluetooth HID devices.
    *   Implement event listeners for the specific devices and translate them to generic struct models.
*   **Phase 4: Event Injection & Shortcut**
    *   Implement `CGEvent.post` on the client side.
    *   Implement the `Eject` key interceptor to toggle the networking stream.
*   **Phase 5: Polish & Lifecycle Management**
    *   Implement `SMAppService` for automatic startup.
    *   Add permission verification and prompts.
    *   Testing, latency optimization, and bug fixing.
