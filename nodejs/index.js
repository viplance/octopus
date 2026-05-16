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
      const modeLabel = monitorManager.monitorMode === 'smartthings'
        ? `SmartThings (source: ${monitorManager.config.myInputSource})`
        : 'Direct';
      console.log(`\nMonitor switch: enabled (mode: ${modeLabel})`);
      const reconfigure = await ask('Reconfigure monitor switch? (y/N): ');
      if (reconfigure.toLowerCase() === 'y') {
        await monitorManager.setup(rl);
      }
    } else {
      console.log('\n─── Monitor Switch ───');
      console.log('When you toggle OctopusSync, the monitor can automatically switch.');
      console.log('Mode 1 (Direct): sleeps this Mac\'s display so the monitor auto-switches.');
      console.log('Mode 2 (SmartThings): sends an explicit input source command via SmartThings.\n');
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
  let isPeerConnected = false;

  // The monitor must always show the Mac that is *receiving* the shared input.
  // - When this Mac toggles ON: send gainFocus to peer (SmartThings mode) OR
  //   sleep our own display (Direct mode) so the monitor auto-switches to peer.
  // - When this Mac toggles OFF or loses connection: wake our display and
  //   switch monitor back to this Mac.
  // - Toggle is blocked when peer is not connected — user sees a clear message.

  const network = new NetworkManager(
    (event) => {
      if (event.control === 'gainFocus') {
        monitorManager.switchToThisMac();
        return;
      }
      // Translate Swift wire format (type 0=mouseMove,1=mouseClick,3=keyDown,4=keyUp,5=raw)
      // to addon format (-3=mouseMove,-4=mouseClick,-2=raw,10/11=key)
      if (event.type === 0) {
        addon.injectEvent({ type: -3, dx: event.dx || 0, dy: event.dy || 0 });
      } else if (event.type === 1) {
        addon.injectEvent({ type: -4, dx: event.dx || 0, dy: event.dy || 0, mouseButton: event.button || 0, isDown: event.isDown !== false });
      } else if (event.type === 3) {
        addon.injectEvent({ type: 10, keycode: event.keyCode || 0, flags: event.flags || 0 });
      } else if (event.type === 4) {
        addon.injectEvent({ type: 11, keycode: event.keyCode || 0, flags: event.flags || 0 });
      } else if (event.type === 5 && event.rawData) {
        addon.injectEvent({ type: -2, rawData: event.rawData });
      } else {
        addon.injectEvent(event);
      }
    },
    () => {
      isPeerConnected = true;
      const shortcutLabel = shortcutChoice === 2 ? 'Eject' : 'Cmd + Option + E';
      console.log(`Network connected! Press ${shortcutLabel} to toggle sync.`);
      if (monitorManager.isEnabled) {
        const modeLabel = monitorManager.monitorMode === 'smartthings' ? 'SmartThings' : 'Direct';
        console.log(`Monitor switch enabled (${modeLabel} mode).`);
      }
    },
    () => {
      isPeerConnected = false;
      console.log('\nConnection lost.');
      if (isIntercepting) {
        // Peer disappeared while we were sending input — return control locally.
        console.log('Returning keyboard and mouse control to this Mac.');
        isIntercepting = false;
        addon.setIntercepting(false);
        // Wake our display so we can see the screen again.
        monitorManager.switchToThisMac();
      }
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
      if (event && !isPeerConnected) {
        // Trying to turn ON but peer is not connected.
        console.log('\nCannot activate sync — peer is not connected (Connection lost).');
        // Ensure the addon reflects the blocked state (no intercepting).
        addon.setIntercepting(false);
        return;
      }

      isIntercepting = event;
      console.log(`\nSync is now ${isIntercepting ? 'ACTIVE (Inputs intercepted)' : 'INACTIVE (Inputs normal)'}`);

      if (isIntercepting) {
        // Giving focus to peer: tell peer to switch monitor (SmartThings mode)
        // and sleep our own display (Direct mode).
        network.sendEvent({ control: 'gainFocus' });
        monitorManager.switchToPeer();
      } else {
        // Regaining focus: wake our display.
        monitorManager.switchToThisMac();
      }
    } else if (type === 'event') {
      network.sendEvent(event);
    }
  }, true, true);

  console.log('Note: To intercept events, ensure your terminal has Accessibility permissions in System Settings -> Privacy & Security.');
  console.log('Waiting for peer connections via Bonjour...');
}
