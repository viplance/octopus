import { mkdir, rm, cp, access } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { spawn, execSync } from "node:child_process";

const __dirname = dirname(fileURLToPath(import.meta.url));
const root = resolve(__dirname, "..");
const buildDir = join(root, "build");
const appName = "OctopusSync";
const appBundle = join(buildDir, `${appName}.app`);
const dmgPath = join(buildDir, `${appName}.dmg`);
const tempDmgPath = join(buildDir, "temp.dmg");

function run(command, args, options = {}) {
  return new Promise((res, rej) => {
    const child = spawn(command, args, { cwd: root, stdio: "inherit", ...options });
    child.on("exit", (code) => (code === 0 ? res() : rej(new Error(`${command} ${args.join(" ")} exited ${code}`))));
    child.on("error", rej);
  });
}

async function ensureBuild() {
  try {
    await access(appBundle);
  } catch {
    console.log("App bundle not found — running build first...");
    await run("node", ["./scripts/build.mjs"]);
  }
}

await ensureBuild();

console.log("Preparing DMG...");
await rm(dmgPath, { force: true });
await rm(tempDmgPath, { force: true });

console.log("Creating writable DMG...");
await run("hdiutil", ["create", "-size", "120m", "-fs", "HFS+", "-volname", appName, "-ov", tempDmgPath]);

console.log("Mounting DMG...");
const mountOutput = execSync(`hdiutil attach -readwrite "${tempDmgPath}"`).toString();
const mountPoint = mountOutput.match(/\/Volumes\/.*/)?.[0]?.trim();
if (!mountPoint) throw new Error("Could not find mount point");
console.log("Mounted at:", mountPoint);

try {
  await cp(appBundle, join(mountPoint, `${appName}.app`), { recursive: true });
  execSync(`ln -s /Applications "${join(mountPoint, "Applications")}"`);

  const script = `
    tell application "Finder"
      tell disk "${appName}"
        open
        delay 2
        set w to container window
        set current view of w to icon view
        set toolbar visible of w to false
        set statusbar visible of w to false
        set bounds of w to {400, 100, 900, 480}
        set icon size of icon view options of w to 128
        set arrangement of icon view options of w to not arranged
        set position of item "${appName}.app" of w to {150, 190}
        set position of item "Applications" of w to {450, 190}
        update without registering applications
        delay 2
        close
      end tell
    end tell
  `;
  try {
    await run("osascript", ["-e", script]);
  } catch {
    console.warn("AppleScript styling failed — DMG will still work.");
  }

  await new Promise((r) => setTimeout(r, 1500));
} finally {
  console.log("Unmounting DMG...");
  execSync(`hdiutil detach "${mountPoint}"`);
}

console.log("Converting to compressed DMG...");
await run("hdiutil", ["convert", tempDmgPath, "-format", "UDZO", "-o", dmgPath]);
await rm(tempDmgPath, { force: true });

console.log(`\nDone. Installer: ${dmgPath}`);
