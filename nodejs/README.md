# OctopusSync Node.js Module

This is the Node.js implementation of the OctopusSync macOS device manager. It uses a Native C++ Addon (via `node-addon-api`) to tap into the macOS `IOKit` and `CoreFoundation` frameworks. This allows it to correctly enumerate and manage Apple internal hardware (Keyboards, Magic Trackpads, etc.), fully mimicking the functionality of the native Swift implementation.

## Prerequisites
- macOS 10.15+
- Node.js (v14+)
- `pnpm` package manager
- Xcode Command Line Tools (for compiling the C++ addon)

## Setup & Installation

1. Install dependencies:
   ```bash
   pnpm install
   ```

2. Build the native C++ addon:
   ```bash
   pnpm build
   ```

3. Run the application (tests the device enumeration):
   ```bash
   pnpm start
   ```

## Available Commands

- `pnpm install` — Installs required packages (`node-addon-api`, `bindings`, and `node-gyp`).
- `pnpm build` — Runs `node-gyp configure build` to compile the `src/mac_hid.mm` source into a native `.node` binary.
- `pnpm start` — Executes `index.js`, loading the compiled addon and logging the discovered HID devices to the terminal.

## Architecture
- `src/mac_hid.mm`: Objective-C++ source file that leverages macOS `IOHIDManager` to interact with low-level inputs.
- `binding.gyp`: Configuration file that tells the `node-gyp` compiler how to build the addon and link the required Apple frameworks (`IOKit`, `CoreFoundation`, `Foundation`).
- `index.js`: Exposes the `DeviceManager` Node.js class and handles deduplicating the hardware results.
