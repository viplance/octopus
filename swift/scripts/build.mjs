import { rm } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { spawn } from "node:child_process";

const __dirname = dirname(fileURLToPath(import.meta.url));
const root = resolve(__dirname, "..");
const buildDir = join(root, "build");

function run(command, args, options = {}) {
  return new Promise((res, rej) => {
    const child = spawn(command, args, { cwd: root, stdio: "inherit", ...options });
    child.on("exit", (code) => (code === 0 ? res() : rej(new Error(`${command} ${args.join(" ")} exited ${code}`))));
    child.on("error", rej);
  });
}

console.log("Cleaning build dir...");
await rm(buildDir, { recursive: true, force: true });

console.log("Building OctopusSync (Release)...");
await run("xcodebuild", [
  "-project", "OctopusSync.xcodeproj",
  "-scheme", "OctopusSync",
  "-configuration", "Release",
  `CONFIGURATION_BUILD_DIR=${buildDir}`,
  "build",
]);

console.log(`Done. App bundle: ${join(buildDir, "OctopusSync.app")}`);
