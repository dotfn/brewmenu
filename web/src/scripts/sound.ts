// The sound of the beer, synthesized with Web Audio (no audio files): the hiss of gas coming out
// of solution, the crackle of foam (hundreds of tiny pops, densest at the start), a low slosh
// when the hit is hard, and a few bubbles rising in pitch. Off by default: the menu bar's speaker
// item turns it on, which is also the user gesture browsers need before any audio can play
// (scrolling doesn't count). The choice is remembered per browser.
//
// One shared instance on `window`: every script that imports this module talks to the same
// AudioContext, whichever bundle chunk it came from.

type State = { on: boolean; ctx: AudioContext | null; out: GainNode | null; noise: AudioBuffer | null; last: number; listeners: Set<(on: boolean) => void> };

const KEY = "brewmenu-sound";
const S: State = ((window as unknown as { __brewSound?: State }).__brewSound ??= {
  on: (() => {
    try {
      return localStorage.getItem(KEY) === "on";
    } catch {
      return false;
    }
  })(),
  ctx: null,
  out: null,
  noise: null,
  last: 0,
  listeners: new Set(),
});

const rand = (a: number, b: number) => a + Math.random() * (b - a);

const ensure = () => {
  if (S.ctx) return S.ctx;
  const AC = window.AudioContext ?? (window as unknown as { webkitAudioContext?: typeof AudioContext }).webkitAudioContext;
  if (!AC) return null;
  const ctx = new AC();
  // A gentle master: never loud, never clipping when bursts overlap.
  const comp = ctx.createDynamicsCompressor();
  comp.threshold.value = -20;
  comp.ratio.value = 6;
  const out = ctx.createGain();
  out.gain.value = 0.55;
  out.connect(comp).connect(ctx.destination);
  // Two seconds of white noise, reused by every voice.
  const noise = ctx.createBuffer(1, ctx.sampleRate * 2, ctx.sampleRate);
  const d = noise.getChannelData(0);
  for (let i = 0; i < d.length; i++) d[i] = Math.random() * 2 - 1;
  S.ctx = ctx;
  S.out = out;
  S.noise = noise;
  return ctx;
};

const noiseSource = (ctx: AudioContext, at: number) => {
  const src = ctx.createBufferSource();
  src.buffer = S.noise;
  src.loop = true;
  src.start(at, Math.random() * 1.5);
  return src;
};

// The hiss: gas leaving the liquid. Bright filtered noise that swells in and dies away.
const hiss = (ctx: AudioContext, t: number, k: number, dur: number) => {
  const src = noiseSource(ctx, t);
  const hp = ctx.createBiquadFilter();
  hp.type = "highpass";
  hp.frequency.value = 2600;
  const bp = ctx.createBiquadFilter();
  bp.type = "bandpass";
  bp.frequency.setValueAtTime(5200, t);
  bp.frequency.exponentialRampToValueAtTime(7400, t + dur);
  bp.Q.value = 0.6;
  const g = ctx.createGain();
  const peak = 0.11 + 0.17 * k;
  g.gain.setValueAtTime(0.0001, t);
  g.gain.exponentialRampToValueAtTime(peak, t + 0.07);
  g.gain.exponentialRampToValueAtTime(peak * 0.45, t + dur * 0.35);
  g.gain.exponentialRampToValueAtTime(0.0001, t + dur);
  src.connect(hp).connect(bp).connect(g).connect(S.out!);
  src.stop(t + dur + 0.05);
};

