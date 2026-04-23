const bindings = require('bindings');
const addon = bindings('octopussync_mac');
const { NetworkManager } = require('./network');

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
  console.log('--- OctopusSync Node.js ---');
  const manager = new DeviceManager();
  const devices = manager.refreshDevices();
  console.log(`Found ${devices.length} HID Devices:`);
  console.table(devices);

  console.log('\n--- Setup Network & Input ---');
  let isIntercepting = false;
  
  const network = new NetworkManager(
    (event) => {
      // Received event from peer, inject it into the local system
      addon.injectEvent(event);
    },
    () => {
      console.log('Network connected! Press Cmd + Option + E to toggle sync.');
    }
  );

  network.startServer();
  network.startDiscovery();

  addon.startTap((type, event) => {
    if (type === 'toggle') {
      isIntercepting = event;
      console.log(`\nSync is now ${isIntercepting ? 'ACTIVE (Inputs intercepted)' : 'INACTIVE (Inputs normal)'}`);
    } else if (type === 'event') {
      // Intercepted a local event, send it to the peer
      network.sendEvent(event);
    }
  });

  console.log('Note: To intercept events, ensure your terminal has Accessibility permissions in System Settings -> Privacy & Security.');
  console.log('Waiting for peer connections via Bonjour...');
}
