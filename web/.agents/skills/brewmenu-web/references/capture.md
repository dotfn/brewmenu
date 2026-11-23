---
version: dotfn-capture-1
name: Mac-app landing (merged from five references)
source: |
  https://dotphin.vercel.app/ (primary — structure, motion, glass bar)
  https://this-day.app/ (hero rhythm, feature rows with real UI, comparison table)
  https://www.getsteerco.com/ (warm paper surface, editorial restraint, FAQ split)
  https://midcode.app/ (mono labels, brew install pill, hairline rules)
  https://akilastudio.com/work/agentools (product UI rebuilt as figures, quiet captions)
captured: 2026-11-22
summary: |
  A single-product Mac app page: centered hero (icon, "New in" pill, two-tone headline, one
  download action next to a copyable brew command), then the product's own UI rebuilt in HTML
  on a tilted stage that flattens as you scroll. Below: feature figures with miniature real UI,
  a dark terminal band, a comparison table, a FAQ and a closing card. Light, warm-neutral,
  almost no color outside the product stage. A rebuild reads wrong if the product UI is a
  screenshot instead of live HTML, or if every section fades in on scroll.
colors:
  bg: "#EDF0F2"
  bg-sunk: "#E3E7EA"
  surface: "#FFFFFF"
  surface-soft: "#F6F8F9"
  ink: "#121518"
  ink-2: "#545C64"
  ink-3: "#7B838A"
  accent: "#1A5FD0"
  term-bg: "#0F1418"
  separator: "rgba(16,24,32,0.10)"
type:
  display: { family: "Urbanist, sans-serif", size: 84px, weight: 700, tracking: -0.035em, lineHeight: 1.02 }
  h2: { family: "Urbanist, sans-serif", size: 52px, weight: 700, tracking: -0.03em, lineHeight: 1.06 }
  h3: { family: "Urbanist, sans-serif", size: 22px, weight: 700, tracking: -0.01em, lineHeight: 1.25 }
  body: { family: "Urbanist, sans-serif", size: 17px, weight: 400, lineHeight: 1.5 }
  mono: { family: "Geist Mono, monospace", size: 14px, weight: 400 }
spacing:
  base: 4px
  scale: [4, 8, 12, 16, 20, 24, 32, 40, 48, 64, 96]
radius:
  xs: 6px
  sm: 10px
  lg: 20px
  xl: 28px
  stage: 36px
motion:
  dur-quick: 180ms
  dur-standard: 280ms
  ease-out: "cubic-bezier(0, 0, .2, 1)"
  ease-spring: "cubic-bezier(.34, 1.36, .64, 1)"
  hero-tilt: "rotateX 26deg→0, scale .9→1, y 40px→0; perspective 1800px; origin 50% 100%; range start-end → start-20%"
components:
  hero: { align: center, icon: 88px, pill: "New in x.y", headline: "two lines, second in {colors.ink-3}" }
  install-pill: { background: "{colors.surface}", radius: "{radius.sm}", font: "{type.mono}" }
  product-stage: { radius: "{radius.stage}", transform: "{motion.hero-tilt}" }
  feature-card: { background: "{colors.surface}", radius: "{radius.xl}", figure: "{colors.bg-sunk}" }
  glass-bar: { height: 64px, radius: 22px, position: "fixed bottom 20px, centered" }
  compare-table: { background: "{colors.surface}", highlight: "product column tinted" }
---

# Design capture: Mac-app landing (merged from five references)

> Captured with dotfn-capture. Date: 2026-11-22. Emphasis: reference + system (merged mood for BrewMenu, not a faithful rebuild of any one site)

## Source

Five live URLs, each captured with `extract_tokens.py` (CSS custom properties + keyframes) and `capture_site.py --viewports desktop,mobile --full-page --save-html` (frames + computed styles). Dotphin additionally got `--motion` (forced hover/active/focus, scroll-reveal, click toggles) and `--scroll-scrub` with `--inspect-canvas`; the hero tilt equation was read from its JS bundle, not eyeballed. Midcode's full-page frames show blank bands — its sections reveal on intersection and the static capture never triggered them; its structure below is read from the visible parts only.

