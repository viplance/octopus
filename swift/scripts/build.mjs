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

// Use a real Apple Development certificate so TCC grants (Accessibility,
// Input Monitoring) survive rebuilds. Try each available cert and use the
// first one codesign accepts on this machine.
// Falls back to ad-hoc if none work (e.g. no Xcode login, CI machine).
let signed = false;
try {
  const output = execSync("security find-identity -v -p codesigning", { stdio: "pipe" }).toString();
  const certs = [...output.matchAll(/"(Apple Development:[^"]+)"/g)].map(m => m[1]);
  for (const cert of certs) {
    try {
      execSync(`codesign --force --deep --sign "${cert}" "${appBundle}"`, { stdio: "pipe" });
      console.log(`Signed with: ${cert}`);
      signed = true;
      break;
    } catch {
      // cert not usable on this machine (wrong keychain), try next
    }
  }
} catch {
  // security command not available
}

if (!signed) {
  console.log("No usable Apple Development certificate — using ad-hoc signature.");
  console.log("Note: Accessibility permission must be re-granted after each rebuild.");
  await run("codesign", ["--force", "--deep", "--sign", "-", appBundle]);
}

console.log(`Done. App bundle: ${appBundle}`);
