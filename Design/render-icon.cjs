#!/usr/bin/env node
// Renders the app icon from Design/icon.svg.
//
// Produces opaque PNGs (App Store icons must not have an alpha channel):
//   SembleShare/Assets.xcassets/AppIcon.appiconset/icon-1024.png  (1024 px)
//   web/icon.png                                                   (512 px)
//
// Run from anywhere; see Design/README.md for the one-liner that installs
// @resvg/resvg-js into a temporary directory first.

const fs = require("fs");
const path = require("path");
const zlib = require("zlib");
const { Resvg } = require("@resvg/resvg-js");

const repo = path.resolve(__dirname, "..");
const logo = fs.readFileSync(path.join(__dirname, "icon.svg"), "utf8");

const BACKGROUND = "#FFF1E2"; // Semble cream
const LOGO_FRACTION = 0.62;   // logo width as a fraction of the icon width

// The logo's viewBox is "-5.5 0 43 43" (square), so a nested <svg> of equal
// width and height keeps the aspect ratio and centres the artwork.
function composite(size) {
  const logoSize = Math.round(size * LOGO_FRACTION);
  const offset = (size - logoSize) / 2;
  const inner = logo
    .replace(/^<\?xml[^>]*>\s*/, "")
    .replace(/<svg([^>]*)\swidth="[^"]*"/, "<svg$1")
    .replace(/<svg([^>]*)\sheight="[^"]*"/, "<svg$1")
    .replace("<svg", `<svg x="${offset}" y="${offset}" width="${logoSize}" height="${logoSize}"`);
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}" viewBox="0 0 ${size} ${size}">
  <rect width="${size}" height="${size}" fill="${BACKGROUND}"/>
  ${inner}
</svg>`;
}

// resvg always emits RGBA PNGs. App Store Connect rejects icons that carry an
// alpha channel at all (even a fully opaque one), so re-encode the raw pixels
// as an 8-bit RGB PNG ourselves. PNG is simple enough to write by hand.
function encodeRGB(width, height, rgba) {
  const stride = width * 3;
  const raw = Buffer.alloc((stride + 1) * height);
  for (let y = 0; y < height; y++) {
    raw[y * (stride + 1)] = 0; // filter type: None
    for (let x = 0; x < width; x++) {
      const i = (y * width + x) * 4;
      const o = y * (stride + 1) + 1 + x * 3;
      if (rgba[i + 3] !== 255) throw new Error(`pixel (${x},${y}) is not opaque`);
      raw[o] = rgba[i];
      raw[o + 1] = rgba[i + 1];
      raw[o + 2] = rgba[i + 2];
    }
  }
  const chunk = (type, data) => {
    const len = Buffer.alloc(4);
    len.writeUInt32BE(data.length);
    const body = Buffer.concat([Buffer.from(type, "ascii"), data]);
    const crc = Buffer.alloc(4);
    crc.writeUInt32BE(zlib.crc32(body));
    return Buffer.concat([len, body, crc]);
  };
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0);
  ihdr.writeUInt32BE(height, 4);
  ihdr[8] = 8; // bit depth
  ihdr[9] = 2; // colour type: truecolour (RGB, no alpha)
  ihdr[10] = 0; ihdr[11] = 0; ihdr[12] = 0;
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk("IHDR", ihdr),
    chunk("IDAT", zlib.deflateSync(raw, { level: 9 })),
    chunk("IEND", Buffer.alloc(0)),
  ]);
}

function render(size, outFile) {
  const resvg = new Resvg(composite(size), {
    fitTo: { mode: "width", value: size },
    background: BACKGROUND, // flattens any transparency
  });
  const image = resvg.render();
  const png = encodeRGB(image.width, image.height, image.pixels);
  fs.mkdirSync(path.dirname(outFile), { recursive: true });
  fs.writeFileSync(outFile, png);
  console.log(`${path.relative(repo, outFile)}  ${image.width}x${image.height} RGB`);
}

render(1024, path.join(repo, "SembleShare/Assets.xcassets/AppIcon.appiconset/icon-1024.png"));
render(512, path.join(repo, "web/icon.png"));
