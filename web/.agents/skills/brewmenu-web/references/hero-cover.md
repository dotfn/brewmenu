# element capture: stacked-card cover (bemaconsultora.com)

> Captured with dotfn-capture, element mode. 2026-11-22. Source: https://bemaconsultora.com/ — the
> "Servicio 01/02/03" stack. Measured by scrubbing the live page and reading each card's inline
> style at 15 scroll positions (Playwright, 1440×900). Library: none needed; their JS writes inline
> `transform`, `opacity`, `filter` per frame.

## Structure (✅ from the rendered DOM)

- Runway: `div.relative` with `height: 300vh` (N = 3 cards).
- Pin: `div.sticky.top-0.h-screen.flex.items-center.overflow-clip`.
- Cards: `li.[grid-area:1/1].origin-top.will-change-transform`, `z-index: i`; each an `article` with
  `bg-white/70 backdrop-blur-xl ring-1 ring-inset ring-white/80 rounded-3xl p-3`.

## Equation (✅ measured)

`p` = progress over the runway (0→1). Each card i ≥ 1 owns the segment `[(i−1)/(N−1), i/(N−1)]`;
`t_i` = linear progress inside it.

- Entering card: `translateY(110vh · (1 − t_i))`, nothing else.
- Card below it: `d = clamp((t_next − 0.25) / 0.75)` →
  `translateY(−10.5% · d) scale(1 − 0.06 · d)`, `opacity: 1 − 0.2625 · d`, `filter: blur(10.5 · d px)`.
  Samples: t=0.5 → d=⅓ → −3.5%, 0.98, 0.9125, 3.5px; t=1 → −10.5%, 0.94, 0.7375, 10.5px.
- Cards further back stay at d = 1.

## Spatial invariants

- Scale direction: the covered card shrinks toward its top edge (`transform-origin: top`).
- Coordinate space: item-local — each card's own segment of the runway.
- Viewport reach: the entering card travels from 110vh (fully off-screen) to 0.

## How BrewMenu uses it

Only on the hero: the hero pins (`position: sticky`, `top = min(0, 100vh − heroHeight)`), the rest
of the page is one sheet that slides over it, and `t` = sheet coverage since pinning
(`(scrollY − max(0, h − vh)) / vh`). Same `d` mapping on the hero's inner wrapper, plus
corner radius 0 → 28px as it sinks. The engine is the measured equation; only the target changed.
