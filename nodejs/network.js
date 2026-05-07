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

// ── Length-prefixed framing (matches Swift NWConnection protocol) ─────────────
//
// Each message = 4-byte big-endian uint32 length + JSON payload bytes.
// This is identical to what the Swift app sends/expects so the two
// implementations are wire-compatible.

class FrameParser {
  constructor(onMessage) {
    this._onMessage = onMessage;
    this._buf = Buffer.alloc(0);
  }

  push(chunk) {
    this._buf = Buffer.concat([this._buf, chunk]);
    while (true) {
      if (this._buf.length < 4) break;
      const len = this._buf.readUInt32BE(0);
      if (this._buf.length < 4 + len) break;
      const payload = this._buf.slice(4, 4 + len);
      this._buf = this._buf.slice(4 + len);
      try {
        const event = JSON.parse(payload.toString('utf8'));
        if (typeof event.rawData === 'string') {
          event.rawData = Buffer.from(event.rawData, 'base64');
        }
        this._onMessage(event);
      } catch (e) { /* ignore malformed frames */ }
    }
  }
}

function encodeFrame(event) {
  const copy = { ...event };
  if (copy.rawData && Buffer.isBuffer(copy.rawData)) {
    copy.rawData = copy.rawData.toString('base64');
  }
  const payload = Buffer.from(JSON.stringify(copy), 'utf8');
  const header = Buffer.alloc(4);
  header.writeUInt32BE(payload.length, 0);
  return Buffer.concat([header, payload]);
}

// ── Bonjour service type ──────────────────────────────────────────────────────
//
// Must match the Swift app exactly. Swift uses NWListener.Service with
// type "_octopussync._tcp", so we publish and browse the same type.
// bonjour-service wants the type without the leading underscore and without
// the transport suffix — it adds them automatically.
const BONJOUR_TYPE = 'octopussync';   // bonjour-service publishes as _octopussync._tcp
const SWIFT_BROWSE_TYPE = '_octopussync._tcp'; // what Swift NWBrowser sees

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
      socket.setNoDelay(true);

      const parser = new FrameParser((event) => {
        this.onEventReceived(event);
      });

      socket.on('data', (chunk) => parser.push(chunk));

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
      console.log(`Server listening on port ${this.port}`);
      this.bonjour.publish({ name: this.serviceName, type: BONJOUR_TYPE, port: this.port });
      console.log(`Published Bonjour service "${this.serviceName}" (${BONJOUR_TYPE})`);
    });
  }

  startDiscovery() {
    console.log('Searching for other OctopusSync instances...');
    const browser = this.bonjour.find({ type: BONJOUR_TYPE });

    browser.on('up', (service) => {
      if (service.name === this.serviceName) return; // ignore self
      console.log('Found service:', service.name, 'addresses:', service.addresses);

      let hostsToTry = [];

      for (const ip of service.addresses) {
        if (ip.includes('%')) {
          hostsToTry.push(ip);
        } else if (ip.startsWith('fe80:')) {
          hostsToTry.push(`${ip}%en0`);
        } else {
          hostsToTry.push(ip);
        }
      }

      // Prefer link-local IPv6 (direct, no router) then IPv4
      hostsToTry.sort((a, b) => {
        const aLL = a.startsWith('fe80:') || a.includes('%en0');
        const bLL = b.startsWith('fe80:') || b.includes('%en0');
        if (aLL && !bLL) return -1;
        if (!aLL && bLL) return 1;
        const aV4 = net.isIPv4(a);
        const bV4 = net.isIPv4(b);
        if (aV4 && !bV4) return -1;
        if (!aV4 && bV4) return 1;
        return 0;
      });

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
      client.setTimeout(0);
      client.setNoDelay(true);
      warnIfRouted(host, client.localAddress);
      if (this.onClientConnected) this.onClientConnected();
    });

    client.setTimeout(1500);

    client.on('timeout', () => {
      console.log(`Connection timeout for ${host}`);
      client.destroy();
    });

    client.on('error', (err) => {
      console.error(`Connection error for ${host}:`, err.message);
    });

    client.on('close', () => {
      if (this.client === client) {
        console.log('Disconnected from peer');
        this.client = null;
        if (this.onClientDisconnected) this.onClientDisconnected();
      } else {
        this.connectTo(hosts, port);
      }
    });
  }

  sendEvent(event) {
    if (this.client && !this.client.destroyed) {
      this.client.write(encodeFrame(event));
    }
  }
}

module.exports = { NetworkManager };
