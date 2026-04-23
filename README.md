# OctopusSync

OctopusSync is a cross-device peripheral sharing utility that allows you to seamlessly share a single MacBook's keyboard, mouse, and trackpad with another MacBook over a local network.

## Project Overview

This repository was created to fulfill the goal of setting up two MacBooks on the same Wi-Fi/Ethernet network to share input hardware without physical KVM switches. It implements real-time interception of hardware inputs and replication to a target machine.

We have implemented two parallel versions of this application in this repository:

1. **Swift (Native macOS App)** - Located in the root directory. A full-featured desktop application with a SwiftUI GUI, designed to start automatically and run in the background.
2. **Node.js (Terminal Bot)** - Located in the `/nodejs` directory. A headless CLI implementation utilizing custom C++ N-API Native Addons to interact directly with macOS's low-level hardware APIs.

## Core Features

- **Hardware Discovery:** Automatically detects both internal Apple Trackpads/Keyboards and external Bluetooth peripherals.
- **Zero-Config Networking:** Utilizes Bonjour (mDNS) to instantly find and establish a low-latency connection with the second MacBook.
- **Input Replication:** Uses `CoreGraphics` Event Taps to "swallow" physical actions on the host machine and reproduce them on the target machine.
- **Shortcut Toggle:** Includes a global hotkey toggle to easily switch control between the two MacBooks.

## Getting Started

Choose your preferred implementation to get started:

- **For the Swift macOS App:** Open `OctopusSync.xcodeproj` in Xcode to build and run the native desktop application.
- **For the Node.js CLI:** Navigate to the `/nodejs` directory and see the [Node.js README](./nodejs/README.md) for installation and build instructions.

*Note: Both implementations require explicit `Accessibility` and `Input Monitoring` permissions in macOS System Settings due to their low-level hardware access.*
