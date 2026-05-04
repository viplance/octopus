/**
 * Drop-in replacement for network.js with latency instrumentation.
 *
 * Usage — replace `require('./network')` with `require('./network-instrumented')`
 * in index.js, OR use index-instrumented.js directly:
 *
 *   node index-instrumented.js
 *
 * Logs every sent/received event with a high-resolution timestamp so you can
 * measure: send time → receive time, serialisation overhead, socket backpressure.
 *
 * Log file is written to ./diag-logs/network-<timestamp>.log
 */

'use strict';

const net    = require('net');
const os     = require('os');
const fs     = require('fs');
const path   = require('path');
const { Bonjour } = require('bonjour-service');

const LOG_DIR = path.join(__dirname, 'diag-logs');
fs.mkdirSync(LOG_DIR, { recursive: true });

const logPath  = path.join(LOG_DIR, `network-${Date.now()}.log`);
const logStream = fs.createWriteStream(logPath, { flags: 'a' });

let seqSend = 0;  // monotonic counter attached to each sent event
let seqRecv = 0;

// High-resolution wall-clock: ms with sub-ms decimal
function hrNow() {
  const [s, ns] = process.hrtime();
  return Date.now() + (ns % 1e6) / 1e6;  // ms, sub-ms precision from hrtime
}

function logLine(tag, obj) {
  const ts   = hrNow();
  const line = JSON.stringify({ ts, tag, ...obj }) + '\n';
  logStream.write(line);
}

function consoleAndLog(msg) {
  console.log(msg);
  logStream.write(`{"ts":${hrNow()},"tag":"INFO","msg":${JSON.stringify(msg)}}\n`);
}

// Print running stats to stdout periodically
function startStatsReporter(getRtts) {
  setInterval(() => {
    const rtts = getRtts();
    if (rtts.length < 2) return;
    const sorted = [...rtts].sort((a, b) => a - b);
    const p50 = sorted[Math.floor(sorted.length * 0.50)];
    const p95 = sorted[Math.floor(sorted.length * 0.95)];
    const p99 = sorted[Math.floor(sorted.length * 0.99)];
    const max = sorted[sorted.length - 1];
    console.log(
      `[STATS] events=${rtts.length} ` +
      `p50=${p50?.toFixed(1)}ms p95=${p95?.toFixed(1)}ms p99=${p99?.toFixed(1)}ms max=${max?.toFixed(1)}ms`
    );
  }, 5000).unref();
}

class NetworkManager {
  constructor(onEventReceived, onClientConnected, onClientDisconnected) {
    this.onEventReceived        = onEventReceived;
    this.onClientConnected      = onClientConnected;
    this.onClientDisconnected   = onClientDisconnected;
    this.server                 = null;
    this.client                 = null;
    this.bonjour                = new Bonjour();
    this.port                   = 8124;
    this.serviceName            = os.hostname().replace(/\.local$/, '');
    this._eventRtts             = [];   // send→recv delta (rough)
    this._sendTimestamps        = new Map(); // seq → hrNow()

    startStatsReporter(() => this._eventRtts);

    consoleAndLog(`[DIAG] Network instrumented. Log → ${logPath}`);
  }

  startServer() {
    this.server = net.createServer((socket) => {
      consoleAndLog(`[DIAG] Client connected from: ${socket.remoteAddress}`);
      logLine('CONN', { dir: 'inbound', remote: socket.remoteAddress, family: socket.remoteFamily });

      let remainder = '';

      socket.on('data', (chunk) => {
        const recvAt = hrNow();
        const raw    = chunk.toString('utf8');
        const combined = remainder + raw;
        const lines  = combined.split('\n');
        remainder    = lines.pop();

        for (const line of lines) {
          const trimmed = line.trim();
          if (!trimmed) continue;
          try {
            const event = JSON.parse(trimmed);

            // Decode rawData
            if (typeof event.rawData === 'string') {
              event.rawData = Buffer.from(event.rawData, 'base64');
            }

            // Measure latency if sender attached a _seq + _sentAt
            let latency = null;
            if (event._sentAt != null) {
              latency = recvAt - event._sentAt;
              this._eventRtts.push(latency);
            }

            const payloadBytes = trimmed.length;

            logLine('RECV', {
              seq         : event._seq ?? seqRecv,
              type        : event.type,
              payloadBytes,
              recvAt,
              senderAt    : event._sentAt ?? null,
              latencyMs   : latency !== null ? +latency.toFixed(3) : null,
              rawDataBytes: event.rawData ? event.rawData.length : 0,
            });

            seqRecv++;

            if (latency !== null && latency > 50) {
              console.log(`[DIAG] ⚠  SPIKE recv latency=${latency.toFixed(1)}ms (seq=${event._seq ?? seqRecv})`);
            }

            this.onEventReceived(event);
          } catch (e) {
            logLine('PARSE_ERR', { msg: e.message, raw: trimmed.slice(0, 120) });
          }
        }
      });

      socket.on('end', () => {
        consoleAndLog('[DIAG] Client disconnected from server.');
        logLine('DISCONN', { dir: 'inbound', remote: socket.remoteAddress });
        if (this.onClientDisconnected) this.onClientDisconnected();
      });

      socket.on('error', (err) => {
        consoleAndLog(`[DIAG] Client socket error: ${err.message}`);
        logLine('SOCK_ERR', { dir: 'inbound', msg: err.message, code: err.code });
        if (this.onClientDisconnected) this.onClientDisconnected();
      });
    });

    this.server.listen(this.port, '::', () => {
      consoleAndLog(`[DIAG] Server listening on :: port ${this.port}`);
      this.bonjour.publish({ name: this.serviceName, type: 'octopussync', port: this.port });
      consoleAndLog('[DIAG] Published Bonjour service');
    });
  }

