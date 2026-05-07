/**
 * MonitorManager — monitor input switching with two modes:
 *
 * Mode 1 — Direct (default):
 *   Relies on the monitor's built-in auto-switch behaviour. When this Mac
 *   gives focus to the peer it sleeps its own external display output so the
 *   monitor sees the peer's signal as the only active one and switches
 *   automatically. No cloud account required.
 *   Requires: macOS `pmset` (pre-installed).
 *
 * Mode 2 — Samsung SmartThings:
 *   Sends an explicit setInputSource command to a Samsung M7/M8 via the
 *   SmartThings cloud REST API. Use this when auto-switch is unreliable or
 *   the monitor does not auto-switch on signal loss.
 *   Requires: SmartThings Personal Access Token + device ID.
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

// ── Direct mode: native display sleep/wake ────────────────────────────────────

const { execFile } = require('child_process');

/**
 * Sleep all external displays on this Mac so the monitor auto-switches to the
 * peer's active signal. Uses `pmset displaysleepnow` which puts the display
 * into DPMS standby — the monitor sees no signal and switches to the other
 * input that is still active.
 *
 * Note: the internal MacBook display (if open) is unaffected — only external
 * displays go dark because pmset targets display power, not backlight.
 */
function sleepExternalDisplay() {
  return new Promise((resolve) => {
    execFile('pmset', ['displaysleepnow'], (err) => {
      if (err) console.error('Direct mode: could not sleep display:', err.message);
      resolve();
    });
  });
}

/**
 * Wake external displays by simulating a tiny mouse nudge via osascript.
 * This is the most reliable cross-version way to wake a sleeping display
 * without requiring additional tools.
 */
function wakeExternalDisplay() {
  return new Promise((resolve) => {
    // Moving the mouse 1 pixel and back wakes the display reliably
    const script = `
      tell application "System Events"
        set mp to position of mouse
        set x to item 1 of mp
        set y to item 2 of mp
        set position of mouse to {x + 1, y}
        delay 0.05
        set position of mouse to {x, y}
      end tell
    `;
    execFile('osascript', ['-e', script], (err) => {
      if (err) console.error('Direct mode: could not wake display:', err.message);
      resolve();
    });
  });
}

// 401 means the SmartThings token is invalid or expired — retrying won't help.
function isAuthError(err) {
  return err instanceof HttpError && err.status === 401;
}

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
      if (isAuthError(e)) throw new Error('SmartThings token is invalid or expired. Generate a new token at https://account.smartthings.com/tokens and run monitor setup again.');
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
      if (isAuthError(e)) throw new Error('SmartThings token is invalid or expired. Generate a new token at https://account.smartthings.com/tokens and run monitor setup again.');
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
      if (isAuthError(e) || e.message.includes('token is invalid or expired')) throw e;
      lastErr = e;
    }
    if (attempt < attempts) {
      await sleep(500 * Math.pow(3, attempt - 1)); // 500ms, 1.5s
    }
  }
  throw new Error(`setInputSource "${source}" failed after ${attempts} attempts: ${lastErr ? lastErr.message : 'unknown'}`);
}

// ── Interactive setup ─────────────────────────────────────────────────────────

async function setupSmartThingsInteractive(rl) {
  const ask = (q) => new Promise((res) => rl.question(q, (a) => res(a.trim())));

  console.log('\n─── Monitor Switch Setup — Samsung SmartThings ───');
  console.log('Prerequisite: your monitor must be added to SmartThings (phone app).');
  console.log('Get a free Personal Access Token at: https://account.smartthings.com/tokens\n');

  const token = await ask('SmartThings Personal Access Token: ');
  if (!token) {
    console.log('No token entered — skipping SmartThings setup.');
    return null;
  }

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
    console.log('No device selected — skipping SmartThings setup.');
    return null;
  }

  console.log('\nFetching supported input sources from monitor...');
  let sources = ['HDMI1', 'HDMI2', 'USB-C'];
  try {
    sources = await fetchSupportedInputSources(token, deviceId);
    console.log('  Supported sources:', sources.join(', '));
  } catch (e) {
    console.log('  Could not fetch sources, using defaults:', sources.join(', '));
  }

  console.log('\nWhich input is THIS Mac connected to on the monitor?');
  sources.forEach((s, i) => console.log(`  ${i + 1}) ${s}`));
  const srcChoice = await ask(`Selection (1-${sources.length}): `);
  const srcIdx = parseInt(srcChoice, 10) - 1;
  const myInputSource = sources[srcIdx] || sources[0];

  return { token, deviceId, myInputSource };
}

