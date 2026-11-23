// The beer: a glass you're looking through. Used by every amber desktop (the hero, 07 install).
// Inside `root`: the wallpaper's three layers ([data-beer-wave], in [data-beer-level]) swell on
// their own loops, script-driven so the surface is always known. A canvas ([data-fizz]) draws the
// carbonation (streams from fixed nucleation points, bubbles that grow and speed up as they rise,
// then pop) and the head of foam: one continuous creamy body, its top scalloped by bubbles, a
// texture of fine cells inside, glints from above. Shake it (`agitate`) and it behaves like a shaken soda: the gas comes out of solution
// (a rush of bubbles everywhere), the head blooms over a few tenths of a second, the liquid
// surges, and a hard enough hit pushes the foam over the rim — on `spill`, a canvas outside the
// clipped glass: a puffy crown draping over the edge, viscous drips running down the front that
// slow, thin and sometimes drop a bead. When the head falls back it leaves lacing on the glass.
// Text in `copy` keeps the rising bubbles dimmed behind it. `level` raises the liquid, `slosh`
// tilts it, `pour` fills the glass, `running` starts/stops drawing (stop it when unseen).

type Bubble = { x0: number; x: number; y: number; r: number; v: number; ph: number; amp: number; age: number };
type Site = { x: number; every: number; next: number; r: number };
type Pop = { x: number; y: number; r: number; age: number };
type Drip = { x: number; y: number; v: number; max: number; w: number; w0: number; age: number; life: number; ph: number; stopped: number; dropped: boolean };
type Drop = { x: number; y: number; v: number; r: number; age: number };
type Lace = { dx: number; dy: number; rx: number; ry: number; rot: number }[];

export type Beer = {
  level(n: number): void;
  slosh(): void;
  pour(): void;
  running(on: boolean): void;
  /** Shake it: 0–1+. Scaled to the glass: a brush makes a wave, a medium hit fills half the glass
   * with foam, a hard one spills over the rim (drawn on `spill`). */
  agitate(intensity: number): void;
};

const STEP = 14; // viewBox units the level rises per step of `level`
const TAU = Math.PI * 2;
const SPILL_TOP = 140; // px of room above the rim on the spill canvas (matches .beer-spill)
const SPILL_SIDE = 24;

