const bindings = require('bindings');
const addon = bindings('octopussync_mac');
const { NetworkManager } = require('./network');
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
    output: process.stdout
  });

  console.log('--- OctopusSync Node.js ---');
  const manager = new DeviceManager();
  const devices = manager.refreshDevices();
  console.log(`Found ${devices.length} HID Devices:`);
  console.table(devices);

  console.log('\nSelect the shortcut to toggle OctopusSync:');
  console.log('1) Cmd + Option + E (Recommended)');
  console.log('2) Eject Key');
  rl.question('Choice (1 or 2): ', (answer) => {
    rl.close();
    const choice = answer.trim() === '2' ? 2 : 1;
    addon.setShortcut(choice);
    startApplication(choice);
  });
}

function startApplication(shortcutChoice) {
  console.log('\n--- Setup Network & Input ---');
  let isIntercepting = false;
  
  const network = new NetworkManager(
    (event) => {
      addon.injectEvent(event);
    },
    () => {
      console.log(`Network connected! Press ${shortcutChoice === 2 ? 'Eject' : 'Cmd + Option + E'} to toggle sync.`);
    },
    () => {
      console.log('\nNetwork connection lost.');
      if (isIntercepting) {
        console.log('Returning keyboard and mouse control back to the local Mac.');
        isIntercepting = false;
        addon.setIntercepting(false);
      }
    }
  );

  network.startServer();
  network.startDiscovery();

  addon.startTap((type, event) => {
    if (type === 'toggle') {
      isIntercepting = event;
      console.log(`\nSync is now ${isIntercepting ? 'ACTIVE (Inputs intercepted)' : 'INACTIVE (Inputs normal)'}`);
    } else if (type === 'event') {
      network.sendEvent(event);
    }
  });

  console.log('Note: To intercept events, ensure your terminal has Accessibility permissions in System Settings -> Privacy & Security.');
  console.log('Waiting for peer connections via Bonjour...');
}