  startDiscovery() {
    consoleAndLog('[DIAG] Searching for other OctopusSync instances...');
    const browser = this.bonjour.find({ type: 'octopussync' });

    browser.on('up', (service) => {
      if (service.name === this.serviceName) return;
      consoleAndLog(`[DIAG] Found service: ${service.name} addresses: ${service.addresses}`);

      let hostsToTry = [];
      for (const ip of service.addresses) {
        if (ip.includes('%')) {
          hostsToTry.push(ip);
        } else if (ip.startsWith('fe80:')) {
          hostsToTry.push(`${ip}%awdl0`);
          hostsToTry.push(`${ip}%en0`);
        } else {
          hostsToTry.push(ip);
        }
      }

      hostsToTry.sort((a, b) => {
        const aw = a.includes('%awdl0');
        const bw = b.includes('%awdl0');
        if (aw && !bw) return -1;
        if (!aw && bw) return 1;
        const av4 = net.isIPv4(a);
        const bv4 = net.isIPv4(b);
        if (av4 && !bv4) return -1;
        if (!av4 && bv4) return 1;
        return 0;
      });

      hostsToTry = [...new Set(hostsToTry)];
      this.connectTo(hostsToTry, service.port);
      browser.stop();
    });
  }

  connectTo(hosts, port) {
    if (!Array.isArray(hosts)) hosts = [hosts];
    if (!hosts.length) {
      consoleAndLog('[DIAG] All connection attempts failed.');
      logLine('CONN_FAIL', { reason: 'exhausted' });
      if (this.onClientDisconnected) this.onClientDisconnected();
      return;
    }

    const host    = hosts.shift();
    const startAt = hrNow();
    consoleAndLog(`[DIAG] Connecting to ${host}:${port}...`);

    const client = net.createConnection({ host, port }, () => {
      const elapsed = hrNow() - startAt;
      consoleAndLog(`[DIAG] Connected to peer via ${host} (took ${elapsed.toFixed(1)}ms)`);
      logLine('CONN', { dir: 'outbound', remote: host, port, connectMs: +elapsed.toFixed(2) });
      this.client = client;
      client.setTimeout(0);
      if (this.onClientConnected) this.onClientConnected();
    });

    client.setTimeout(1500);

    client.on('timeout', () => {
      consoleAndLog(`[DIAG] Connection timeout for ${host}`);
      logLine('CONN_TIMEOUT', { host });
      client.destroy();
    });

    client.on('error', (err) => {
      consoleAndLog(`[DIAG] Connection error for ${host}: ${err.message}`);
      logLine('CONN_ERR', { host, msg: err.message, code: err.code });
    });

    client.on('close', () => {
      if (this.client === client) {
        consoleAndLog('[DIAG] Disconnected from peer.');
        logLine('DISCONN', { dir: 'outbound', remote: host });
        this.client = null;
        if (this.onClientDisconnected) this.onClientDisconnected();
      } else {
        this.connectTo(hosts, port);
      }
    });
  }

  sendEvent(event) {
    if (!this.client || this.client.destroyed) return;

    const sentAt = hrNow();
    const seq    = seqSend++;

    // Attach timing metadata so receiver can measure latency
    event._seq    = seq;
    event._sentAt = sentAt;

    if (event.rawData && Buffer.isBuffer(event.rawData)) {
      event.rawData = event.rawData.toString('base64');
    }

    const serialized = JSON.stringify(event) + '\n';
    const byteLen    = Buffer.byteLength(serialized);

    // Detect socket backpressure
    const writable = this.client.write(serialized);
    if (!writable) {
      consoleAndLog(`[DIAG] ⚠  Socket write buffer full at seq=${seq} — backpressure`);
      logLine('BACKPRESSURE', { seq, byteLen });
    }

    this._sendTimestamps.set(seq, sentAt);

    logLine('SEND', {
      seq,
      type    : event.type,
      byteLen,
      sentAt,
      writable,
    });
  }
}

module.exports = { NetworkManager };