/**
 * Interactive setup — asks mode first, then mode-specific settings.
 * Returns the final config object (also persisted to disk).
 */
async function setupInteractive(rl) {
  const ask = (q) => new Promise((res) => rl.question(q, (a) => res(a.trim())));

  console.log('\n─── Monitor Switch Setup ───');
  console.log('Select monitor mode:');
  console.log('  1) Direct (default) — relies on monitor auto-switch when signal is lost');
  console.log('     No cloud account needed. Works with most monitors.');
  console.log('  2) Samsung SmartThings — explicitly sets input source via SmartThings API');
  console.log('     Required for monitors that do not auto-switch on signal loss (e.g. Samsung M7/M8).');
  const modeAnswer = await ask('Mode (1 or 2, Enter for 1): ');
  const monitorMode = modeAnswer === '2' ? 'smartthings' : 'direct';

  let cfg = { enabled: true, monitorMode };

  if (monitorMode === 'smartthings') {
    const stCfg = await setupSmartThingsInteractive(rl);
    if (!stCfg) {
      console.log('SmartThings setup cancelled — falling back to Direct mode.');
      cfg.monitorMode = 'direct';
    } else {
      Object.assign(cfg, stCfg);
    }
  } else {
    console.log('\nDirect mode selected.');
    console.log('When you give focus to the peer, this Mac will sleep its display output.');
    console.log('The monitor should auto-switch to the other Mac\'s signal.');
    console.log('When you regain focus, the display will wake automatically.\n');
  }

  saveConfig(cfg);
  console.log(`\nMonitor switch configured (mode: ${cfg.monitorMode}). Config saved to ${CONFIG_PATH}`);
  return cfg;
}

// ── Main exported class ───────────────────────────────────────────────────────

class MonitorManager {
  constructor() {
    this.config = loadConfig();
    this._inflight = null;
    this._lastSwitchAt = 0;
  }

  get monitorMode() {
    return (this.config && this.config.monitorMode) || 'direct';
  }

  get isEnabled() {
    if (!this.config || !this.config.enabled) return false;
    if (this.monitorMode === 'direct') return true;
    // SmartThings requires token + deviceId + source
    return !!(this.config.token && this.config.deviceId && this.config.myInputSource);
  }

  /**
   * Called when THIS Mac gains focus (peer just gave us control).
   * Wake our display so the monitor shows this Mac's signal.
   */
  switchToThisMac() {
    if (!this.isEnabled) return Promise.resolve();
    if (this._inflight) return this._inflight;

    const DEBOUNCE_MS = 5000;
    if (Date.now() - this._lastSwitchAt < DEBOUNCE_MS) return Promise.resolve();

    this._inflight = (async () => {
      try {
        if (this.monitorMode === 'direct') {
          await wakeExternalDisplay();
          console.log('Monitor wake signal sent (Direct mode).');
        } else {
          const { token, deviceId, myInputSource } = this.config;
          await setInputSource(token, deviceId, myInputSource);
          console.log(`Monitor switched to ${myInputSource} (SmartThings mode).`);
        }
        this._lastSwitchAt = Date.now();
      } catch (e) {
        console.error('Monitor switch failed:', e.message);
      } finally {
        this._inflight = null;
      }
    })();
    return this._inflight;
  }

  /**
   * Called when THIS Mac gives focus to the peer.
   * In Direct mode: sleep our display so the monitor auto-switches to peer.
   * In SmartThings mode: the peer will call its own switchToThisMac via gainFocus.
   */
  switchToPeer() {
    if (!this.isEnabled) return Promise.resolve();
    if (this.monitorMode !== 'direct') return Promise.resolve();

    return (async () => {
      try {
        await sleepExternalDisplay();
        console.log('Display sleeping — monitor should auto-switch to peer (Direct mode).');
      } catch (e) {
        console.error('Direct mode sleep failed:', e.message);
      }
    })();
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
