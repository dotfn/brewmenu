// Renders the social preview images (public/og-image.jpg and public/og-image-es.jpg): the hero in
// small — amber wallpaper, the app icon, the hero title, a line, the install command, the meta —
// drawn as HTML in Chrome so it uses the page's own fonts.
//
//   cd web && npx -y -p playwright-core@1 node scripts/og/build-og.mjs
//
// Output is exactly 1200×630 (what every platform expects) and a JPEG well under WhatsApp's
// 500 KB limit: rendered at 2× for crisp text, downscaled by Chrome, encoded at quality 88.
import { chromium } from "playwright-core";
import { readFileSync, writeFileSync, statSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const pub = join(here, "..", "..", "public");
const icon = readFileSync(join(pub, "icon-512.png")).toString("base64");

const copy = {
  en: {
    title: "Homebrew,<br>in plain sight.",
    line: "BrewMenu lives in your menu bar and keeps an eye on Homebrew for you.",
    meta: "Free · macOS 26 or later · Open source",
    file: "og-image.jpg",
  },
  es: {
    title: "Homebrew,<br>a simple vista.",
    line: "BrewMenu vive en tu barra de menú y vigila Homebrew por vos.",
    meta: "Gratis · macOS 26 o posterior · Código abierto",
    file: "og-image-es.jpg",
  },
};

const page = (c) => `<!doctype html><html><head><meta charset="utf-8">
<link href="https://fonts.googleapis.com/css2?family=Urbanist:wght@400;500;700&family=Geist+Mono:wght@400&display=block" rel="stylesheet">
<style>
html,body{margin:0;width:1200px;height:630px;overflow:hidden}
body{position:relative;font-family:Urbanist,sans-serif;color:#1c1206;
 background:linear-gradient(180deg,#fff1d6 0%,#fcd48c 38%,#f3a845 70%,#e28a28 100%)}
svg.w{position:absolute;inset:0;width:100%;height:100%}
.wrap{position:absolute;inset:0;display:flex;align-items:center;gap:56px;padding:0 84px}
img{width:340px;height:340px;flex:none;margin-left:-26px;filter:drop-shadow(0 18px 36px rgb(60 30 0/.35))}
h1{margin:0;font-size:86px;line-height:1.0;font-weight:700;letter-spacing:-0.035em}
p.l{margin:22px 0 0;font-size:29px;line-height:1.35;color:rgb(28 18 6/.82);max-width:600px}
.cmd{margin-top:32px;display:inline-flex;align-items:center;gap:10px;background:#fff;border-radius:12px;padding:14px 20px;font:400 21px "Geist Mono",monospace;box-shadow:0 0 0 1px rgb(28 18 6/.12)}
.cmd span{color:#8a8478}
.meta{margin-top:18px;font-size:21px;color:rgb(28 18 6/.75)}
</style></head><body>
<svg class="w" viewBox="0 0 1200 630" preserveAspectRatio="xMidYMid slice">
<defs><linearGradient id="a" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#ffe3a6"/><stop offset="1" stop-color="#f8b552"/></linearGradient>
<linearGradient id="b" x1="0" y1="0" x2="1" y2=".6"><stop offset="0" stop-color="#f9c063"/><stop offset="1" stop-color="#ee962e"/></linearGradient>
<linearGradient id="c" x1="0" y1="0" x2="1" y2=".4"><stop offset="0" stop-color="#f2a53f"/><stop offset="1" stop-color="#df8222"/></linearGradient></defs>
<path d="M0 260 C 220 200 430 330 680 260 S 1050 170 1200 230 V630 H0Z" fill="url(#a)"/>
<path d="M0 395 C 250 325 470 445 750 372 S 1080 315 1200 355 V630 H0Z" fill="url(#b)"/>
<path d="M0 515 C 280 468 530 555 815 498 S 1110 475 1200 490 V630 H0Z" fill="url(#c)"/>
</svg>
<div class="wrap"><img src="data:image/png;base64,${icon}" alt=""><div>
<h1>${c.title}</h1>
<p class="l">${c.line}</p>
<div class="cmd"><span>$</span> brew install --cask dotfn/tap/brewmenu</div>
<div class="meta">${c.meta}</div>
</div></div></body></html>`;

const browser = await chromium.launch({ channel: "chrome" });
const p = await browser.newPage({ viewport: { width: 1200, height: 630 }, deviceScaleFactor: 2 });
for (const c of Object.values(copy)) {
  await p.setContent(page(c), { waitUntil: "networkidle" });
  await p.evaluate(() => document.fonts.ready);
  // Downscale the 2× render to exactly 1200×630 and encode, inside the page (no image deps).
  const hi = await p.screenshot({ type: "png" });
  const b64 = await p.evaluate(async (src) => {
    const img = new Image();
    img.src = `data:image/png;base64,${src}`;
    await img.decode();
    const cv = document.createElement("canvas");
    cv.width = 1200;
    cv.height = 630;
    const x = cv.getContext("2d");
    x.imageSmoothingQuality = "high";
    x.drawImage(img, 0, 0, 1200, 630);
    return cv.toDataURL("image/jpeg", 0.88).split(",")[1];
  }, hi.toString("base64"));
  const out = join(pub, c.file);
  writeFileSync(out, Buffer.from(b64, "base64"));
  console.log(c.file, Math.round(statSync(out).size / 1024), "KB");
}
await browser.close();
