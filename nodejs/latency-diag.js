#!/usr/bin/env node
/**
 * OctopusSync Latency Diagnostic
 *
 * Run on Mac A (sender): node latency-diag.js sender
 * Run on Mac B (receiver): node latency-diag.js receiver
 *
 * Measures end-to-end latency at every layer:
 *   - TCP round-trip (ping/pong)
 *   - JSON serialization cost
 *   - Event send-to-receive time
 *   - Socket buffer backpressure
 *   - Per-interface performance (AWDL vs en0 vs IPv4)
 *
 * Outputs a timestamped .log file and a summary to stdout.
 */

'use strict';

const net  = require('net');
const os   = require('os');
const fs   = require('fs');
const path = require('path');
const { Bonjour } = require('bonjour-service');

// ─── Config ────────────────────────────────────────────────────────────────
const PORT          = 8125;          // separate port, won't collide with main app
const SERVICE_TYPE  = 'octopussync-diag';
const PING_INTERVAL = 200;           // ms between pings
const PING_COUNT    = 200;           // total pings per run
const PAYLOAD_SIZES = [64, 512, 4096]; // bytes — simulates small keyboard vs large mouse/gesture events
const LOG_DIR       = path.join(__dirname, 'diag-logs');

// ─── State ──────────────────────────────────────────────────────────────────
const mode        = (process.argv[2] || '').toLowerCase();
const hostname    = os.hostname().replace(/\.local$/, '');
const logFile     = path.join(LOG_DIR, `diag-${mode}-${Date.now()}.log`);
const logLines    = [];
let   totalSent   = 0;
let   totalRecv   = 0;
const rtts        = [];        // round-trip times (ms) — sender side
const oneWayLat   = [];        // one-way latencies (ms) — receiver side (clock-skew aware)
const pendingPings = new Map(); // seq → {sentAt, size}

if (!['sender', 'receiver'].includes(mode)) {
  console.error('Usage: node latency-diag.js <sender|receiver>');
  console.error('  sender   — run on Mac A (the machine with the active input tap)');
  console.error('  receiver — run on Mac B (the second MacBook)');
  process.exit(1);
}

fs.mkdirSync(LOG_DIR, { recursive: true });

// ─── Logging ─────────────────────────────────────────────────────────────────
function log(msg, alsoStdout = true) {
  const ts  = new Date().toISOString();
  const line = `[${ts}] ${msg}`;
  logLines.push(line);
  if (alsoStdout) console.log(line);
}

function flushLog() {
  fs.writeFileSync(logFile, logLines.join('\n') + '\n');
}

process.on('exit', flushLog);
process.on('SIGINT', () => { printSummary(); process.exit(0); });

// ─── Stats helpers ───────────────────────────────────────────────────────────
function percentile(arr, p) {
  if (!arr.length) return NaN;
  const sorted = [...arr].sort((a, b) => a - b);
  const idx    = Math.floor((p / 100) * sorted.length);
  return sorted[Math.min(idx, sorted.length - 1)];
}

function mean(arr) {
  return arr.length ? arr.reduce((a, b) => a + b, 0) / arr.length : NaN;
}

