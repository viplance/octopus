/**
 * MonitorManager — Samsung M7/M8 input switching via the SmartThings cloud API.
 *
 * Samsung M7 does NOT support DDC/CI (it runs Tizen TV firmware), so the only
 * programmatic path is the SmartThings REST API via Samsung's cloud.
 *
 * Setup:
 *  1. Add your Samsung M7/M8 to the SmartThings app (phone) via Wi-Fi.
 *  2. Generate a Personal Access Token at https://account.smartthings.com/tokens
 *  3. Run `discoverDevices(token)` or `setupInteractive(rl)` to find your device ID.
 *
 * Config is persisted to ~/.octopussync_monitor.json so you only set it up once.
 */

const https = require('https');
const fs = require('fs');
const os = require('os');
const path = require('path');

const CONFIG_PATH = path.join(os.homedir(), '.octopussync_monitor.json');
const ST_HOST = 'api.smartthings.com';

// ── Config persistence ────────────────────────────────────────────────────────

function loadConfig() {
  try {
    return JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8'));
  } catch {
    return null;
  }
}

function saveConfig(cfg) {
  fs.writeFileSync(CONFIG_PATH, JSON.stringify(cfg, null, 2));
}

// ── Low-level SmartThings HTTP helper ─────────────────────────────────────────

function stRequest(method, path, token, body) {
  return new Promise((resolve, reject) => {
    const payload = body ? JSON.stringify(body) : undefined;
    const options = {
      hostname: ST_HOST,
      path,
      method,
      headers: {
        Authorization: `Bearer ${token}`,
        'Content-Type': 'application/json',
        ...(payload ? { 'Content-Length': Buffer.byteLength(payload) } : {}),
      },
    };

    const req = https.request(options, (res) => {
      let data = '';
      res.on('data', (c) => (data += c));
      res.on('end', () => {
        if (res.statusCode >= 200 && res.statusCode < 300) {
          try { resolve(JSON.parse(data)); } catch { resolve({}); }
        } else {
          reject(new Error(`SmartThings HTTP ${res.statusCode}: ${data.slice(0, 200)}`));
        }
      });
    });

    req.on('error', reject);
    req.setTimeout(10000, () => { req.destroy(new Error('SmartThings request timed out')); });
    if (payload) req.write(payload);
    req.end();
  });
}

// ── Device discovery ──────────────────────────────────────────────────────────

/**
 * Lists all SmartThings devices that expose a media input source capability.
 * Returns an array of { id, name, label }.
 */
async function discoverMonitors(token) {
  const res = await stRequest('GET', '/v1/devices', token);
  const items = res.items || [];
  return items.filter((d) => {
    const components = d.components || [];
    return components.some((c) =>
      (c.capabilities || []).some(
        (cap) => cap.id === 'samsungvd.mediaInputSource' || cap.id === 'mediaInputSource'
      )
    );
  }).map((d) => ({ id: d.deviceId, name: d.name, label: d.label || d.name }));
}

/**
 * Fetches the list of supported input source strings for a given device.
 * Returns e.g. ['HDMI1', 'HDMI2', 'USB-C'] or a sensible default list.
 */
async function fetchSupportedInputSources(token, deviceId) {
  const caps = ['samsungvd.mediaInputSource', 'mediaInputSource'];
  for (const cap of caps) {
    try {
      const status = await stRequest(
        'GET',
        `/v1/devices/${deviceId}/components/main/capabilities/${cap}/status`,
        token
      );
      const src = status.inputSource || status.mediaInputSource || {};
      const supported =
        src.supportedValues || src.supportedInputSources || src.enum || [];
      if (supported.length > 0) return supported;
    } catch {
      // try next capability name
    }
  }
  return ['HDMI1', 'HDMI2', 'USB-C']; // fallback defaults
}

// ── Input source switching ────────────────────────────────────────────────────

/**
 * Sends a setInputSource command. Tries both capability names (Samsung-specific
 * and generic) for maximum firmware compatibility.
 */
async function setInputSource(token, deviceId, source) {
  const caps = ['samsungvd.mediaInputSource', 'mediaInputSource'];
  for (const cap of caps) {
    try {
      await stRequest('POST', `/v1/devices/${deviceId}/commands`, token, {
        commands: [
          {
            component: 'main',
            capability: cap,
            command: 'setInputSource',
            arguments: [source],
          },
        ],
      });
      return; // success
    } catch {
      // try next
    }
  }
  throw new Error(`setInputSource failed for source "${source}" on device ${deviceId}`);
}

