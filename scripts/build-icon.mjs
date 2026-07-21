// Renders art/icon.svg → art/icon.png (1024) + Resources/AppIcon.icns.
//
// Needs `sharp` (librsvg-backed — QuickLook/qlmanage can't render the SVG's
// feDropShadow filters). This repo has no JS toolchain, so sharp is borrowed
// from a sibling cozy repo's node_modules; override with COZY_SHARP_ROOT if
// yours lives elsewhere. Run with:  node scripts/build-icon.mjs
// The generated artifacts are committed, so app builds never need this.
import { execFile } from "node:child_process";
import { existsSync } from "node:fs";
import { mkdir, rm } from "node:fs/promises";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import path from "node:path";

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

const sharpRoots = [
  process.env.COZY_SHARP_ROOT,
  path.resolve(repo, "../cozyfinance-apps"),
  path.resolve(repo, "../cozycode/apps/desktop"),
].filter(Boolean);
const sharpRoot = sharpRoots.find((root) => existsSync(path.join(root, "node_modules", "sharp")));
if (!sharpRoot) {
  console.error(`sharp not found in any of: ${sharpRoots.join(", ")} — set COZY_SHARP_ROOT`);
  process.exit(1);
}
const sharp = createRequire(path.join(sharpRoot, "package.json"))("sharp");

const execute = promisify(execFile);
const source = path.join(repo, "art", "icon.svg");
const iconset = path.join(repo, "art", "icon.iconset");

const images = [
  ["icon_16x16.png", 16],
  ["icon_16x16@2x.png", 32],
  ["icon_32x32.png", 32],
  ["icon_32x32@2x.png", 64],
  ["icon_128x128.png", 128],
  ["icon_128x128@2x.png", 256],
  ["icon_256x256.png", 256],
  ["icon_256x256@2x.png", 512],
  ["icon_512x512.png", 512],
  ["icon_512x512@2x.png", 1024],
];

await rm(iconset, { recursive: true, force: true });
await mkdir(iconset, { recursive: true });
await mkdir(path.join(repo, "Resources"), { recursive: true });

await Promise.all(
  images.map(([filename, size]) =>
    sharp(source).resize(size, size).png().toFile(path.join(iconset, filename)),
  ),
);

await sharp(source).resize(1024, 1024).png().toFile(path.join(repo, "art", "icon.png"));
await execute("iconutil", [
  "--convert",
  "icns",
  iconset,
  "--output",
  path.join(repo, "Resources", "AppIcon.icns"),
]);
await rm(iconset, { recursive: true, force: true });

console.log("Created art/icon.png and Resources/AppIcon.icns");
