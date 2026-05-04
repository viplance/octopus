const net = require('net');
const { Bonjour } = require('bonjour-service');
const os = require('os');

// Warn when both peers are on the same subnet but connected via a routed IPv4
// address — this means traffic is going through the router instead of directly,
// which adds bufferbloat and causes latency spikes.
function warnIfRouted(remoteHost, localAddr) {
  if (!net.isIPv4(remoteHost)) return; // link-local IPv6 is always direct

  const ifaces = os.networkInterfaces();
  for (const addrs of Object.values(ifaces)) {
    for (const a of (addrs || [])) {
      if (a.family !== 'IPv4' || a.internal) continue;
      if (a.address === localAddr) {
        // Check if remote is in the same /24 subnet (same LAN)
        const localNet  = a.address.split('.').slice(0, 3).join('.');
        const remoteNet = remoteHost.split('.').slice(0, 3).join('.');
        if (localNet === remoteNet) {
          console.warn(
            '\n⚠  WARNING: Connected via IPv4 through the router (' + remoteHost + ').\n' +
            '   Both Macs are on the same LAN but traffic is routed, not direct.\n' +
            '   This causes bufferbloat and latency spikes (up to 1-2 seconds).\n' +
            '   Fix: enable AirDrop on both Macs so the link-local IPv6 path works.\n'
          );
        }
        return;
      }
    }
  }
}

class NetworkManager {
  constructor(onEventReceived, onClientConnected, onClientDisconnected) {
    this.onEventReceived = onEventReceived;
    this.onClientConnected = onClientConnected;
    this.onClientDisconnected = onClientDisconnected;
    this.server = null;
    this.client = null;
    this.bonjour = new Bonjour();
    this.port = 8124;
    this.serviceName = os.hostname().replace(/\.local$/, '');
  }

  startServer() {
    this.server = net.createServer((socket) => {
      console.log('Client connected from:', socket.remoteAddress);
      
      socket.on('data', (data) => {
        try {
          const messages = data.toString().split('\n').filter(m => m);
          for (const msg of messages) {
            const event = JSON.parse(msg);
            if (typeof event.rawData === 'string') {
              event.rawData = Buffer.from(event.rawData, 'base64');
            }
            this.onEventReceived(event);
          }
        } catch (e) { }
      });

      socket.on('end', () => {
        console.log('Client disconnected from server.');
        if (this.onClientDisconnected) this.onClientDisconnected();
      });
      socket.on('error', (err) => {
        console.error('Client socket error:', err.message);
        if (this.onClientDisconnected) this.onClientDisconnected();
      });
    });

    this.server.listen(this.port, '::', () => {
      console.log(`Server listening on :: (all interfaces, including IPv6/AWDL) port ${this.port}`);
      this.bonjour.publish({ name: this.serviceName, type: 'octopussync', port: this.port });
      console.log('Published Bonjour service');
    });
  }

  startDiscovery() {
    console.log('Searching for other OctopusSync instances...');
    const browser = this.bonjour.find({ type: 'octopussync' });

    browser.on('up', (service) => {
      if (service.name === this.serviceName) return; // ignore self
      console.log('Found service:', service.name, 'addresses:', service.addresses);

      let hostsToTry = [];

      // Node.js requires scope IDs for IPv6 link-local (fe80) addresses on macOS.
      // Only %en0 is used — Bonjour never advertises the peer's awdl0 address,
      // so appending %awdl0 always fails with EHOSTUNREACH.
      for (const ip of service.addresses) {
        if (ip.includes('%')) {
          hostsToTry.push(ip);
        } else if (ip.startsWith('fe80:')) {
          hostsToTry.push(`${ip}%en0`); // link-local via Wi-Fi interface
        } else {
          hostsToTry.push(ip); // IPv4 or global IPv6
        }
      }

      // Prioritize link-local IPv6 (direct, no router) then IPv4 (through router)
      hostsToTry.sort((a, b) => {
        const aIsLinkLocal = a.startsWith('fe80:') || a.includes('%en0');
        const bIsLinkLocal = b.startsWith('fe80:') || b.includes('%en0');
        if (aIsLinkLocal && !bIsLinkLocal) return -1;
        if (!aIsLinkLocal && bIsLinkLocal) return 1;

        const aIsV4 = net.isIPv4(a);
        const bIsV4 = net.isIPv4(b);
        if (aIsV4 && !bIsV4) return -1;
        if (!aIsV4 && bIsV4) return 1;

        return 0;
      });

      // Remove duplicates
      hostsToTry = [...new Set(hostsToTry)];

      this.connectTo(hostsToTry, service.port);
      browser.stop();
    });
  }

  connectTo(hosts, port) {
    if (!Array.isArray(hosts)) hosts = [hosts];
    if (hosts.length === 0) {
      console.log('All connection attempts failed.');
      if (this.onClientDisconnected) this.onClientDisconnected();
      return;
    }

    const host = hosts.shift();
    console.log(`Connecting to ${host}:${port}...`);

    const client = net.createConnection({ host, port }, () => {
      console.log(`Connected to peer via ${host}!`);
      this.client = client;
      client.setTimeout(0); // Remove connection timeout
      warnIfRouted(host, client.localAddress);
      if (this.onClientConnected) this.onClientConnected();
    });

    // Set a short timeout for connection attempts so we failover quickly
    client.setTimeout(1500);

    client.on('timeout', () => {
      console.log(`Connection timeout for ${host}`);
      client.destroy(); // This will trigger 'close'
    });

    client.on('error', (err) => {
      console.error(`Connection error for ${host}:`, err.message);
      // 'close' will be emitted automatically after 'error'
    });

    client.on('close', () => {
      if (this.client === client) {
        // We were successfully connected, but now disconnected
        console.log('Disconnected from peer');
        this.client = null;
        if (this.onClientDisconnected) this.onClientDisconnected();
      } else {
        // We never fully connected, try the next address
        this.connectTo(hosts, port);
      }
    });
  }

  sendEvent(event) {
    if (this.client && !this.client.destroyed) {
      if (event.rawData && Buffer.isBuffer(event.rawData)) {
        event.rawData = event.rawData.toString('base64');
      }
      this.client.write(JSON.stringify(event) + '\n');
    }
  }
}

module.exports = { NetworkManager };