// ── Interactive setup ─────────────────────────────────────────────────────────

/**
 * Walks the user through the full monitor setup interactively.
 * Uses the readline interface passed in (already created by the caller).
 * Returns the final config object (also persisted to disk).
 */
async function setupInteractive(rl) {
  const ask = (q) => new Promise((res) => rl.question(q, (a) => res(a.trim())));

  console.log('\n─── Monitor Switch Setup (Samsung M7/M8 via SmartThings) ───');
  console.log('Prerequisite: your monitor must be added to SmartThings (phone app).');
  console.log('Get a free Personal Access Token at: https://account.smartthings.com/tokens\n');

  const token = await ask('SmartThings Personal Access Token: ');
  if (!token) {
    console.log('No token entered — skipping monitor switch setup.');
    return null;
  }

  // Discover monitors automatically
  let deviceId = '';
  console.log('\nSearching for Samsung monitors in your SmartThings account...');
  let monitors = [];
  try {
    monitors = await discoverMonitors(token);
  } catch (e) {
    console.error('  Discovery error:', e.message);
  }

  if (monitors.length === 0) {
    console.log('  No monitors found automatically.');
    console.log('  Enter your Device ID manually (found at account.smartthings.com → Devices):');
    deviceId = await ask('  Device ID: ');
  } else if (monitors.length === 1) {
    deviceId = monitors[0].id;
    console.log(`  Found: ${monitors[0].label} (${deviceId})`);
  } else {
    console.log('  Found multiple devices:');
    monitors.forEach((m, i) => console.log(`  ${i + 1}) ${m.label} — ${m.id}`));
    const choice = await ask(`  Select (1-${monitors.length}): `);
    const idx = parseInt(choice, 10) - 1;
    deviceId = (monitors[idx] || monitors[0]).id;
  }

  if (!deviceId) {
    console.log('No device selected — skipping monitor switch setup.');
    return null;
  }

  // Fetch supported input sources
  console.log('\nFetching supported input sources from monitor...');
  let sources = ['HDMI1', 'HDMI2', 'USB-C'];
  try {
    sources = await fetchSupportedInputSources(token, deviceId);
    console.log('  Supported sources:', sources.join(', '));
  } catch (e) {
    console.log('  Could not fetch sources, using defaults:', sources.join(', '));
  }

  // Ask which input source this Mac is connected to
  console.log('\nWhich input is THIS Mac connected to on the monitor?');
  sources.forEach((s, i) => console.log(`  ${i + 1}) ${s}`));
  const srcChoice = await ask(`Selection (1-${sources.length}): `);
  const srcIdx = parseInt(srcChoice, 10) - 1;
  const myInputSource = sources[srcIdx] || sources[0];

  const cfg = { enabled: true, token, deviceId, myInputSource };
  saveConfig(cfg);

  console.log(`\nMonitor switch configured:`);
  console.log(`  Device : ${deviceId}`);
  console.log(`  Source : ${myInputSource}`);
  console.log(`  Config saved to ${CONFIG_PATH}`);

  return cfg;
}

// ── Main exported class ───────────────────────────────────────────────────────

class MonitorManager {
  constructor() {
    this.config = loadConfig();
  }

  get isEnabled() {
    return !!(
      this.config &&
      this.config.enabled &&
      this.config.token &&
      this.config.deviceId &&
      this.config.myInputSource
    );
  }

  /**
   * Switch the monitor to this Mac's configured input source.
   * Called when this Mac gains input focus (sync toggle ON).
   * Errors are logged but never thrown — monitor switching is best-effort.
   */
  async switchToThisMac() {
    if (!this.isEnabled) return;
    const { token, deviceId, myInputSource } = this.config;
    try {
      await setInputSource(token, deviceId, myInputSource);
      console.log(`Monitor switched to ${myInputSource}`);
    } catch (e) {
      console.error('Monitor switch failed:', e.message);
    }
  }

  /**
   * Run interactive setup and reload config afterward.
   */
  async setup(rl) {
    const cfg = await setupInteractive(rl);
    if (cfg) this.config = cfg;
    return cfg;
  }
}

module.exports = { MonitorManager, discoverMonitors, fetchSupportedInputSources, setInputSource };
