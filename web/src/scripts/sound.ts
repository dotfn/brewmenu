// The sound of the beer, synthesized with Web Audio (no audio files): the hiss of gas coming out
// of solution, the crackle of foam (hundreds of tiny pops, densest at the start and thinning out
// while the head collapses), a low slosh when the hit is hard, and a few bubbles rising in pitch.
// It lasts as long as the foam does on screen. On by default (asked for); the menu
// bar's speaker item turns it off, and the choice is remembered per browser. Browsers still play
// nothing until the visitor clicks, taps or presses a key somewhere (scrolling doesn't count):
// the first such gesture on the page wakes the audio up.
//
// One shared instance on `window`: every script that imports this module talks to the same
// AudioContext, whichever bundle chunk it came from.

type State = { on: boolean; ctx: AudioContext | null; out: GainNode | null; noise: AudioBuffer | null; last: number; listeners: Set<(on: boolean) => void> };

const KEY = "brewmenu-sound";
const S: State = ((window as unknown as { __brewSound?: State }).__brewSound ??= {
  on: (() => {
    try {
      return localStorage.getItem(KEY) !== "off";
    } catch {
      return true;
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
  out.gain.value = 0.5;
  // A soft top: nothing above ~7kHz gets through at full strength, so the fizz never stings.
  const soft = ctx.createBiquadFilter();
  soft.type = "lowpass";
  soft.frequency.value = 7000;
  soft.Q.value = 0.5;
  out.connect(soft).connect(comp).connect(ctx.destination);
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

// The sound follows the beer's own clocks (src/scripts/beer.ts): the gas lets go with a time
// constant of 1.8s, the head blooms in over ~0.28s and collapses with 3.2s. Every voice decays on
// those same exponentials instead of ending on a fixed length, so it fades with the foam.
const GAS_TAU = 1.8;
const HEAD_TAU = 3.2;
const BLOOM = 0.28;
// How long the crackle goes on after a hit of strength k: the first, busy part of the head's
// collapse, not the whole of it (that was too long to listen to).
const tail = (k: number) => HEAD_TAU * Math.log(1 + 5 * k);
// A delay drawn from an exponential with time constant `tau`, cut off at `max`.
const expDelay = (tau: number, max: number) => -tau * Math.log(1 - Math.random() * (1 - Math.exp(-max / tau)));

// The hiss: gas leaving the liquid. Bright filtered noise that swells in with the bloom and dies
// away with the gas.
const hiss = (ctx: AudioContext, t: number, k: number) => {
  const end = t + BLOOM + 3 * GAS_TAU;
  const src = noiseSource(ctx, t);
  const hp = ctx.createBiquadFilter();
  hp.type = "highpass";
  hp.frequency.value = 1800;
  const bp = ctx.createBiquadFilter();
  bp.type = "bandpass";
  bp.frequency.setValueAtTime(3800, t);
  bp.frequency.setTargetAtTime(5000, t, GAS_TAU);
  bp.Q.value = 0.6;
  const g = ctx.createGain();
  const peak = 0.08 + 0.12 * k;
  g.gain.setValueAtTime(0.0001, t);
  g.gain.exponentialRampToValueAtTime(peak, t + 0.07);
  g.gain.setTargetAtTime(peak * 0.7, t + 0.07, BLOOM);
  g.gain.setTargetAtTime(0, t + BLOOM, GAS_TAU);
  src.connect(hp).connect(bp).connect(g).connect(S.out!);
  src.stop(end);
};

// The crackle: each pop is a few ms of noise through a narrow band, at a random pitch and level.
// Some pops are bubbles bursting while the gas comes out (fast to fade), the rest the head
// collapsing (slow): thick at first, thinning out for as long as the foam is there.
const crackle = (ctx: AudioContext, t: number, k: number) => {
  const count = Math.round(90 + 340 * k);
  const max = tail(k);
  for (let i = 0; i < count; i++) {
    const after = expDelay(Math.random() < 0.45 ? GAS_TAU : HEAD_TAU, max);
    const at = t + after;
    const src = ctx.createBufferSource();
    src.buffer = S.noise;
    const len = rand(0.003, 0.009);
    const bp = ctx.createBiquadFilter();
    bp.type = "bandpass";
    bp.frequency.value = rand(1600, 6500);
    bp.Q.value = rand(4, 9);
    const g = ctx.createGain();
    const lvl = rand(0.04, 0.2) * (0.5 + 0.5 * k) * Math.exp(-after / HEAD_TAU);
    // A sub-ms rise instead of a jump: a pop, not a click.
    g.gain.setValueAtTime(0.0001, at);
    g.gain.exponentialRampToValueAtTime(lvl, at + 0.0008);
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
// They rise while the gas comes out.
const bubbles = (ctx: AudioContext, t: number, k: number) => {
  const n = Math.round(4 + 14 * k);
  for (let i = 0; i < n; i++) {
    const at = t + 0.02 + expDelay(GAS_TAU, 3 * GAS_TAU);
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
  /** Whether audio can actually play yet (a gesture has unlocked it). */
  get running() {
    return S.ctx?.state === "running";
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
    const t = now + 0.01;
    hiss(ctx, t, k);
    crackle(ctx, t, k);
    bubbles(ctx, t, k);
    if (k > 0.35) slosh(ctx, t, k);
  },
};