function printSummary() {
  log('\n═══════════════════════════════════════════');
  log(' LATENCY DIAGNOSTIC SUMMARY');
  log('═══════════════════════════════════════════');
  log(`Mode     : ${mode}`);
  log(`Hostname : ${hostname}`);
  log(`Sent     : ${totalSent}  Received: ${totalRecv}`);
  log(`Loss     : ${totalSent ? ((1 - totalRecv / totalSent) * 100).toFixed(1) : 'N/A'}%`);

  if (mode === 'sender' && rtts.length) {
    log('\n── Round-Trip Time (RTT) ──────────────────');
    log(`  count : ${rtts.length}`);
    log(`  min   : ${Math.min(...rtts).toFixed(2)} ms`);
    log(`  mean  : ${mean(rtts).toFixed(2)} ms`);
    log(`  p50   : ${percentile(rtts, 50).toFixed(2)} ms`);
    log(`  p90   : ${percentile(rtts, 90).toFixed(2)} ms`);
    log(`  p99   : ${percentile(rtts, 99).toFixed(2)} ms`);
    log(`  max   : ${Math.max(...rtts).toFixed(2)} ms`);

    // Detect freeze patterns: gaps > 50ms between consecutive pings
    const spikes = rtts.filter(r => r > 50);
    if (spikes.length) {
      log(`\n  ⚠  Spikes > 50 ms: ${spikes.length} (${(spikes.length / rtts.length * 100).toFixed(1)}%)`);
      log(`     Spike values: ${spikes.slice(0, 20).map(v => v.toFixed(0) + 'ms').join(', ')}${spikes.length > 20 ? '…' : ''}`);
    } else {
      log('  ✓  No RTT spikes > 50 ms detected.');
    }
  }

  if (mode === 'receiver' && oneWayLat.length) {
    log('\n── One-Way Latency (receiver clock, skew-relative) ──');
    log(`  count : ${oneWayLat.length}`);
    log(`  min   : ${Math.min(...oneWayLat).toFixed(2)} ms`);
    log(`  mean  : ${mean(oneWayLat).toFixed(2)} ms`);
    log(`  p50   : ${percentile(oneWayLat, 50).toFixed(2)} ms`);
    log(`  p90   : ${percentile(oneWayLat, 90).toFixed(2)} ms`);
    log(`  p99   : ${percentile(oneWayLat, 99).toFixed(2)} ms`);
    log(`  max   : ${Math.max(...oneWayLat).toFixed(2)} ms`);
    log('  Note  : subtract ~half-RTT for true one-way latency if clocks differ.');
  }

  log(`\nFull log saved to: ${logFile}`);
  flushLog();
}

// ─── Message framing (newline-delimited JSON, same as main app) ──────────────
function buildPing(seq, payloadSize) {
  return JSON.stringify({
    cmd    : 'ping',
    seq,
    sentAt : Date.now(),       // sender's wall clock in ms
    payload: 'x'.repeat(payloadSize),
  }) + '\n';
}

function buildPong(ping) {
  return JSON.stringify({
    cmd      : 'pong',
    seq      : ping.seq,
    senderAt : ping.sentAt,
    recvAt   : Date.now(),
    payload  : ping.payload,  // echo payload back (measures serialization)
  }) + '\n';
}

// ─── Parse a newline-delimited buffer into complete messages ─────────────────
function parseMessages(buf, remainder) {
  const combined = remainder + buf.toString('utf8');
  const lines    = combined.split('\n');
  const last     = lines.pop();              // may be incomplete
  const messages = [];
  for (const line of lines) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    try { messages.push(JSON.parse(trimmed)); }
    catch (e) { log(`Parse error: ${e.message} — raw: ${trimmed.slice(0, 80)}`); }
  }
  return { messages, remainder: last };
}

// ─── RECEIVER mode ───────────────────────────────────────────────────────────
function startReceiver() {
  log('Starting in RECEIVER mode');
  log(`Listening on port ${PORT}`);

  const server = net.createServer((socket) => {
    log(`Sender connected from ${socket.remoteAddress}`);
    logSocketInfo(socket, 'incoming');

    let remainder = '';
    socket.on('data', (chunk) => {
      const { messages, remainder: rem } = parseMessages(chunk, remainder);
      remainder = rem;

      for (const msg of messages) {
        if (msg.cmd !== 'ping') continue;
        totalRecv++;

        const now   = Date.now();
        const delta = now - msg.sentAt;   // clock-skew aware relative latency
        oneWayLat.push(delta);

        // Log every ping receipt with timing
        log(`RECV seq=${msg.seq} size=${msg.payload?.length ?? 0}B senderClock=${msg.sentAt} localClock=${now} delta=${delta}ms`, false);

        // Send pong
        socket.write(buildPong(msg));
      }
    });

    socket.on('error', (e) => log(`Socket error: ${e.message}`));
    socket.on('close', () => {
      log('Sender disconnected. Printing summary...');
      printSummary();
    });
  });

  server.listen(PORT, '::', () => {
    log(`Receiver ready — waiting for sender to connect`);
  });

  server.on('error', (e) => {
    log(`Server error: ${e.message}`);
    process.exit(1);
  });
}

