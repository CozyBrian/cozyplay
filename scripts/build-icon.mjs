// Exports Resources/cozyplay.icon to art/icon.png for web and marketing use.
// Run with: node scripts/build-icon.mjs
import { execFile } from "node:child_process";
import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import path from "node:path";

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const execute = promisify(execFile);

const developerDirectories = [
  process.env.DEVELOPER_DIR,
  "/Applications/Xcode.app/Contents/Developer",
  "/Applications/Xcode-beta.app/Contents/Developer",
].filter(Boolean);

const iconTool = developerDirectories
  .map((directory) =>
    path.resolve(
      directory,
      "../Applications/Icon Composer.app/Contents/Executables/ictool",
    ),
  )
  .find(existsSync);

if (!iconTool) {
  console.error(
    "Icon Composer's ictool was not found. Install Xcode or set DEVELOPER_DIR.",
  );
  process.exit(1);
}

const source = path.join(repo, "Resources", "cozyplay.icon");
const output = path.join(repo, "art", "icon.png");

await execute(iconTool, [
  source,
  "--export-image",
  "--output-file",
  output,
  "--platform",
  "macOS",
  "--rendition",
  "Default",
  "--width",
  "1024",
  "--height",
  "1024",
  "--scale",
  "1",
]);

console.log("Created art/icon.png");
