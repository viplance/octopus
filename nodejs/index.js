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
  console.log('1) Eject Key (Default)');
  console.log('2) Cmd + Option + E');
  rl.question('Choice (1 or 2, press Enter for 1): ', (answer) => {
    rl.close();
    // In C++ Addon: 1 = Cmd+Option+E, 2 = Eject
    const choice = answer.trim() === '2' ? 1 : 2;
    addon.setShortcut(choice);
    // We share all by default since per-device filtering is not possible
    startApplication(choice, true, true);
  });
}

function startApplication(shortcutChoice, shareKeyboard, shareMouse) {
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
    } else if (type === 'event') {
      network.sendEvent(event);
    }
  }, shareKeyboard, shareMouse);

  console.log('Note: To intercept events, ensure your terminal has Accessibility permissions in System Settings -> Privacy & Security.');
  console.log('Waiting for peer connections via Bonjour...');
}