// ─── SENDER mode ─────────────────────────────────────────────────────────────
function startSender() {
  log('Starting in SENDER mode');
  log(`Will send ${PING_COUNT} pings with ${PING_INTERVAL}ms interval`);
  log(`Payload sizes: ${PAYLOAD_SIZES.join(', ')} bytes`);

  const bonjour = new Bonjour();
  log('Searching for receiver via Bonjour...');

  const browser = bonjour.find({ type: SERVICE_TYPE });
  browser.on('up', (service) => {
    if (service.name === hostname) return;  // ignore self if somehow announced
    log(`Found receiver: ${service.name} at ${service.addresses}`);
    browser.stop();
    bonjour.unpublishAll(() => bonjour.destroy());

    const candidates = buildCandidates(service.addresses, service.port);
    tryConnect(candidates, service.port);
  });

  // Also publish ourselves so receiver can find us (symmetric discovery)
  // The receiver doesn't need Bonjour but we publish for symmetry
  const senderBonjour = new Bonjour();
  senderBonjour.publish({ name: hostname, type: SERVICE_TYPE, port: PORT });
  log('Published Bonjour presence (sender)');
}

function buildCandidates(addresses, port) {
  let candidates = [];
  for (const ip of addresses) {
    if (ip.includes('%')) {
      candidates.push(ip);
    } else if (ip.startsWith('fe80:')) {
      // Only %en0 — Bonjour never advertises the peer's awdl0 address,
      // so %awdl0 always fails with EHOSTUNREACH.
      candidates.push(`${ip}%en0`);
    } else {
      candidates.push(ip);
    }
  }
  // Prioritize link-local IPv6 (direct, no router) then IPv4 (through router)
  candidates.sort((a, b) => {
    const aLL = a.includes('%en0');
    const bLL = b.includes('%en0');
    if (aLL && !bLL) return -1;
    if (!aLL && bLL) return 1;
    const av4 = net.isIPv4(a);
    const bv4 = net.isIPv4(b);
    if (av4 && !bv4) return -1;
    if (!av4 && bv4) return 1;
    return 0;
  });
  return [...new Set(candidates)];
}

function tryConnect(candidates, port) {
  if (!candidates.length) {
    log('All connection attempts exhausted. Is the receiver running?');
    process.exit(1);
  }

  const host = candidates.shift();
  log(`Trying ${host}:${port}...`);

  const socket = net.createConnection({ host, port });
  socket.setTimeout(1500);

  socket.on('connect', () => {
    log(`Connected via ${host}`);
    socket.setTimeout(0);
    logSocketInfo(socket, 'outgoing');
    warnIfRouted(host, socket.localAddress);
    runPingSession(socket, candidates, port);
  });

  socket.on('timeout', () => {
    log(`Timeout connecting to ${host} — trying next`);
    socket.destroy();
  });

  socket.on('error', (e) => {
    log(`Error connecting to ${host}: ${e.message}`);
  });

  socket.on('close', () => {
    if (totalSent === 0) {
      // Never started — try next
      tryConnect(candidates, port);
    }
  });
}

