import { mkdir, rm, cp, writeFile, chmod, access } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { spawn, execSync } from "node:child_process";

const __dirname = dirname(fileURLToPath(import.meta.url));
const root = resolve(__dirname, "..");
const appName = "OctopusSync";
const buildDir = join(root, "build");
const appBundle = join(buildDir, `${appName}.app`);
const appContents = join(appBundle, "Contents");
const macOSDir = join(appContents, "MacOS");
const resourcesDir = join(appContents, "Resources");
const swiftBinary = join(root, ".build", "release", appName);

function run(command, args, options = {}) {
  return new Promise((res, rej) => {
    const child = spawn(command, args, { cwd: root, stdio: "inherit", ...options });
    child.on("exit", (code) => (code === 0 ? res() : rej(new Error(`${command} ${args.join(" ")} exited ${code}`))));
    child.on("error", rej);
  });
}

function buildInfoPlist() {
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key>
  <string>${appName}</string>
  <key>CFBundleExecutable</key>
  <string>${appName}</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIdentifier</key>
  <string>enotix.OctopusSync</string>
  <key>CFBundleName</key>
  <string>${appName}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSLocalNetworkUsageDescription</key>
  <string>OctopusSync uses the local network to discover and connect to the peer Mac.</string>
  <key>NSBonjourServices</key>
  <array>
    <string>_octopussync._tcp</string>
  </array>
</dict>
</plist>
`;
}

console.log("Cleaning build dir...");
await rm(buildDir, { recursive: true, force: true });

console.log("Building Swift release binary...");
await run("swift", ["build", "-c", "release"]);

console.log("Assembling app bundle...");
await mkdir(macOSDir, { recursive: true });
await mkdir(resourcesDir, { recursive: true });

await cp(swiftBinary, join(macOSDir, appName));
await chmod(join(macOSDir, appName), 0o755);

// App icon
try {
  await access(join(root, "assets", "AppIcon.icns"));
  await cp(join(root, "assets", "AppIcon.icns"), join(resourcesDir, "AppIcon.icns"));
} catch {
  console.warn("Warning: assets/AppIcon.icns not found, building without app icon.");
}

// Menu bar icon (used by MenuBarExtra via image: "MenuBarIcon")
// SPM copies resources into the bundle but SwiftUI's image: init looks in the
// main bundle by name, so we place them directly in Resources/.
try {
  await cp(join(root, "assets", "MenuBarIcon.png"), join(resourcesDir, "MenuBarIcon.png"));
  await cp(join(root, "assets", "MenuBarIcon@2x.png"), join(resourcesDir, "MenuBarIcon@2x.png"));
} catch {
  console.warn("Warning: MenuBarIcon assets not found.");
}

await writeFile(join(appContents, "Info.plist"), buildInfoPlist(), "utf8");

// Sign with a stable identity so TCC grants (Accessibility, Input Monitoring)
// survive rebuilds. Priority:
//   1. Apple Development cert (if logged in to Xcode with Apple ID)
//   2. Local self-signed cert named "OctopusSync" (created once, reused forever)
//   3. Ad-hoc fallback (TCC resets every rebuild — last resort)

const SELF_SIGNED_NAME = "OctopusSync-codesign";

function findUsableCert(pattern) {
  try {
    const output = execSync("security find-identity -v -p codesigning", { stdio: "pipe" }).toString();
    const certs = [...output.matchAll(new RegExp(`"(${pattern}[^"]*)"`, "g"))].map(m => m[1]);
    for (const cert of certs) {
      try {
        execSync(`codesign --force --deep --sign "${cert}" "${appBundle}"`, { stdio: "pipe" });
        return cert;
      } catch {
        // not usable on this machine, try next
      }
    }
  } catch { /* security not available */ }
  return null;
}

function createSelfSignedCert() {
  // Creates a self-signed code-signing cert in the login keychain.
  // This only needs to happen once per machine.
  console.log(`Creating self-signed certificate "${SELF_SIGNED_NAME}"...`);
  const script = `
    tell application "Keychain Access" to activate
  `;
  // Use security's built-in cert creation via python/expect is complex;
  // use the Certificate Assistant via command line instead.
  execSync([
    "security", "create-keychain-cert",
    "-k", `${process.env.HOME}/Library/Keychains/login.keychain-db`,
    "-c", SELF_SIGNED_NAME,
    "-C", "1",   // code signing
    "-s",        // self-signed
    "-a", "rsa", "-b", "2048",
    "-Z", "sha256",
    "-e", "always",
  ].join(" "), { stdio: "pipe" });
}

let signed = false;

// 1. Try Apple Development cert
const appleDevCert = findUsableCert("Apple Development:");
if (appleDevCert) {
  console.log(`Signed with: ${appleDevCert}`);
  signed = true;
}

// 2. Try or create self-signed cert
if (!signed) {
  let selfSigned = findUsableCert(SELF_SIGNED_NAME);
  if (!selfSigned) {
    try {
      // Create it using a Python one-liner via security + openssl
      execSync([
        `security create-certificate`,
      ].join(" "), { stdio: "pipe" });
    } catch { /* ignore, fallback below */ }

    // Most reliable: use openssl + security import
    try {
      const tmpKey = `/tmp/${SELF_SIGNED_NAME}.key`;
      const tmpCert = `/tmp/${SELF_SIGNED_NAME}.pem`;
      const tmpP12 = `/tmp/${SELF_SIGNED_NAME}.p12`;
      execSync(`openssl req -newkey rsa:2048 -nodes -keyout "${tmpKey}" -x509 -days 3650 -out "${tmpCert}" -subj "/CN=${SELF_SIGNED_NAME}/O=OctopusSync"`, { stdio: "pipe" });
      execSync(`openssl pkcs12 -export -out "${tmpP12}" -inkey "${tmpKey}" -in "${tmpCert}" -passout pass:`, { stdio: "pipe" });
      execSync(`security import "${tmpP12}" -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign -P "" 2>/dev/null || true`, { stdio: "pipe" });
      // Mark as trusted for code signing
      execSync(`security add-trusted-cert -d -r trustRoot -k ~/Library/Keychains/login.keychain-db "${tmpCert}" 2>/dev/null || true`, { stdio: "pipe" });
      execSync(`rm -f "${tmpKey}" "${tmpCert}" "${tmpP12}"`, { stdio: "pipe" });
      selfSigned = findUsableCert(SELF_SIGNED_NAME);
    } catch (e) {
      // openssl not available or import failed
    }
  }

  if (selfSigned) {
    console.log(`Signed with self-signed certificate: ${selfSigned}`);
    signed = true;
  }
}

// 3. Ad-hoc fallback
if (!signed) {
  console.log("No usable certificate found — using ad-hoc signature.");
  console.log("Note: Accessibility permission must be re-granted after each rebuild.");
  await run("codesign", ["--force", "--deep", "--sign", "-", appBundle]);
}

console.log(`Done. App bundle: ${appBundle}`);