export function createBeer(
  root: HTMLElement,
  opts: {
    copy?: HTMLElement | null;
    running?: boolean;
    spill?: HTMLCanvasElement | null;
    /** The glass's corner radius, for the rim the foam spills over. */
    radius?: number;
    /** How much lower than the drawing this glass sits, in viewBox units (a half-full glass). */
    base?: number;
  } = {},
): Beer | null {
  const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  const levelEl = root.querySelector<SVGGElement>("[data-beer-level]");
  const waveEls = Array.from(root.querySelectorAll<SVGGElement>("[data-beer-wave]"));
  const fizz = root.querySelector<HTMLCanvasElement>("[data-fizz]");
  const ctx = fizz?.getContext("2d") ?? null;
  if (!levelEl || !fizz || !ctx || !waveEls.length) return null;
  const copy = opts.copy ?? null;
  const spill = opts.spill ?? null;
  const sctx = spill?.getContext("2d") ?? null;
  const R = opts.radius ?? 0;
  const base = opts.base ?? 0;
  const rand = (a: number, b: number) => a + Math.random() * (b - a);
  const clamp01 = (v: number) => Math.min(1, Math.max(0, v));

  // ── State ───────────────────────────────────────────────────────────────────────────────────
  // The level is a spring in viewBox units (it overshoots and settles). `surge` is the shaken
  // liquid's extra rise in px. `head` is the foam's thickness in px; `bloom` is foam still coming
  // out of solution, fed into the head over ~0.3s. `gas` is how much CO2 is being released.
  let start: number | null = null;
  let levelTarget = base;
  let levelNow = base;
  let levelV = 0;
  let surge = 0;
  let surgeV = 0;
  let head = 0;
  let bloom = 0;
  let gas = 0;
  let clock = 0;

  // ── The wallpaper's waves ─────────────────────────────────────────────────────────────────
  // "M-120 y L0 y C x y x y x y S x y x y L1560 y" → 16 numbers, tweened in place.
  const nums = (d: string) => (d.match(/-?\d+(?:\.\d+)?/g) ?? []).map(Number);
  const pathOf = (n: number[]) =>
    `M${n[0]} ${n[1]} L${n[2]} ${n[3]} C ${n[4]} ${n[5]} ${n[6]} ${n[7]} ${n[8]} ${n[9]} S ${n[10]} ${n[11]} ${n[12]} ${n[13]} L${n[14]} ${n[15]}`;
  const easeInOut = (f: number) => (f < 0.5 ? 4 * f * f * f : 1 - Math.pow(-2 * f + 2, 3) / 2);
  const waves = waveEls.map((g) => ({
    g,
    fill: g.querySelector<SVGPathElement>("[data-fill]")!,
    stroke: g.querySelector<SVGPathElement>("[data-stroke]")!,
    keys: (JSON.parse(g.dataset.tops ?? "[]") as string[]).map(nums),
    dur: Number(g.dataset.dur ?? 12) * 1000,
    now: [] as number[],
  }));
  const shapeWaves = (ms: number) => {
    for (const w of waves) {
      const p = ((ms % w.dur) / w.dur) * w.keys.length;
      const i = Math.floor(p);
      const a = w.keys[i];
      const b = w.keys[(i + 1) % w.keys.length];
      const e = easeInOut(p - i);
      w.now = a.map((v, k) => v + (b[k] - v) * e);
      const d = pathOf(w.now.map((v) => Math.round(v * 10) / 10));
      w.stroke.setAttribute("d", d);
      w.fill.setAttribute("d", `${d} V1100 H-120Z`);
    }
  };

  // ── Where the surface is, in canvas px ────────────────────────────────────────────────────
  // Sample the top layer's two curves, apply the slosh rotation (about the viewBox centre) and the
  // level translation, then the slice fit.
  let W = 0;
  let H = 0;
  let fit = { s: 1, ox: 0, oy: 0 };
  const surface: { x: number; y: number }[] = [];
  const cubic = (t: number, a: number, b: number, c: number, d: number) => {
    const u = 1 - t;
    return u * u * u * a + 3 * u * u * t * b + 3 * u * t * t * c + t * t * t * d;
  };
  const matrixOf = (el: Element) => {
    const t = getComputedStyle(el).transform;
    return t && t !== "none" ? new DOMMatrix(t) : new DOMMatrix();
  };
  const measureSurface = () => {
    const n = waves[0]?.now;
    if (!n?.length) return;
    const rot = new DOMMatrix().translate(720, 400).multiply(matrixOf(waves[0].g)).translate(-720, -400);
    const all = matrixOf(levelEl).multiply(rot);
    const pts: [number, number][] = [[n[0], n[1]]];
    const rx = 2 * n[8] - n[6];
    const ry = 2 * n[9] - n[7];
    for (let k = 0; k <= 24; k++) {
      const t = k / 24;
      pts.push([cubic(t, n[2], n[4], n[6], n[8]), cubic(t, n[3], n[5], n[7], n[9])]);
    }
    for (let k = 1; k <= 24; k++) {
      const t = k / 24;
      pts.push([cubic(t, n[8], rx, n[10], n[12]), cubic(t, n[9], ry, n[11], n[13])]);
    }
    pts.push([n[14], n[15]]);
    surface.length = 0;
    for (const [x, y] of pts) {
      const q = all.transformPoint(new DOMPoint(x, y));
      surface.push({ x: fit.ox + q.x * fit.s, y: fit.oy + q.y * fit.s });
    }
    surface.sort((a, b) => a.x - b.x);
  };
  const surfaceAt = (x: number) => {
    if (!surface.length) return H;
    let lo = 0;
    let hi = surface.length - 1;
    if (x <= surface[0].x) return surface[0].y;
    if (x >= surface[hi].x) return surface[hi].y;
    while (hi - lo > 1) {
      const mid = (lo + hi) >> 1;
      if (surface[mid].x <= x) lo = mid;
      else hi = mid;
    }
    const a = surface[lo];
    const b = surface[hi];
    return a.y + ((b.y - a.y) * (x - a.x)) / (b.x - a.x || 1);
  };

  // Foam isn't flat: a slow, travelling lumpiness (three octaves of sines), stronger as it grows.
  const ph = [rand(0, TAU), rand(0, TAU), rand(0, TAU), rand(0, TAU)];
  const lump = (x: number, amt = 1) =>
    1 +
    amt *
      (0.17 * Math.sin(x * 0.0102 + ph[0] + clock * 0.33) +
        0.1 * Math.sin(x * 0.0261 + ph[1] - clock * 0.47) +
        0.06 * Math.sin(x * 0.0617 + ph[2] + clock * 0.8));
  // Real foam undulates a few px, however tall it is: absolute lumpiness, not proportional.
  const headAt = (x: number) => 6 + head + Math.min(16, 3 + head * 0.06) * ((lump(x, 1) - 1) / 0.33);
  const foamTop = (x: number) => surfaceAt(x) - headAt(x);

  // ── Particles ───────────────────────────────────────────────────────────────────────────────
  let bubbles: Bubble[] = [];
  let sites: Site[] = [];
  let pops: Pop[] = [];
  let copyRect = { x: 0, y: 0, w: 0, h: 0 };
  const spawn = (x: number, y: number, r: number, v = rand(14, 28)): Bubble => ({ x0: x, x, y, r, v, ph: rand(0, TAU), amp: rand(0.3, 1.4), age: 0 });

  // Spill: the crown, the drips, the beads they drop.
  let drips: Drip[] = [];
  let drops: Drop[] = [];
  let spillPops: Pop[] = [];
  let spilled = 0; // keeps oozing after the surge falls back: drains over ~1.6s
  let spilledPeak = 0;

  // Lacing: where the head reached, foam stays stuck to the glass for a while.
  const LACE_STEP = 9;
  let laceTop: number[] = []; // highest foam top (smallest y) per column since the last shake
  let laceAge = 99;
  let lacePattern: Lace[] = [];

  const layout = () => {
    W = root.offsetWidth;
    H = root.offsetHeight;
    const dpr = Math.min(2, window.devicePixelRatio || 1);
    fizz.width = Math.round(W * dpr);
    fizz.height = Math.round(H * dpr);
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    const s = Math.max(W / 1440, H / 800);
    fit = { s, ox: (W - 1440 * s) / 2, oy: (H - 800 * s) / 2 };
    if (copy) {
      const box = root.getBoundingClientRect();
      const rects = (Array.from(copy.children) as HTMLElement[]).map((k) => k.getBoundingClientRect()).filter((r) => r.width);
      if (rects.length) {
        const x = Math.min(...rects.map((r) => r.left)) - box.left;
        const y = Math.min(...rects.map((r) => r.top)) - box.top;
        copyRect = {
          x: x - 16,
          y: y - 16,
          w: Math.max(...rects.map((r) => r.right)) - box.left - x + 32,
          h: Math.max(...rects.map((r) => r.bottom)) - box.top - y + 32,
        };
      }
    }
    // Nucleation sites: fixed points the streams rise from, like scratches in a glass.
    sites = Array.from({ length: Math.max(6, Math.round(W / 68)) }, () => ({ x: rand(12, W - 12), every: rand(0.09, 0.32), next: rand(0, 0.3), r: rand(0.9, 1.9) }));
    // Foam texture: fine cells (and a few big bubbles) placed inside whatever foam body is drawn.
    tex = Array.from({ length: Math.round(W * 1.1) }, () => {
      const isBig = Math.random() < 0.05;
      return { u: Math.random(), v: Math.random(), r: isBig ? rand(4, 8.5) : rand(1.2, 3.6), big: isBig, glint: Math.random() < (isBig ? 0.9 : 0.25), ph: rand(0, TAU) };
    });
    laceTop = Array.from({ length: Math.ceil(W / LACE_STEP) + 1 }, () => Infinity);
    lacePattern = laceTop.map(() =>
      Array.from({ length: 2 + Math.floor(Math.random() * 3) }, () => ({ dx: rand(-5, 5), dy: rand(-7, 9), rx: rand(1.5, 5.5), ry: rand(0.8, 2.6), rot: rand(-0.6, 0.6) })),
    );
    if (spill && sctx) {
      spill.width = Math.round((W + 2 * SPILL_SIDE) * dpr);
      spill.height = Math.round((H + SPILL_TOP) * dpr);
      sctx.setTransform(dpr, 0, 0, dpr, 0, 0);

    }
  };

  const dimAt = (x: number, y: number) =>
    x > copyRect.x && x < copyRect.x + copyRect.w && y > copyRect.y && y < copyRect.y + copyRect.h ? 0.35 : 1;

  // ── Carbonation ─────────────────────────────────────────────────────────────────────────────
  const step = (dt: number) => {
    const fizzUp = 1 + 9 * gas; // shaken: the gas comes out of solution everywhere
    for (const s of sites) {
      s.next -= dt * fizzUp;
      if (s.next <= 0) {
        s.next = s.every * rand(0.7, 1.4);
        bubbles.push(spawn(s.x, H + 4, s.r * rand(0.8, 1.2)));
      }
    }
    if (Math.random() < dt * (W / 140) * (1 + 12 * gas)) bubbles.push(spawn(rand(0, W), H + 4, rand(0.8, 2.3)));
    // Nucleation in the body of the liquid, not only at the bottom, while the gas is coming out.
    const inBody = dt * (W / 9) * gas;
    for (let i = 0; i < Math.floor(inBody) + (Math.random() < inBody % 1 ? 1 : 0); i++) {
      const x = rand(0, W);
      const top = surfaceAt(x);
      if (H - top > 12) bubbles.push(spawn(x, rand(top + 8, H), rand(0.7, 2.6), rand(40, 90)));
    }
    for (const b of bubbles) {
      b.age += dt;
      b.v = Math.min(140 + 120 * gas, b.v + (34 + 60 * gas) * dt);
      b.y -= b.v * dt;
      b.r += b.r * 0.00055 * b.v * dt;
      b.x = b.x0 + Math.sin(b.age * 5 + b.ph) * b.amp * (1 + 2 * gas);
    }
    // Bubbles end where they meet the foam (or the bare surface) and pop there.
    bubbles = bubbles.filter((b) => {
      if (b.y > surfaceAt(b.x) + 1) return true;
      if (head < 8) pops.push({ x: b.x, y: b.y, r: b.r, age: 0 });
      return false;
    });
    // The head collapses from the top: bubbles bursting on it, more while it's tall.
    if (head > 6 && Math.random() < dt * (W / 90) * Math.min(1, head / 60)) {
      const x = rand(0, W);
      pops.push({ x, y: foamTop(x) + rand(0, 3), r: rand(1.2, 3.4), age: 0 });
    }
    for (const p of pops) p.age += dt;
    pops = pops.filter((p) => p.age < 0.22);
  };

  // ── Drawing helpers ─────────────────────────────────────────────────────────────────────────
  // Foam is one continuous body: an organic top edge (scalloped by the bubbles at its surface), a
  // creamy vertical gradient, and inside it, clipped, a texture of fine cells with a few larger
  // bubbles near the top and glints from above. `top`/`base` are y per column every FOAM_DX px,
  // starting at x = x0; NaN where there's no foam.
  const FOAM_DX = 3;
  type Tex = { u: number; v: number; r: number; big: boolean; glint: boolean; ph: number };
  let tex: Tex[] = [];
  const scallop = (x: number) => 1.6 * Math.abs(Math.sin(x * 0.23 + ph[3])) + 1.1 * Math.abs(Math.sin(x * 0.57 + ph[1]));
  const drawFoamBody = (c: CanvasRenderingContext2D, ox: number, x0: number, top: number[], base: number[], ms: number) => {
    // Split into runs where there's foam.
    const runs: [number, number][] = [];
    let s0 = -1;
    for (let i = 0; i <= top.length; i++) {
      const ok = i < top.length && !Number.isNaN(top[i]) && base[i] - top[i] > 0.6;
      if (ok && s0 < 0) s0 = i;
      if (!ok && s0 >= 0) (runs.push([s0, i - 1]), (s0 = -1));
    }
    if (!runs.length) return;
    let minTop = Infinity;
    let maxBase = -Infinity;
    for (const [a, b] of runs)
      for (let i = a; i <= b; i++) {
        minTop = Math.min(minTop, top[i]);
        maxBase = Math.max(maxBase, base[i]);
      }
    const body = new Path2D();
    for (const [a, b] of runs) {
      const X = (i: number) => ox + x0 + i * FOAM_DX;
      body.moveTo(X(a), base[a]);
      for (let i = a; i <= b; i++) {
        const t = Math.min(top[i], base[i] - 0.6);
        // The scallops shrink where the foam is thin, so a thin head is a smooth line.
        const sc = scallop(X(i)) * Math.min(1, (base[i] - top[i]) / 14);
        body.lineTo(X(i), t - sc);
      }
      for (let i = b; i >= a; i--) body.lineTo(X(i), base[i]);
      body.closePath();
    }
    // Body.
    const g = c.createLinearGradient(0, minTop, 0, Math.max(minTop + 1, maxBase));
    g.addColorStop(0, "rgba(255, 252, 245, 0.99)");
    g.addColorStop(0.45, "rgba(255, 246, 228, 0.98)");
    g.addColorStop(1, "rgba(242, 218, 170, 0.93)");
    c.fillStyle = g;
    c.fill(body);
    // Texture, clipped inside: fine cells everywhere, a few big bubbles near the top.
    c.save();
    c.clip(body);
    const fine = new Path2D();
    const big = new Path2D();
    const glints = new Path2D();
    const span = top.length * FOAM_DX;
    for (const t of tex) {
      const i = Math.round((t.u * span) / FOAM_DX);
      if (i < 0 || i >= top.length || Number.isNaN(top[i])) continue;
      const h = base[i] - top[i];
      if (h < 2) continue;
      if (t.big && t.v < 0.6) continue; // big bubbles sit in the upper part
      const x = ox + x0 + t.u * span;
      const y = base[i] - t.v * h;
      const r = t.r * (t.big ? 1 : 0.55 + 0.45 * t.v) * (0.95 + 0.05 * Math.sin(ms / 650 + t.ph));
      const p = t.big ? big : fine;
      p.moveTo(x + r, y);
      p.arc(x, y, r, 0, TAU);
      if (t.glint && r > 1.6) {
        const gr = r * (t.big ? 0.3 : 0.26);
        glints.moveTo(x - r * 0.34 + gr, y - r * 0.38);
        glints.arc(x - r * 0.34, y - r * 0.38, gr, 0, TAU);
      }
    }
    c.lineWidth = 0.5;
    c.strokeStyle = "rgba(200, 164, 112, 0.24)";
    c.stroke(fine);
    c.fillStyle = "rgba(255, 252, 246, 0.35)";
    c.fill(big);
    c.lineWidth = 0.8;
    c.strokeStyle = "rgba(190, 150, 96, 0.38)";
    c.stroke(big);
    c.fillStyle = "rgba(255, 255, 255, 0.85)";
    c.fill(glints);
    // Shading: the underside is warmer and a touch darker; the top catches the light.
    const sh = c.createLinearGradient(0, minTop, 0, Math.max(minTop + 1, maxBase));
    sh.addColorStop(0, "rgba(255, 255, 255, 0.0)");
    sh.addColorStop(0.75, "rgba(255, 255, 255, 0)");
    sh.addColorStop(1, "rgba(170, 112, 40, 0.14)");
    c.fillStyle = sh;
    c.fill(body);
    c.restore();
    // A sheen along the top edge.
    c.beginPath();
    for (const [a, b] of runs) {
      for (let i = a; i <= b; i++) {
        const X = ox + x0 + i * FOAM_DX;
        const sc = scallop(X) * Math.min(1, (base[i] - top[i]) / 14);
        const y = Math.min(top[i], base[i] - 0.6) - sc + 1;
        if (i === a) c.moveTo(X, y);
        else c.lineTo(X, y);
      }
    }
    c.lineWidth = 1.2;
    c.strokeStyle = "rgba(255, 255, 255, 0.7)";
    c.stroke();
  };

  // ── The head of foam, in the glass ──────────────────────────────────────────────────────────
  const drawHead = (ms: number) => {
    if (!surface.length) return;
    // Lacing first: it sits on the glass, behind the foam.
    drawLace();
    const n = Math.ceil(W / FOAM_DX) + 1;
    const top = new Array<number>(n);
    const base = new Array<number>(n);
    for (let i = 0; i < n; i++) {
      const x = i * FOAM_DX;
      const s = surfaceAt(x);
      top[i] = s - headAt(x);
      base[i] = s + 2;
    }
    drawFoamBody(ctx, 0, 0, top, base, ms);
    // Where foam meets beer: a soft, warm line.
    ctx.beginPath();
    for (let i = 0; i < n; i++) (i ? ctx.lineTo : ctx.moveTo).call(ctx, i * FOAM_DX, base[i]);
    ctx.lineWidth = 2;
    ctx.strokeStyle = "rgba(196, 128, 40, 0.22)";
    ctx.stroke();
  };

  // Lacing: rings and streaks of foam left on the glass between where the head reached and where
  // it is now, fading over ~8s.
  const drawLace = () => {
    if (laceAge > 9) return;
    const a = 0.55 * clamp01(1 - laceAge / 9) * clamp01(laceAge / 0.6);
    if (a <= 0.01) return;
    ctx.beginPath();
    for (let i = 0; i < laceTop.length; i++) {
      const hw = laceTop[i];
      if (!isFinite(hw)) continue;
      const x = i * LACE_STEP;
      if (foamTop(x) - hw < 14) continue; // still covered by foam
      for (const m of lacePattern[i]) {
        ctx.moveTo(x + m.dx + m.rx, hw + m.dy);
        ctx.ellipse(x + m.dx, hw + m.dy, m.rx, m.ry, m.rot, 0, TAU);
      }
    }
    ctx.fillStyle = `rgba(255, 250, 238, ${a * 0.55})`;
    ctx.fill();
    ctx.lineWidth = 0.7;
    ctx.strokeStyle = `rgba(255, 255, 255, ${a})`;
    ctx.stroke();
    // A few streaks where foam slid down the glass.
    ctx.beginPath();
    for (let i = 0; i < laceTop.length; i += 3) {
      const hw = laceTop[i];
      if (!isFinite(hw)) continue;
      const x = i * LACE_STEP + lacePattern[i][0].dx;
      const len = 6 + Math.abs(lacePattern[i][0].dy) * 2.2;
      if (foamTop(x) - hw < len + 14) continue;
      ctx.moveTo(x, hw + 4);
      ctx.lineTo(x + lacePattern[i][0].rot * 2, hw + 4 + len);
    }
    ctx.lineWidth = 1.4;
    ctx.lineCap = "round";
    ctx.strokeStyle = `rgba(255, 250, 238, ${a * 0.6})`;
    ctx.stroke();
  };

  const draw = (ms: number) => {
    ctx.clearRect(0, 0, W, H);
    // Rising bubbles first, behind the head.
    for (const b of bubbles) {
      const a = dimAt(b.x, b.y);
      ctx.beginPath();
      ctx.arc(b.x, b.y, b.r, 0, TAU);
      if (b.r < 1.3) {
        ctx.fillStyle = `rgba(255, 250, 238, ${0.7 * a})`;
        ctx.fill();
        continue;
      }
      ctx.fillStyle = `rgba(255, 246, 226, ${0.16 * a})`;
      ctx.fill();
      ctx.lineWidth = 0.8;
      ctx.strokeStyle = `rgba(255, 252, 242, ${0.75 * a})`;
      ctx.stroke();
      ctx.beginPath();
      ctx.arc(b.x - b.r * 0.35, b.y - b.r * 0.35, b.r * 0.32, 0, TAU);
      ctx.fillStyle = `rgba(255, 255, 255, ${0.85 * a})`;
      ctx.fill();
    }
    drawHead(ms);
    for (const p of pops) {
      const k = p.age / 0.22;
      ctx.beginPath();
      ctx.arc(p.x, p.y, p.r * (1 + 1.6 * k), 0, TAU);
      ctx.lineWidth = 0.7;
      ctx.strokeStyle = `rgba(255, 255, 255, ${0.6 * (1 - k)})`;
      ctx.stroke();
    }
  };

  // ── Overflow ────────────────────────────────────────────────────────────────────────────────
  const rimY = (x: number) => {
    if (x < R) return R - Math.sqrt(Math.max(0, R * R - (R - x) ** 2));
    if (x > W - R) return R - Math.sqrt(Math.max(0, R * R - (x - (W - R)) ** 2));
    return 0;
  };
  const overflowAt = (x: number) => Math.max(0, rimY(x) - foamTop(x));
  // The crown's height along the rim: what has spilled, lumpy, a little less in the corners.
  // Overflowing foam mushrooms a little over the rim (it can't stand tall) and the excess runs
  // down as drips; it rolls over the edge onto the front of the glass.
  const crownAt = (x: number) => {
    const edge = 0.6 + 0.4 * clamp01(Math.min(x, W - x) / Math.max(1, R * 2));
    return Math.min(spilled * 0.7, 62) * lump(x + 777, 1.2) * edge;
  };
  // The drape bulges down where a drip is born: the foam flows into it, no seam.
  const drapeAt = (x: number) => {
    let d = Math.min(16, crownAt(x) * 0.3) * (0.7 + 0.3 * Math.sin(x * 0.043 + ph[2]));
    for (const dr of drips) {
      const k = Math.abs(x - dr.x) / (dr.w0 * 1.1);
      if (k < 1) d = Math.max(d, (dr.w0 * 1.3 + 6) * Math.cos((k * Math.PI) / 2) ** 2 * clamp01((dr.life - dr.age) / 0.9));
    }
    return d;
  };
  // Drips run down beside the copy, never over it.
  const dripX = () => {
    const lanes: [number, number][] = [];
    const l = Math.max(R * 0.8, 10);
    if (copyRect.x - 10 > l) lanes.push([l, copyRect.x - 10]);
    if (W - l > copyRect.x + copyRect.w + 10) lanes.push([copyRect.x + copyRect.w + 10, W - l]);
    if (!lanes.length) lanes.push([l, W - l]);
    const [a, b] = lanes[Math.floor(Math.random() * lanes.length)];
    // Prefer where the crown is heaviest: try a few, keep the tallest.
    let best = rand(a, b);
    for (let i = 0; i < 3; i++) {
      const x = rand(a, b);
      if (crownAt(x) > crownAt(best)) best = x;
    }
    return best;
  };

  const stepSpill = (dt: number) => {
    if (!spill || !sctx) return;
    let most = 0;
    for (let x = 0; x <= W; x += 20) most = Math.max(most, overflowAt(x));
    const before = spilled;
    spilled = Math.max(most, spilled * Math.exp(-dt / 1.6));
    if (spilled < 0.5) spilled = 0;
    spilledPeak = spilled > before ? spilled : Math.max(spilled, spilledPeak * Math.exp(-dt / 3));
    const flow = Math.min(spilled, 130);
    // Drips: born where the crown is heavy, more while it's spilling.
    if (flow > 4 && drips.length < 22 && Math.random() < dt * (flow / 11) * (W / 420)) {
      const w0 = rand(6, 14) * (0.75 + Math.min(1, flow / 100) * 0.5);
      const x = dripX();
      // Not on top of another running drip.
      if (!drips.some((d) => Math.abs(d.x - x) < (d.w0 + w0) * 0.9 && d.age < 1.5)) {
        drips.push({ x, y: 0, v: rand(0, 10), max: rand(60, 230) * (0.6 + Math.min(1.2, flow / 80)), w: w0, w0, age: 0, life: rand(3.2, 5.5), ph: rand(0, TAU), stopped: 0, dropped: false });
      }
    }
    for (const d of drips) {
      d.age += dt;
      if (d.y < d.max) {
        // Viscous: weight pulls, drag holds; heavier drips run faster, everything slows.
        const a = 70 + d.w * 9 - 2.6 * d.v;
        d.v = Math.max(0, d.v + a * dt);
        d.y = Math.min(d.max, d.y + d.v * dt);
      } else {
        d.stopped += dt;
        d.v = 0;
        d.w = d.w0 * Math.exp(-d.stopped / 2.4); // the foam in it collapses: it thins
        // A heavy drip sometimes lets go of its bead.
        if (!d.dropped && d.w0 > 10 && d.stopped > 0.3 && Math.random() < dt * 0.9) {
          d.dropped = true;
          drops.push({ x: d.x, y: d.y + d.w * 0.4, v: 30, r: d.w * 0.5, age: 0 });
          d.y -= d.w * 0.5;
        }
      }
    }
    drips = drips.filter((d) => d.age < d.life);
    for (const dr of drops) {
      dr.age += dt;
      dr.v += 520 * dt;
      dr.y += dr.v * dt;
    }
    drops = drops.filter((dr) => dr.age < 0.9 && dr.y < H + 40);
    for (const p of spillPops) p.age += dt;
    spillPops = spillPops.filter((p) => p.age < 0.25);
  };

  const drawSpill = (ms: number) => {
    if (!spill || !sctx) return;
    const ox = SPILL_SIDE;
    const oy = SPILL_TOP;
    sctx.clearRect(0, 0, spill.width, spill.height);
    if (!spilled && !drips.length && !drops.length && !spillPops.length) return;

    // A soft shadow the foam casts on the front of the glass, just under the rim.
    if (spilled > 2) {
      const sh = sctx.createLinearGradient(0, oy, 0, oy + 22);
      sh.addColorStop(0, `rgba(120, 66, 8, ${0.16 * Math.min(1, spilled / 40)})`);
      sh.addColorStop(1, "rgba(120, 66, 8, 0)");
      sctx.fillStyle = sh;
      sctx.fillRect(ox + R * 0.5, oy, W - R, 22);
    }

    // Drips (behind the crown, which they hang from).
    for (const d of drips) drawDrip(d, ox, oy);

    // Crown: one foam body over the rim, draping onto the front; bubbles pop on it as it drains.
    {
      const n = Math.ceil(W / FOAM_DX) + 1;
      const top = new Array<number>(n);
      const base = new Array<number>(n);
      for (let k = 0; k < n; k++) {
        const x = k * FOAM_DX;
        const ch = crownAt(x);
        const dr = drapeAt(x);
        if (ch < 1 && dr < 1.5) {
          top[k] = NaN;
          base[k] = NaN;
          continue;
        }
        top[k] = oy + rimY(x) - Math.max(ch, 2);
        base[k] = oy + rimY(x) + dr;
      }
      drawFoamBody(sctx, ox, 0, top, base, ms);
      if (spilled > 2 && spilled < spilledPeak * 0.95 && Math.random() < 0.6) {
        const x = rand(0, W);
        const ch = crownAt(x);
        if (ch > 3) spillPops.push({ x: ox + x, y: oy + rimY(x) - ch * rand(0.4, 1) + 2, r: rand(1.5, 4), age: 0 });
      }
    }

    // Beads falling away.
    for (const dr of drops) {
      const a = clamp01(1 - dr.age / 0.9);
      sctx.beginPath();
      sctx.ellipse(ox + dr.x, oy + dr.y, dr.r * 0.85, dr.r * 1.15, 0, 0, TAU);
      sctx.fillStyle = `rgba(255, 248, 232, ${0.95 * a})`;
      sctx.fill();
      sctx.beginPath();
      sctx.arc(ox + dr.x - dr.r * 0.3, oy + dr.y - dr.r * 0.35, dr.r * 0.28, 0, TAU);
      sctx.fillStyle = `rgba(255, 255, 255, ${0.9 * a})`;
      sctx.fill();
    }
    for (const p of spillPops) {
      const k = p.age / 0.25;
      sctx.beginPath();
      sctx.arc(p.x, p.y, p.r * (1 + 1.4 * k), 0, TAU);
      sctx.lineWidth = 0.7;
      sctx.strokeStyle = `rgba(255, 255, 255, ${0.7 * (1 - k)})`;
      sctx.stroke();
    }
  };

  // A drip: tapered, wobbling a little as it runs, a bead at the end; lit from the left.
  const drawDrip = (d: Drip, ox: number, oy: number) => {
    if (!sctx || d.y < 2 || d.w < 0.8) return;
    const a = clamp01((d.life - d.age) / 0.9);
    const x0 = ox + d.x;
    const y0 = oy + rimY(d.x) + 2; // starts inside the crown's bulge above it
    const N = 14;
    const left: [number, number][] = [];
    const right: [number, number][] = [];
    for (let k = 0; k <= N; k++) {
      const f = k / N;
      const yy = y0 + d.y * f;
      const wob = Math.sin(d.y * f * 0.045 + d.ph) * 1.3 * f;
      // Widest where it leaves the crown, tapering as it runs; the bead at the end is a little
      // wider than the thread above it.
      const prof = 1.05 - 0.4 * Math.pow(f, 0.8);
      const half = (d.w / 2) * prof;
      left.push([x0 + wob - half, yy]);
      right.push([x0 + wob + half, yy]);
    }
    const end = left[N];
    const bx = (end[0] + right[N][0]) / 2;
    const by = end[1];
    const br = d.w * (0.4 + 0.08 * Math.min(1, d.y / 120));
    const path = () => {
      sctx.beginPath();
      sctx.moveTo(left[0][0], left[0][1]);
      for (const [x, y] of left) sctx.lineTo(x, y);
      sctx.arc(bx, by, br, Math.PI, 0, true);
      for (let k = N; k >= 0; k--) sctx.lineTo(right[k][0], right[k][1]);
      sctx.closePath();
    };
    // Shadow on the glass, offset down-right.
    sctx.save();
    sctx.translate(1.2, 1.8);
    path();
    sctx.fillStyle = `rgba(110, 60, 6, ${0.12 * a})`;
    sctx.fill();
    sctx.restore();
    // Body: lit from the left.
    path();
    const g = sctx.createLinearGradient(bx - br, 0, bx + br, 0);
    g.addColorStop(0, `rgba(255, 253, 247, ${0.98 * a})`);
    g.addColorStop(0.5, `rgba(254, 245, 226, ${0.97 * a})`);
    g.addColorStop(1, `rgba(234, 208, 166, ${0.95 * a})`);
    sctx.fillStyle = g;
    sctx.fill();
    // A glint running down its left side, and one on the bead.
    sctx.beginPath();
    for (let k = 1; k < N; k++) {
      const x = left[k][0] + d.w * 0.2;
      if (k === 1) sctx.moveTo(x, left[k][1]);
      else sctx.lineTo(x, left[k][1]);
    }
    sctx.lineWidth = Math.max(0.8, d.w * 0.14);
    sctx.lineCap = "round";
    sctx.strokeStyle = `rgba(255, 255, 255, ${0.75 * a})`;
    sctx.stroke();
    sctx.beginPath();
    sctx.arc(bx - br * 0.32, by - br * 0.1, br * 0.26, 0, TAU);
    sctx.fillStyle = `rgba(255, 255, 255, ${0.85 * a})`;
    sctx.fill();
  };

  // ── Physics ─────────────────────────────────────────────────────────────────────────────────
  // Springs: the level (overshoots a little) and the surge from a shake (underdamped: it rises
  // fast, falls back, bobs once). The foam blooms in from `bloom`, keeps growing while the gas
  // comes out, and collapses slowly. Lacing records how high the head reached.
  const physics = (dt: number) => {
    clock += dt;
    const a = 30 * (levelTarget - levelNow) - 7 * levelV;
    levelV += a * dt;
    levelNow += levelV * dt;
    const sa = -18 * surge - 3.5 * surgeV;
    surgeV += sa * dt;
    surge += surgeV * dt;
    const fromBloom = bloom * (1 - Math.exp(-dt / 0.28));
    bloom -= fromBloom;
    head += fromBloom + gas * H * 0.05 * dt;
    head = Math.max(0, Math.min(0.62 * H, head - head * (1 - Math.exp(-dt / 3.2))));
    gas *= Math.exp(-dt / 1.8);
    if (gas < 0.002) gas = 0;
    levelEl.style.transform = `translateY(${(levelNow - surge / fit.s).toFixed(2)}px)`;
    laceAge += dt;
    if (head > 20) for (let i = 0; i < laceTop.length; i++) laceTop[i] = Math.min(laceTop[i], foamTop(i * LACE_STEP) + 4);
  };

  let on = false;
  let rafId = 0;
  let last = 0;
  const frame = (ms: number) => {
    rafId = 0;
    const dt = Math.min(0.05, last ? (ms - last) / 1000 : 0.016);
    last = ms;
    physics(dt);
    shapeWaves(ms);
    measureSurface();
    step(dt);
    draw(ms);
    stepSpill(dt);
    drawSpill(ms);
    if (on) rafId = requestAnimationFrame(frame);
  };

  const beer: Beer = {
    level(n) {
      start ??= n;
      levelTarget = base - (start - n) * STEP;
      if (reduceMotion || !on) {
        levelNow = levelTarget;
        levelV = 0;
        levelEl.style.transform = `translateY(${levelNow}px)`;
        if (reduceMotion) requestAnimationFrame(() => (measureSurface(), draw(0)));
      }
    },
    agitate(intensity) {
      if (reduceMotion || !on || intensity <= 0) return;
      const k = Math.min(1.4, intensity);
      // Scaled to the glass, so the same hit means the same thing on any panel height.
      surgeV += 2 * H * k;
      bloom += 0.3 * H * k;
      gas = Math.min(2, gas + k);
      // A new shake starts a new lacing record (keeping what's higher).
      if (laceAge > 1.5) laceTop = laceTop.map(() => Infinity);
      laceAge = 0;
      if (k > 0.35) beer.slosh();
    },
    slosh() {
      if (reduceMotion) return;
      waveEls.forEach((w, i) =>
        w.animate(
          [
            { transform: "rotate(0deg)" },
            { transform: "rotate(-2.2deg)", offset: 0.18 },
            { transform: "rotate(1.5deg)", offset: 0.42 },
            { transform: "rotate(-0.7deg)", offset: 0.66 },
            { transform: "rotate(0.25deg)", offset: 0.84 },
            { transform: "rotate(0deg)" },
          ],
          { duration: 1500, delay: i * 90, easing: "ease-out" },
        ),
      );
      // A slosh shakes loose a burst of bubbles from the bottom.
      for (let k = 0; k < Math.round(W / 40); k++) bubbles.push(spawn(rand(0, W), H + rand(4, 120), rand(0.8, 2)));
    },
    // The glass fills: the liquid pours in from below, then settles with a slosh.
    pour() {
      if (reduceMotion) return;
      levelEl.animate([{ transform: "translateY(300px)" }, { transform: "translateY(0)" }], {
        duration: 1600,
        easing: "cubic-bezier(.2,.8,.2,1)",
        composite: "add",
      });
      setTimeout(() => beer.slosh(), 900);
    },
    running(next) {
      if (reduceMotion || next === on) return;
      on = next;
      last = 0;
      if (on && !rafId) rafId = requestAnimationFrame(frame);
    },
  };

  levelEl.style.transform = `translateY(${base}px)`;
  layout();
  new ResizeObserver(() => {
    layout();
    if (reduceMotion) (shapeWaves(0), measureSurface(), draw(0));
  }).observe(root);
  if (reduceMotion) {
    // A still glass: the waves at rest, bubbles caught mid-rise, the foam on top.
    shapeWaves(0);
    measureSurface();
    for (let k = 0; k < Math.round(W / 9); k++) {
      const x = rand(0, W);
      const top = surfaceAt(x);
      if (H - top > 20) bubbles.push(spawn(x, rand(top + 10, H), rand(0.6, 2)));
    }
    draw(0);
  } else {
    // Settle the shapes once so a glass that starts stopped isn't empty.
    shapeWaves(0);
    measureSurface();
    if (opts.running ?? true) beer.running(true);
  }
  return beer;
}