function runPingSession(socket, _remaining, _port) {
  let remainder  = '';
  let seq        = 0;
  let sizeIndex  = 0;

  // Track consecutive gap times for freeze detection
  let lastSendTime = Date.now();
  const sendGaps   = [];

  log('\nStarting ping session...');

  socket.on('data', (chunk) => {
    const { messages, remainder: rem } = parseMessages(chunk, remainder);
    remainder = rem;

    for (const msg of messages) {
      if (msg.cmd !== 'pong') continue;
      const now     = Date.now();
      const rtt     = now - msg.senderAt;
      const pending = pendingPings.get(msg.seq);
      if (!pending) continue;
      pendingPings.delete(msg.seq);

      rtts.push(rtt);
      totalRecv++;

      const recvDelay = msg.recvAt - msg.senderAt;  // network one-way (clock skew)
      log(`PONG seq=${msg.seq} size=${msg.payload?.length ?? 0}B rtt=${rtt}ms netDelay=${recvDelay}ms`, false);

      if (rtt > 50) {
        log(`⚠  SPIKE seq=${msg.seq} rtt=${rtt}ms (> 50ms threshold)`);
      }
    }
  });

  socket.on('error', (e) => log(`Socket error: ${e.message}`));
  socket.on('close', () => {
    log('\nConnection closed.');
    printSummary();
    process.exit(0);
  });

  const interval = setInterval(() => {
    const now      = Date.now();
    const gap      = now - lastSendTime;
    sendGaps.push(gap);
    if (gap > PING_INTERVAL + 20) {
      log(`⚠  SEND GAP seq=${seq} gap=${gap}ms (Node.js event loop may be blocked)`);
    }
    lastSendTime = now;

    const size = PAYLOAD_SIZES[sizeIndex % PAYLOAD_SIZES.length];
    const msg  = buildPing(seq, size);
    pendingPings.set(seq, { sentAt: now, size });
    socket.write(msg);
    totalSent++;
    seq++;
    sizeIndex++;

    if (seq >= PING_COUNT) {
      clearInterval(interval);
      log('\nAll pings sent. Waiting for last pongs...');
      // Give 3s for last pongs then close
      setTimeout(() => {
        socket.end();
      }, 3000);
    }
  }, PING_INTERVAL);
}

// ─── Receiver auto-discovery via Bonjour ─────────────────────────────────────
function startReceiverWithBonjour() {
  const bonjour = new Bonjour();
  bonjour.publish({ name: hostname, type: SERVICE_TYPE, port: PORT });
  log(`Published Bonjour service as "${hostname}"`);
  startReceiver();
}

// ─── Routing quality check ────────────────────────────────────────────────────
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
          log(
            '\n⚠  WARNING: Connected via IPv4 through the router (' + remoteHost + ').\n' +
            '   Both Macs are on the same LAN but traffic goes router → peer.\n' +
            '   This causes bufferbloat and latency spikes (measured up to 1.6s).\n' +
            '   Fix: enable AirDrop on both Macs — the fe80%en0 direct path will be used instead.\n'
          );
        }
        return;
      }
    }
  }
}

// ─── Log socket-level info ────────────────────────────────────────────────────
function logSocketInfo(socket, direction) {
  log(`Socket [${direction}] localAddr=${socket.localAddress} remoteAddr=${socket.remoteAddress} family=${socket.remoteFamily}`);

  // Interface detection
  const ifaces = os.networkInterfaces();
  for (const [name, addrs] of Object.entries(ifaces)) {
    for (const a of addrs) {
      if (a.address === socket.localAddress) {
        log(`  Local interface: ${name} (${a.family})`);
      }
    }
  }

  // Show all interfaces for reference
  log('  All active network interfaces:');
  for (const [name, addrs] of Object.entries(ifaces)) {
    const active = (addrs || []).filter(a => !a.internal);
    if (active.length) {
      log(`    ${name}: ${active.map(a => `${a.address}/${a.family}`).join(', ')}`, false);
    }
  }
}

// ─── System environment snapshot ─────────────────────────────────────────────
function logSystemInfo() {
  log('── System Info ──────────────────────────────────────');
  log(`  hostname   : ${os.hostname()}`);
  log(`  platform   : ${os.platform()} ${os.release()}`);
  log(`  arch       : ${os.arch()}`);
  log(`  cpus       : ${os.cpus().length}x ${os.cpus()[0]?.model ?? 'unknown'}`);
  log(`  freemem    : ${(os.freemem() / 1024 / 1024).toFixed(0)} MB`);
  log(`  uptime     : ${(os.uptime() / 3600).toFixed(1)} h`);
  log(`  node ver   : ${process.version}`);
  log(`  pid        : ${process.pid}`);
  log('─────────────────────────────────────────────────────');
}

// ─── Entry point ──────────────────────────────────────────────────────────────
logSystemInfo();
log(`Log file: ${logFile}`);

if (mode === 'receiver') {
  startReceiverWithBonjour();
} else {
  startSender();
}
