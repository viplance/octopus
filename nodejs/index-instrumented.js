/**
 * Instrumented entry point — identical to index.js but uses network-instrumented.js.
 *
 * Run instead of `node index.js`:
 *   node index-instrumented.js
 *
 * Adds:
 *   - Per-event send/receive timestamps in diag-logs/network-*.log
 *   - Running p50/p95/p99 latency stats printed every 5 seconds
 *   - Socket backpressure detection
 *   - Event-loop lag monitor (catches JS-thread freezes)
 */

'use strict';

const bindings = require('bindings');
const addon    = bindings('octopussync_mac');
const { NetworkManager } = require('./network-instrumented');
const readline = require('readline');

// ─── Event-loop lag monitor ─────────────────────────────────────────────────
// If the Node.js main thread is blocked (GC, heavy JSON, etc.), the setInterval
// will fire late. We log any gap > 20ms so you can correlate with latency spikes.
(function startLagMonitor() {
  let last = Date.now();
  const INTERVAL = 50; // check every 50ms
  setInterval(() => {
    const now = Date.now();
    const lag = now - last - INTERVAL;
    last      = now;
    if (lag > 20) {
      const ts = new Date().toISOString();
      console.log(`[DIAG] ⚠  Event-loop lag: +${lag}ms at ${ts}`);
    }
  }, INTERVAL).unref(); // don't prevent process exit
})();

// ─── Device enumeration (same as index.js) ──────────────────────────────────
class DeviceManager {
  constructor() { this.devices = []; }
  refreshDevices() {
    const hidDevices = addon.getDevices();
    const newDevices = [];
    const seen       = new Set();
    for (const device of hidDevices) {
      const key = `${device.name}-${device.type}`;
      if (!seen.has(key)) {
        seen.add(key);
        newDevices.push({ name: device.name, type: device.type });
      }
    }
    this.devices = newDevices;
    return this.devices;
  }
}

if (require.main === module) {
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });

  console.log('--- OctopusSync Node.js [INSTRUMENTED] ---');
  const manager = new DeviceManager();
  const devices = manager.refreshDevices();
  console.log(`Found ${devices.length} HID Devices:`);
  console.table(devices);

  console.log('\nSelect shortcut:');
  console.log('1) Eject Key (Default)');
  console.log('2) Cmd + Option + E');
  rl.question('Choice (1 or 2, press Enter for 1): ', (answer) => {
    rl.close();
    const choice = answer.trim() === '2' ? 1 : 2;
    addon.setShortcut(choice);
    startApplication(choice, true, true);
  });
}

function startApplication(shortcutChoice, shareKeyboard, shareMouse) {
  console.log('\n--- Setup Network & Input ---');
  let isIntercepting = false;

  const network = new NetworkManager(
    (event) => { addon.injectEvent(event); },
    () => {
      console.log(`Network connected! Press ${shortcutChoice === 2 ? 'Eject' : 'Cmd+Option+E'} to toggle.`);
    },
    () => {
      console.log('\nNetwork connection lost.');
      if (isIntercepting) {
        console.log('Returning control to local Mac.');
        isIntercepting = false;
        addon.setIntercepting(false);
      }
      console.log('Attempting to reconnect...');
      setTimeout(() => network.startDiscovery(), 2000);
    }
  );

  network.startServer();
  network.startDiscovery();

  addon.startTap((type, event) => {
    if (type === 'toggle') {
      isIntercepting = event;
      console.log(`\nSync is now ${isIntercepting ? 'ACTIVE' : 'INACTIVE'}`);
    } else if (type === 'event') {
      network.sendEvent(event);
    }
  }, shareKeyboard, shareMouse);

  console.log('Waiting for peer connections...');
}
