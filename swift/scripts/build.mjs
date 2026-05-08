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
//   2. Local self-signed cert named "OctopusSync-codesign" (created once, reused forever)
//   3. Ad-hoc fallback (TCC resets every rebuild — last resort)

const SELF_SIGNED_NAME = "OctopusSync-codesign";
const KEYCHAIN = `${process.env.HOME}/Library/Keychains/login.keychain-db`;

function findCertInKeychain(pattern) {
  try {
    const output = execSync("security find-identity -v -p codesigning", { stdio: "pipe" }).toString();
    const matches = [...output.matchAll(new RegExp(`"(${pattern}[^"]*)"`, "g"))].map(m => m[1]);
    return matches[0] ?? null;
  } catch {
    return null;
  }
}

function trySign(certName) {
  try {
    execSync(`codesign --force --deep --sign "${certName}" "${appBundle}"`, { stdio: "pipe" });
    return true;
  } catch {
    return false;
  }
}

function createSelfSignedCert() {
  // The cert must include extendedKeyUsage = codeSigning (OID 1.3.6.1.5.5.7.3.3)
  // otherwise security find-identity -p codesigning won't list it.
  const tmpConf = `/tmp/${SELF_SIGNED_NAME}.conf`;
  const tmpKey  = `/tmp/${SELF_SIGNED_NAME}.key`;
  const tmpCert = `/tmp/${SELF_SIGNED_NAME}.pem`;
  const tmpP12  = `/tmp/${SELF_SIGNED_NAME}.p12`;

  const conf = [
    "[ req ]",
    "default_bits       = 2048",
    "prompt             = no",
    "default_md         = sha256",
    "distinguished_name = dn",
    "x509_extensions    = v3_cs",
    "",
    "[ dn ]",
    `CN = ${SELF_SIGNED_NAME}`,
    "",
    "[ v3_cs ]",
    "subjectKeyIdentifier   = hash",
    "authorityKeyIdentifier = keyid:always,issuer",
    "basicConstraints       = critical, CA:FALSE",
    "keyUsage               = critical, digitalSignature",
    "extendedKeyUsage       = codeSigning",
  ].join("\n");

  execSync(`printf '%s' '${conf.replace(/'/g, "'\\''")}' > "${tmpConf}"`, { stdio: "pipe" });
  execSync(`openssl req -newkey rsa:2048 -nodes -keyout "${tmpKey}" -x509 -days 3650 -out "${tmpCert}" -config "${tmpConf}"`, { stdio: "pipe" });
  // -legacy uses 3DES/RC2 encoding so macOS security import can read it.
  // OpenSSL 3.x default (AES-256) and empty passwords are both rejected by macOS.
  const p12pass = "octopus-codesign";
  execSync(`openssl pkcs12 -export -out "${tmpP12}" -inkey "${tmpKey}" -in "${tmpCert}" -passout "pass:${p12pass}" -legacy`, { stdio: "pipe" });
  execSync(`security import "${tmpP12}" -k "${KEYCHAIN}" -T /usr/bin/codesign -P "${p12pass}"`, { stdio: "pipe" });
  execSync(`security add-trusted-cert -d -r trustRoot -k "${KEYCHAIN}" "${tmpCert}"`, { stdio: "pipe" });
  execSync(`rm -f "${tmpConf}" "${tmpKey}" "${tmpCert}" "${tmpP12}"`, { stdio: "pipe" });
}

let signed = false;

// 1. Try Apple Development cert
const appleDevCert = findCertInKeychain("Apple Development:");
if (appleDevCert && trySign(appleDevCert)) {
  console.log(`Signed with: ${appleDevCert}`);
  signed = true;
}

// 2. Try or create self-signed cert
if (!signed) {
  if (!findCertInKeychain(SELF_SIGNED_NAME)) {
    console.log(`Creating self-signed code-signing certificate "${SELF_SIGNED_NAME}"...`);
    try {
      createSelfSignedCert();
    } catch (e) {
      console.warn(`Warning: Could not create self-signed cert: ${e.message}`);
    }
  }

  const selfSignedCert = findCertInKeychain(SELF_SIGNED_NAME);
  if (selfSignedCert && trySign(selfSignedCert)) {
    console.log(`Signed with self-signed certificate: ${selfSignedCert}`);
    signed = true;
  }
}

// 3. Ad-hoc fallback
if (!signed) {
  console.warn("No usable certificate found — falling back to ad-hoc signature.");
  console.warn("Accessibility/Input Monitoring permissions must be re-granted after each rebuild.");
  await run("codesign", ["--force", "--deep", "--sign", "-", appBundle]);
}

console.log(`Done. App bundle: ${appBundle}`);
