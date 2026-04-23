const net = require('net');
const { Bonjour } = require('bonjour-service');
const os = require('os');

class NetworkManager {
  constructor(onEventReceived, onClientConnected) {
    this.onEventReceived = onEventReceived;
    this.onClientConnected = onClientConnected;
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

      socket.on('end', () => console.log('Client disconnected'));
    });

    this.server.listen(this.port, '0.0.0.0', () => {
      console.log(`Server listening on 0.0.0.0:${this.port}`);
      this.bonjour.publish({ name: this.serviceName, type: 'octopussync', port: this.port });
      console.log('Published Bonjour service');
    });
  }

  startDiscovery() {
    console.log('Searching for other OctopusSync instances...');
    const browser = this.bonjour.find({ type: 'octopussync' });
    
    browser.on('up', (service) => {
      if (service.name === this.serviceName) return; // ignore self
      console.log('Found service:', service.name);
      
      // Prefer IPv4 addresses to avoid IPv6 link-local connection timeouts
      const ipv4 = service.addresses.find(ip => net.isIPv4(ip));
      const targetIp = ipv4 || service.addresses[0];
      
      this.connectTo(targetIp, service.port);
      browser.stop();
    });
  }

  connectTo(host, port) {
    console.log(`Connecting to ${host}:${port}...`);
    this.client = net.createConnection({ host, port }, () => {
      console.log('Connected to peer!');
      if (this.onClientConnected) this.onClientConnected();
    });
    
    this.client.on('error', (err) => {
      console.error('Connection error:', err.message);
    });
    this.client.on('end', () => {
      console.log('Disconnected from peer');
      this.client = null;
    });
  }

  sendEvent(event) {
    if (this.client && !this.client.destroyed) {
      this.client.write(JSON.stringify(event) + '\n');
    }
  }
}

module.exports = { NetworkManager };
