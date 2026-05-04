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
- `pnpm start:instrumented` — Same as `start` but with per-event latency logging, live p50/p95/p99 stats every 5 seconds, socket backpressure detection, and event-loop lag monitoring. Logs to `diag-logs/network-<timestamp>.log`.
- `pnpm diag:receiver` — Starts the latency diagnostic tool in receiver mode. Run this on the **second MacBook** before running `diag:sender`.
- `pnpm diag:sender` — Runs the latency diagnostic tool in sender mode. Sends 200 ping/pong round-trips (at three payload sizes: 64 B, 512 B, 4096 B) and prints a full RTT report with min/mean/p50/p90/p99/max and spike detection.

## Latency Diagnostics

Two diagnostic scripts are included to identify the source of latency and freezes between the two MacBooks. No native addon is required — they run on any machine with Node.js and `bonjour-service` installed.

### Standalone ping/pong test (no addon needed)

Run on **Mac B** first:
```bash
pnpm diag:receiver
```

Then run on **Mac A**:
```bash
pnpm diag:sender
```

The sender uses Bonjour to discover the receiver automatically. It sends 200 pings at 200 ms intervals across three payload sizes (64 B / 512 B / 4096 B) to simulate keyboard, mouse, and gesture events. At the end it prints a full RTT summary and flags any spike > 50 ms. Logs are saved to `diag-logs/`.

### Live production instrumentation

Run instead of `pnpm start` on either or both Macs:
```bash
pnpm start:instrumented
```

Adds to the normal run:
- Every event timestamped at send and receive with sub-millisecond precision
- Running p50/p95/p99 latency stats printed to stdout every 5 seconds
- Socket write-buffer backpressure warnings
- Event-loop lag monitor — flags any > 20 ms JS thread block (the direct cause of input freezes)

### Reading the results

| Symptom | Likely cause |
|---|---|
| `⚠ WARNING: Connected via IPv4 through the router` | Traffic routed through Wi-Fi router — enable AirDrop on both Macs for a direct link-local path |
| RTT spikes but no send-gap warnings | Network issue (router bufferbloat, Wi-Fi congestion) |
| Send-gap warnings alongside spikes | Node.js event loop blocked (GC, heavy JSON parsing) |
| Backpressure warnings | Too many events queued; socket can't drain fast enough |
| p50 fine, p99 > 100 ms | Intermittent Wi-Fi jitter or router queue buildup |

## Architecture
- `src/addon.mm`: Objective-C++ source that uses `IOHIDManager` and `CGEventTap` to capture and inject macOS input events.
- `binding.gyp`: `node-gyp` build configuration; links `IOKit`, `CoreFoundation`, `Foundation`, `ApplicationServices`, `CoreGraphics`, and `AppKit`.
- `index.js`: Main entry point — device enumeration, shortcut selection, network + tap setup.
- `network.js`: TCP server/client with Bonjour discovery. Prioritises direct link-local IPv6 (`fe80%en0`) over routed IPv4.
- `index-instrumented.js` / `network-instrumented.js`: Drop-in instrumented versions of the above with latency logging.
- `latency-diag.js`: Standalone ping/pong diagnostic — no native addon dependency.
