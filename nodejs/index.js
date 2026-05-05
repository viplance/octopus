const bindings = require('bindings');
const addon = bindings('octopussync_mac');
const { NetworkManager } = require('./network');
const { MonitorManager } = require('./monitor');
const readline = require('readline');

class DeviceManager {
  constructor() {
    this.devices = [];
  }

  refreshDevices() {
    const hidDevices = addon.getDevices();
    const newDevices = [];
    const seen = new Set();
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

module.exports = { DeviceManager };

if (require.main === module) {
  const rl = readline.createInterface({
    input: process.stdin,
    output: process.stdout,
  });

  const ask = (q) => new Promise((res) => rl.question(q, (a) => res(a.trim())));

  (async () => {
    console.log('─── OctopusSync Node.js ───');

    // ── Devices ────────────────────────────────────────────────────────────
    const manager = new DeviceManager();
    const devices = manager.refreshDevices();
    console.log(`\nFound ${devices.length} HID Devices:`);
    console.table(devices);

    // ── Shortcut ───────────────────────────────────────────────────────────
    console.log('\nSelect the shortcut to toggle OctopusSync:');
    console.log('1) Eject Key (Default)');
    console.log('2) Cmd + Option + E');
    const shortcutAnswer = await ask('Choice (1 or 2, press Enter for 1): ');
    // C++ Addon: 1 = Cmd+Option+E, 2 = Eject
    const shortcutChoice = shortcutAnswer === '2' ? 1 : 2;
    addon.setShortcut(shortcutChoice);

    // ── Monitor switch setup ───────────────────────────────────────────────
    const monitorManager = new MonitorManager();

    if (monitorManager.isEnabled) {
      console.log(`\nMonitor switch: enabled (source: ${monitorManager.config.myInputSource})`);
      const reconfigure = await ask('Reconfigure monitor switch? (y/N): ');
      if (reconfigure.toLowerCase() === 'y') {
        await monitorManager.setup(rl);
      }
    } else {
      console.log('\n─── Monitor Switch (Samsung M7/M8 via SmartThings) ───');
      console.log('When you toggle OctopusSync ON, the monitor can automatically');
      console.log('switch its input source to this Mac.\n');
      const wantMonitor = await ask('Set up monitor switching? (y/N): ');
      if (wantMonitor.toLowerCase() === 'y') {
        await monitorManager.setup(rl);
      } else {
        console.log('Skipping monitor switch setup. Run again to set it up later.');
      }
    }

    rl.close();

    startApplication(shortcutChoice, monitorManager);
  })();
}

function startApplication(shortcutChoice, monitorManager) {
  console.log('\n─── Setup Network & Input ───');
  let isIntercepting = false;

  // The monitor must always show the Mac that owns the shared input. Each Mac
  // tracks its own isIntercepting and switches the monitor locally when it
  // becomes the owner. The receiver never touches the monitor — that avoided
  // the cross-talk that caused the old gainFocus/fallback dance to flap.

  const network = new NetworkManager(
    (event) => {
      addon.injectEvent(event);
    },
    () => {
      const shortcutLabel = shortcutChoice === 2 ? 'Eject' : 'Cmd + Option + E';
      console.log(`Network connected! Press ${shortcutLabel} to toggle sync.`);
      if (monitorManager.isEnabled) {
        console.log(`Monitor switch enabled — source: ${monitorManager.config.myInputSource}`);
      }
    },
    () => {
      console.log('\nNetwork connection lost.');
      if (isIntercepting) {
        console.log('Returning keyboard and mouse control back to the local Mac.');
        isIntercepting = false;
        addon.setIntercepting(false);
      }
      // Whether or not we were intercepting, this Mac now owns its own input
      // again, so make sure the monitor shows us. Fire-and-forget — the
      // reconnect timer below shouldn't wait on SmartThings.
      monitorManager.switchToThisMac();
      console.log('Attempting to reconnect...');
      setTimeout(() => {
        network.startDiscovery();
      }, 2000);
    }
  );

  network.startServer();
  network.startDiscovery();

  addon.startTap((type, event) => {
    if (type === 'toggle') {
      isIntercepting = event;
      console.log(`\nSync is now ${isIntercepting ? 'ACTIVE (Inputs intercepted)' : 'INACTIVE (Inputs normal)'}`);
      // In both directions this Mac is now the input owner: when turning sync
      // ON we just grabbed the keyboard/mouse, when turning OFF we just
      // released them back to ourselves. Either way, the monitor should show
      // us. Fire-and-forget to keep the input pipe responsive.
      monitorManager.switchToThisMac();
    } else if (type === 'event') {
      network.sendEvent(event);
    }
  }, true, true);

  console.log('Note: To intercept events, ensure your terminal has Accessibility permissions in System Settings -> Privacy & Security.');
  console.log('Waiting for peer connections via Bonjour...');
}