// The crackle: each pop is a few ms of noise through a narrow band, at a random pitch and level.
// Pops come thick at first and thin out, like foam settling.
const crackle = (ctx: AudioContext, t: number, k: number, dur: number) => {
  const count = Math.round(90 + 420 * k);
  for (let i = 0; i < count; i++) {
    const at = t + dur * Math.pow(Math.random(), 1.9);
    const src = ctx.createBufferSource();
    src.buffer = S.noise;
    const len = rand(0.0015, 0.006);
    const bp = ctx.createBiquadFilter();
    bp.type = "bandpass";
    bp.frequency.value = rand(2200, 9500);
    bp.Q.value = rand(6, 14);
    const g = ctx.createGain();
    const lvl = rand(0.05, 0.32) * (0.5 + 0.5 * k) * (1 - 0.6 * ((at - t) / dur));
    g.gain.setValueAtTime(lvl, at);
    g.gain.exponentialRampToValueAtTime(0.0001, at + len);
    src.connect(bp).connect(g).connect(S.out!);
    src.start(at, Math.random() * 1.9, len + 0.002);
  }
};

// The slosh: a low swell of liquid moving, for hard hits.
const slosh = (ctx: AudioContext, t: number, k: number) => {
  const src = noiseSource(ctx, t);
  const lp = ctx.createBiquadFilter();
  lp.type = "lowpass";
  lp.frequency.setValueAtTime(220, t);
  lp.frequency.exponentialRampToValueAtTime(900, t + 0.12);
  lp.frequency.exponentialRampToValueAtTime(260, t + 0.55);
  lp.Q.value = 3;
  const g = ctx.createGain();
  g.gain.setValueAtTime(0.0001, t);
  g.gain.exponentialRampToValueAtTime(0.35 * k, t + 0.06);
  g.gain.exponentialRampToValueAtTime(0.0001, t + 0.6);
  src.connect(lp).connect(g).connect(S.out!);
  src.stop(t + 0.65);
};

// Bubbles: a quick upward chirp each, the sound of a bubble leaving the liquid.
const bubbles = (ctx: AudioContext, t: number, k: number, dur: number) => {
  const n = Math.round(3 + 10 * k);
  for (let i = 0; i < n; i++) {
    const at = t + rand(0.02, dur * 0.6);
    const o = ctx.createOscillator();
    o.type = "sine";
    const f0 = rand(380, 900);
    o.frequency.setValueAtTime(f0, at);
    o.frequency.exponentialRampToValueAtTime(f0 * rand(2.2, 3.4), at + rand(0.025, 0.06));
    const g = ctx.createGain();
    g.gain.setValueAtTime(0.0001, at);
    g.gain.exponentialRampToValueAtTime(rand(0.03, 0.08), at + 0.006);
    g.gain.exponentialRampToValueAtTime(0.0001, at + 0.07);
    o.connect(g).connect(S.out!);
    o.start(at);
    o.stop(at + 0.08);
  }
};

export const sound = {
  get on() {
    return S.on;
  },
  /** Turn it on or off. Call from a click: that's what unlocks audio in the browser. */
  set(on: boolean) {
    S.on = on;
    try {
      localStorage.setItem(KEY, on ? "on" : "off");
    } catch {
      // private mode: the choice just isn't remembered
    }
    if (on) {
      const ctx = ensure();
      void ctx?.resume();
    } else void S.ctx?.suspend();
    S.listeners.forEach((f) => f(on));
  },
  onChange(f: (on: boolean) => void) {
    S.listeners.add(f);
  },
  /** Any click or key on the page: if sound is on, make sure the context is running. */
  wake() {
    if (S.on) void ensure()?.resume();
  },
  /** The foam: 0–1+, same scale as the beer's `agitate`. */
  foam(k: number) {
    if (!S.on || k <= 0) return;
    const ctx = ensure();
    if (!ctx || ctx.state !== "running") return;
    const now = ctx.currentTime;
    // Hits arrive in quick runs; overlapping bursts would only get louder, so space them.
    if (now - S.last < 0.22) k *= 0.35;
    S.last = now;
    k = Math.min(1.2, k);
    const dur = 1.1 + 2.4 * k;
    const t = now + 0.01;
    hiss(ctx, t, k, dur);
    crackle(ctx, t, k, dur);
    bubbles(ctx, t, k, dur);
    if (k > 0.35) slosh(ctx, t, k);
  },
};