## Summary

All five are pages for one product made by a small studio. The shared move: the product's interface, rebuilt in HTML at small scale, carries the page; prose stays short and concrete. What a rebuild must get right: the product UI is live markup with real-looking data (versions, sizes, dates), never a flat screenshot, and motion is reserved for one moment (the hero stage) instead of every section.

## 1. Identity

### 1.1 Impression

- **Quiet** — one cool/warm neutral background ({colors.bg} #EDF0F2 on dotphin, #F1F1F2 on thisday, #F6F1E7 on steerco), no section banding except one dark band.
- **Concrete** — every feature claim sits next to a miniature of the UI doing it, with plausible data ("harbor-dawn.heic 3.4 MB").
- **Native** — macOS vocabulary: traffic lights, sidebars, ⌘ glyphs in keycaps, glass bars.
- **Editorial** — steerco: serif display, long rules between FAQ rows; akila: captions under figures.
- **Confident type** — display 84–95px with negative tracking (-2.9px at 84px on dotphin, ✅ computed).

### 1.2 The one distinguishing thing

Dotphin and thisday share it: the headline's second line in a quieter grey ("Every folder, / side by side." — second line {colors.ink-3}), repeated once in the closing card. It appears exactly twice per page.

## 2. Tokens

### 2.1 Color

| Token | Value | Role | Where it appears | Confidence |
|---|---|---|---|---|
| bg | #EDF0F2 | page | body | ✅ |
| bg-sunk | #E3E7EA | figure wells inside cards | feature figures | ✅ |
| surface | #FFFFFF | cards, table, closing card | | ✅ |
| surface-soft | #F6F8F9 | secondary buttons | Copy button | ✅ |
| ink | #121518 | text, primary | headings, body | ✅ |
| ink-2 | #545C64 | secondary text | descriptions | ✅ |
| ink-3 | #7B838A | quiet display line, captions | headline line 2 | ✅ |
| accent | #1A5FD0 | the download action only | Download buttons, "New in" chip | ✅ |
| term-bg | #0F1418 | dark terminal band | one section | ✅ |
| separator | rgba(16,24,32,.10) | hairlines | FAQ rows, table | ✅ |

Thisday's accent is #FF3157 (red) used the same way — only on the download button and "New in" chip ✅.

### 2.2 Type

Dotphin: Urbanist (✅ computed) + Geist Mono for commands. Thisday: Open Runde. Steerco: Fraunces display + DM Sans body. Midcode: Geist + Geist Mono.

| Token | Size | Weight | Line-height | Use |
|---|---|---|---|---|
| display | 84px (44px mobile) | 700 | 1.02 | hero h1 |
| h2 | 52px (34px mobile) | 700 | 1.06 | section titles |
| h3 | 22px | 700 | 1.25 | feature card titles |
| body | 17px | 400 | 1.5 | paragraphs |
| caption | 14px | 400–600 | 1.5 | meta lines, table |

### 2.3 Spacing and radius

4px base ✅ (`--spacing: .25rem`). Radius is tiered ✅: xs 6 (keycaps), sm 10 (install pill, buttons), lg 20 (inner figures), xl 28 (cards), 36 stage. Inner radius = outer − inset in the feature cards (28 outer, 8 inset, 20 figure).

### 2.4 Elevation

| Level | Treatment | Use |
|---|---|---|
| lift | 0 1px 2px rgba(16,24,32,.06) | cards at rest |
| float | 0 18px 50px rgba(14,30,44,.14), 0 2px 8px rgba(14,30,44,.06) | glass bar, popovers |
| window | 0 40px 90px rgba(8,40,60,.28), 0 8px 24px rgba(8,40,60,.14) | the hero app window |

### 2.5 Contrast check

Checked with `lint_design_md.py --contrast` against the BrewMenu palette derived from this capture (see the project skill): every text pair passes AA; ink on amber 9.98:1; quiet text on bg 4.97:1.

## 3. Components

#### hero

Centered column: app icon (88px, own shadow), "New in x.y" pill (accent chip + label + chevron), two-line h1, 2-line description (max ~560px), action row (Download button + install pill), one meta line ("Free · macOS 27 or later · Beta", 14px {colors.ink-2}). ✅ computed.

#### install-pill

White pill, 1px separator border, radius 10px: `$` in ink-3, command in Geist Mono 15px, a "Copy" button (surface-soft, radius 10px) on the right ✅.

#### product-stage

Max 1280px, radius 36px, overflow hidden, wallpaper (three.js shader on dotphin — water and a warm sun) with the app window centered inside. Scroll-driven tilt (Section 5) ✅.

#### feature-card

White card, radius 28px, 8px inset well in {colors.bg-sunk} radius 20px holding a miniature UI, then h3 + 2-line description with inline keycaps ✅. Two columns on desktop, one on mobile.

#### glass-bar

Fixed bottom-center pill 420px × 64px, radius 22px, strong glass (white 82% + blur): menu button, prev section, current-section title + subtitle, next section, a round accent download button. Side pills (studio mark left, GitHub right) only ≥1024px ✅ (from `class` attributes in the saved HTML).

#### compare-table

White, radius 20px, product column tinted (#EEF5FE on dotphin), ✓ glyphs with short annotations ("⌘\"), em-dash for absent ✅. Caption below in 13px ink-3.

## 4. Layout

### 4.1 Grid and containers

Text column ~560–640px; figure grid max ~1100px; stage max 1280px. Section rhythm ~128–160px. Hierarchy is carried by size and weight; color only separates the quiet headline line.

### 4.2 Responsive behavior

Desktop 1440 and mobile 375 captured. Mobile: h1 44px, h2 34px, single-column cards, glass bar keeps full width minus 32px, side pills hidden. Nothing else measured ❓.

## 5. Motion

**Pseudo-class (measured, dotphin):** shortcut rows — `transition-colors` at `--dur-quick` 180ms, hover fills `bg-surface/60`, pressed fills `bg-surface` and sets `aria-pressed`.

**Scroll-reveal:** none measured on dotphin ("no measurable change on scroll-into-view"). Midcode does reveal sections on intersection (inferred from blank capture bands ⚠️).

**Scroll-driven (measured from bundle, dotphin, Framer Motion `useScroll`):** target = stage; `offset: ["start end", "start 0.2"]`; `rotateX: [26, 0]` deg, `scale: [.9, 1]`, `y: [40, 0]` px; parent `perspective: 1800px`; `transformOrigin: 50% 100%`. Reduced motion → constants (0, 1, 0).

**Spatial invariants (stage tilt):**

- **Scale direction:** grows toward 1 as it enters — starts at .9 and reaches full size at the end of the range; never overshoots.
- **Coordinate space:** item-local — the stage's own top edge against the viewport (`start end` → `start 0.2`), not a continuous screen-space field; the wallpaper inside tilts with it.
- **Viewport reach:** fixed max width 1280px with 16px side gutters; it never stretches to the viewport edges.

**State loop:** the hero demo cycles states with `hold: 3400` ms ✅ (bundle).

## 6. Reconstruction guidance

Stack: any static site; dotphin is Next + Tailwind 4 + Framer Motion. Without Framer, the tilt is ~20 lines of rAF on scroll. Quick wins: real product UI in HTML, `<details>` FAQ, one copy-to-clipboard component. Tricky: glass legibility over a busy wallpaper; table on mobile (scroll inside its own container, never the page); keeping the hero demo loop pausable.

## 7. Constraints

### Do

- Keep {colors.accent} for the download action and the "New in" chip only.
- Put a miniature of the real UI next to every feature claim.
- Use the quiet second headline line exactly twice: hero and closing card.

### Don't

- Don't fade-rise every section; the stage tilt is the page's one scroll motion.
- Don't screenshot the product where HTML can rebuild it.
- Don't band sections in alternating colors; one dark band at most.

## 8. Open questions

Midcode's hidden sections were not captured (needs `--motion --scroll-selector section` with longer settle). Not needed for the merge.

## 9. Companion files

- This spec.
- Frames: `{ref}-desktop.png`, `{ref}-mobile.png` for all five references (session scratchpad, not committed).
