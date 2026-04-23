const net = require('net');
const { Bonjour } = require('bonjour-service');
const os = require('os');

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
      // We append %awdl0 (Wi-Fi Direct/AirDrop) and %en0 (Wi-Fi) to ensure routing works.
      for (const ip of service.addresses) {
        if (ip.includes('%')) {
          hostsToTry.push(ip);
        } else if (ip.startsWith('fe80:')) {
          hostsToTry.push(`${ip}%awdl0`); // Peer-to-Peer
          hostsToTry.push(`${ip}%en0`);   // Standard Wi-Fi
        } else {
          hostsToTry.push(ip); // IPv4 or global IPv6
        }
      }
      
      // Prioritize AWDL (Wi-Fi Direct) interfaces first, then IPv4, then others
      hostsToTry.sort((a, b) => {
        const aIsAwdl = a.includes('%awdl0');
        const bIsAwdl = b.includes('%awdl0');
        if (aIsAwdl && !bIsAwdl) return -1;
        if (!aIsAwdl && bIsAwdl) return 1;
        
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
      if (this.onClientConnected) this.onClientConnected();
    });
    
    // Set a short timeout for connection attempts (e.g. 1500ms) so we failover quickly
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
      this.client.write(JSON.stringify(event) + '\n');
    }
  }
}

module.exports = { NetworkManager };
