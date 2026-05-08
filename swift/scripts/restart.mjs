import { spawn, execSync } from "node:child_process";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const root = resolve(__dirname, "..");
const appBundle = join(root, "build", "OctopusSync.app");

try {
  execSync("pkill -x OctopusSync", { stdio: "pipe" });
  await new Promise((r) => setTimeout(r, 1000));
} catch {
  // not running — that's fine
}

spawn("open", [appBundle], { detached: true, stdio: "ignore" }).unref();
console.log("OctopusSync restarted.");
