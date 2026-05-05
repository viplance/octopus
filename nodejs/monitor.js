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

class HttpError extends Error {
  constructor(status, body) {
    super(`SmartThings HTTP ${status}: ${String(body).slice(0, 200)}`);
    this.status = status;
  }
}

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
          reject(new HttpError(res.statusCode, data));
        }
      });
    });

    req.on('error', reject);
    req.setTimeout(10000, () => { req.destroy(new Error('SmartThings request timed out')); });
    if (payload) req.write(payload);
    req.end();
  });
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// 404/422 mean this capability name is wrong for this device — try the other one.
// Everything else (5xx, network errors, timeouts) is transient and worth retrying.
function isCapabilityMismatch(err) {
  return err instanceof HttpError && (err.status === 404 || err.status === 422);
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

async function fetchStatus(token, deviceId) {
  const caps = ['samsungvd.mediaInputSource', 'mediaInputSource'];
  let lastErr;
  for (const cap of caps) {
    try {
      const status = await stRequest(
        'GET',
        `/v1/devices/${deviceId}/components/main/capabilities/${cap}/status`,
        token
      );
      return { cap, status };
    } catch (e) {
      lastErr = e;
      if (!isCapabilityMismatch(e)) throw e;
    }
  }
  throw lastErr || new Error('No matching mediaInputSource capability');
}

/**
 * Fetches the list of supported input source strings for a given device.
 * Returns e.g. ['HDMI1', 'HDMI2', 'USB-C'] or a sensible default list.
 */
async function fetchSupportedInputSources(token, deviceId) {
  try {
    const { status } = await fetchStatus(token, deviceId);
    const src = status.inputSource || status.mediaInputSource || {};
    const supported = src.supportedValues || src.supportedInputSources || src.enum || [];
    if (supported.length > 0) return supported;
  } catch {
    // fall through to defaults
  }
  return ['HDMI1', 'HDMI2', 'USB-C']; // fallback defaults
}

/**
 * Reads the monitor's currently active input source. Returns null if unknown.
 */
async function getCurrentInputSource(token, deviceId) {
  const { status } = await fetchStatus(token, deviceId);
  const src = status.inputSource || status.mediaInputSource || {};
  return src.value || null;
}

// ── Input source switching ────────────────────────────────────────────────────

/**
 * Sends a setInputSource command once. Tries both capability names (Samsung-
 * specific and generic) — but only falls through on capability-mismatch errors
 * (404/422). Network/timeout/5xx errors propagate so the retry layer can handle
 * them.
 */
async function setInputSourceOnce(token, deviceId, source) {
  const caps = ['samsungvd.mediaInputSource', 'mediaInputSource'];
  let lastErr;
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
      return;
    } catch (e) {
      lastErr = e;
      if (!isCapabilityMismatch(e)) throw e;
    }
  }
  throw lastErr || new Error(`No matching capability for "${source}"`);
}

/**
 * Sends setInputSource with retry + verify. SmartThings cloud is occasionally
 * flaky (5xx, timeouts) and the monitor sometimes accepts the command but
 * fails to actually switch — so we re-read the status afterward and retry if
 * the active source doesn't match.
 */
async function setInputSource(token, deviceId, source, { attempts = 3, verifyDelayMs = 1500 } = {}) {
  let lastErr;
  for (let attempt = 1; attempt <= attempts; attempt++) {
    try {
      await setInputSourceOnce(token, deviceId, source);
      await sleep(verifyDelayMs);
      let current = null;
      try {
        current = await getCurrentInputSource(token, deviceId);
      } catch {
        // verify is best-effort — if we can't read, assume the command stuck
        return;
      }
      if (current === null || current === source) return;
      lastErr = new Error(`monitor reports "${current}", expected "${source}"`);
    } catch (e) {
      lastErr = e;
    }
    if (attempt < attempts) {
      await sleep(500 * Math.pow(3, attempt - 1)); // 500ms, 1.5s
    }
  }
  throw new Error(`setInputSource "${source}" failed after ${attempts} attempts: ${lastErr ? lastErr.message : 'unknown'}`);
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
    this._inflight = null;
    this._lastSwitchAt = 0;
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
   *
   * - Coalesces concurrent calls: while a switch is in flight, additional
   *   calls return the same promise instead of stacking up SmartThings
   *   commands (which the monitor treats as a "stutter").
   * - Debounces: if we just successfully switched within DEBOUNCE_MS, skip.
   * - Best-effort: errors are logged, never thrown.
   */
  switchToThisMac() {
    if (!this.isEnabled) return Promise.resolve();
    if (this._inflight) return this._inflight;

    const DEBOUNCE_MS = 5000;
    if (Date.now() - this._lastSwitchAt < DEBOUNCE_MS) {
      return Promise.resolve();
    }

    const { token, deviceId, myInputSource } = this.config;
    this._inflight = (async () => {
      try {
        await setInputSource(token, deviceId, myInputSource);
        this._lastSwitchAt = Date.now();
        console.log(`Monitor switched to ${myInputSource}`);
      } catch (e) {
        console.error('Monitor switch failed:', e.message);
      } finally {
        this._inflight = null;
      }
    })();
    return this._inflight;
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

module.exports = {
  MonitorManager,
  discoverMonitors,
  fetchSupportedInputSources,
  getCurrentInputSource,
  setInputSource,
};
