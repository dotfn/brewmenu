---
name: brewmenu-web
description: >-
  The BrewMenu website's design system (web/, Astro + Tailwind 4). Load before touching any
  page, section or component under web/src, before choosing a color, space, type size,
  radius, shadow or motion, before writing or changing site copy (en or es), and before
  calling any web screen finished. Overrules dotfn-taste and ad-hoc code; when the code and
  this skill disagree and the code is right, update this skill in the same change.
---

# BrewMenu web — design system

The site is one product page for a free, open-source macOS menu bar app for Homebrew, made by
dotfn. It descends from a merged capture of five Mac-app landing pages
([references/capture.md](references/capture.md)); the values below are BrewMenu's own.

## 1. Surfaces

| Route | Who | States |
|:--|:--|:--|
| `/` (en), `/es/` (es) | Mac developers who already use Homebrew, arriving from GitHub, the cask, or a share; mostly desktop, some phone | GitHub API reachable at build (stars, release zip URL) or not — every value has a static fallback |

One page, rendered by `src/components/HomePage.astro` with `lang`. Order: hero (the desktop) →
01 what it runs for you (one scene: the Dashboard window, scroll-driven) → 03 small things → 04 under the hood → 05 compared →
06 questions (heading pinned left, with "Something else? Ask on GitHub") → 07 install (`Install.astro`: a rounded
amber desktop panel with the hero's live beer, centred — the app icon, "Put Homebrew in your menu
bar.", the meta, ONE primary action (dark Download, version · size), then quieter "Or with
Homebrew, which keeps it updated:" and the command in a light glass pill, "Then look up: it's
already there.") → footer: one quiet 12px line in the strip left under 07's panel (built by • fn, GitHub, Releases, Report an issue, AGPL-3.0, the legal note to the right) — the panel is the last thing you see. Links 24px on a pointer, 44px on touch (negative margins reclaim the slack so it stays one row at 390px).

**The concept: the page is your Mac.** The site's navigation is a macOS menu bar
(`MenuBar.astro`), the hero is the desktop, and BrewMenu's status item in that bar is live.

## 2. Brand gesture

**The live status item.** The beer icon + badge in the site's menu bar is wired to the hero
popover (`mac/Popover.astro`): Upgrade / Upgrade All really run (simulated, 1.3s per package,
instant under reduced motion), rows leave, the popover's count and the menu bar badge drop
together, and "Up to date" offers a reset. On ≥1024px the popover hangs right under the status
item (positioned by script from its rect). This interaction is the page's signature.

**Amber is beer.** `--accent` (#FBB040, the app's `BrewTheme.accent`) appears in: the hero
desktop wallpaper (`.desktop-amber`), 07 install (the same desktop again, as the page's closing
bookend: asked for by the person to give getting the app the most visual weight), and the menu
bar badge in mocks. On the amber desktop the primary button is dark (`--desk-ink`), never amber on
amber. Nowhere else.

## 3. Color

Every value is a CSS custom property in `src/styles/global.css`, exposed to Tailwind through
`@theme inline`. Components use the role names only (`bg-surface`, `text-ink-2`), never hex.

| Role | Light | Dark | Use |
|:--|:--|:--|:--|
| `bg` | #F1EFEA | #14120E | page |
| `bg-sunk` | #E7E4DD | #1B1814 | figure wells inside cards |
| `surface` | #FFFFFF | #1F1C17 | cards, table, closing card, mock windows |
| `surface-soft` | #F8F7F4 | #26221C | secondary buttons, table header |
| `ink` | #16140F | #F3F0EA | text |
| `ink-2` | #5A564D | #B5AFA3 | secondary text |
| `ink-3` | #6B665C | #948E82 | captions, meta (≥ 4.5:1 on bg and surface) |
| `ink-quiet` | #8A8478 | #7A7468 | decorative only (stopped-service dot); never text |
| `accent` / `on-accent` | #FBB040 / #16140F | same | see §2 |
| `accent-ink` | #8A5A00 | #FBB040 | amber as text (rare: the "New" chip label in dark) |
| `separator` | ink at 10% | white at 10% | hairlines |
| `term-*` | #15120D bg, #D7D2C8 ink, #8E877B dim, #6FD08C green, #F3C86B yellow | same | terminal band and terminal figures |
| `sys-accent` | #1A62D6 | #3B82F6 | macOS system-accent controls *inside mocks* (Upgrade, Upgrade All) |
| `ok` / `danger` | #1E7A43 / #B3372E | #4CC27A / #FF7B6E | service running / stop, error |

Dark mode follows `prefers-color-scheme` only — no toggle. The hero desktop wallpaper and the
terminal don't change between modes; text on the wallpaper is always `--desk-ink`.

## 4. Type and numbers

- **Urbanist** for everything readable on the page (the face dotphin uses — chosen by the person),
  **Geist Mono** for package names, versions, commands, keycaps and sizes. Loaded with Astro fonts
  (`--font-urbanist`, `--font-geist-mono`). macOS mocks use the system font stack instead (§3).
- Display (the hero h1 only): Urbanist 700, tracking −0.035em, line-height ~1.02 (measured on
  dotphin: 84px / −2.94px). The brand's one display moment.
- **Titles below the hero speak macOS** (asked for by the person: Urbanist titles didn't read as
  native): h2, card and install h3, detail `dt`, FAQ `summary`, compare row labels use
  `font-title` = `-apple-system, BlinkMacSystemFont, "SF Pro Display"`, then Inter (loaded, never
  preloaded; only downloads off Apple devices). Set as Apple sets SF Display: h2 600, −0.01em at
  52px / −0.006em at 34px, line-height 1.08–1.1; h3 600, untracked. Urbanist's −0.035em made SF
  look cramped. Body text stays Urbanist.
- Scale (all in `global.css` `@theme`): `display` 84/44px; `h2` 52/34px · 600 · −0.01em; card
  titles 20px · 600; `lead` 19px; `body` 17px; `caption` 14px; mocks 12–13px (aria-hidden or
  macOS-native controls).
- Versions are always `from → to`, tabular, the `to` in `ink`, `from` in `ink-3`.
- Headings `text-wrap: balance`; paragraphs `pretty`.

## 5. Space, shape, depth

- 4px base, with 2px half-steps inside controls. Allowed values live in `dotfn-audit.json`.
- Radius tiers: `xs` 6 (badges, keycaps) · `sm` 10 (buttons, install pill) · `md` 14 (menus,
  Dashboard sidebar) · `lg` 20 (terminal) · 18 popover · 22 Dashboard window. Nested:
  inner = outer − inset (window 22, sidebar inset 8 → 14).
- Shadows: `float` (popover, menus), `window` (the Dashboard mock), a soft lift under the
  feature mocks. Section content never casts shadows. One light direction: from above.

## 6. Motion

The page must feel alive (a flat, static page was rejected — see §11). Motion comes from the
product doing its own thing, never decoration for its own sake:

- **Hero load, once:** text block enters staggered (`[data-enter]`, 70ms steps, 0.7s), then
  the popover drops from the status item (320ms, slight overshoot, origin top right). Closing
  is faster (160ms).
- **The beer lives in `src/scripts/beer.ts` (`createBeer(root, { copy, running })`) and
  `BeerWallpaper.astro` (the SVG layers + canvas, `id` for unique gradient ids)**: one engine for
  every amber desktop. The hero pours on load and its popover drives `level`/`slosh`; 07 pours the
  first time it's seen and only runs while intersecting.
- **07 foams over when you hit the bottom of the page (asked for by the person: "like a shaken
  soda").** The impact is the speed you reach the end with (scroll), plus pushing on against it
  (wheel / trackpad momentum, a finger dragging up); hits inside 90ms are one, and a stronger one
  tops it up. `agitate(k)` scales with the glass: surge `2·H·k` px/s (an underdamped spring that
  climbs and falls back) and the foam head `+0.3·H·k` (cap 0.58·H), drawn as layers of small
  bubbles, not a flat band. A brush makes a wave; a medium hit fills half the glass with foam; a
  hard one spills: a crown over the rim and drips down the front beside the copy, on
  `[data-spill]` (a canvas outside the clipped glass, 140px above it), lasting ~1.4s after the
  surge falls back. 07's glass sits half full (`base: 220`) so the climb is visible. The level
  is a JS spring now (it was a CSS transition), so `level`, `surge` and `pour` combine. Off under
  reduced motion. Realism (asked for: "polish it until it looks almost real"), all in
  `beer.ts`: foam is ONE continuous body (`drawFoamBody`: scalloped top edge, cream gradient,
  clipped texture of fine cells + a few big bubbles near the top, glints, a warm underside), never
  a pile of separate circles; its top undulates a few px absolutely (proportional lumps made
  mountains). A shake releases gas (`gas`): bubbles nucleate in the whole liquid and rise faster,
  the head blooms over ~0.3s (`bloom`) instead of jumping, and collapses slowly with pops on top.
  The crown mushrooms low over the rim (cap ~62px) and drapes onto the front; the excess runs as
  drips that taper (widest at the crown, a small bead), accelerate then slow (weight vs drag),
  thin as they stop, sometimes drop a bead, and the crown bulges down into each one (no seam).
  When the head falls, lacing stays on the glass where it reached (~8s). ~53fps at 1920×1200@2x
  at the peak. Overflow at the rim needs the panel's top on screen: at 1440×900 the climb and
  the drips show, the crown sits under the menu bar.
- **Sound (asked for by the person: "the sound of foam / beer when the effect runs")**:
  `src/scripts/sound.ts`, synthesized with Web Audio (no files): a bright hiss (gas leaving the
  liquid), crackle (90–510 micro-pops, densest at the start), rising bubble chirps, and a low
  slosh on hard hits; ~1–3.5s, scaled by the hit, peak ≈0.25, one shared instance on `window`.
  Off by default. Browsers only play audio after a click/tap/key — scrolling doesn't count — so
  it's turned on from a speaker item in the menu bar (macOS's volume item; aria-pressed, plays a
  small fizz to confirm), remembered in localStorage, and woken by the first click/key on a
  later visit. Hits closer than 220ms play quieter so a run of them doesn't stack.
- **The beer (hero wallpaper), asked for by the person — "it should feel like looking at a
  beer":** the three amber layers are liquid, driven by script (no SMIL) so the surface is known
  every frame. Each swells on its own loop (three shapes, 11 / 13.5 / 16s, ease-in-out); the glass
  fills on load (level pours in from 300 units below, 1.6s) and settles with a slosh; every
  finished upgrade sloshes the layers (rotation ±2.2° damped, 1.5s, staggered 90ms), shakes loose
  a burst of bubbles and raises the level 14 units; reset drops it back. On a canvas
  (`[data-fizz]`) over the wallpaper and under the text: carbonation rising in streams from fixed
  nucleation sites (~1 per 68px), plus a few strays; bubbles accelerate (to 140px/s), grow as they
  rise, wobble, and pop with a ring at the surface; a foam rim (soft band + packed small bubbles)
  rides the surface, following the slosh rotation and the level. Bubbles and foam dim to 35% over
  the hero copy. Stops drawing when the sheet covers the hero; under reduced motion it's one still
  frame (waves at rest, bubbles mid-rise, foam). 60fps measured in Chrome at 1440px.
- **The live popover:** upgrading rows spin, then collapse out; badge and count bump when the
  number changes; reset staggers the rows back in.
- **Live mocks (`[data-live]`) run once when 45% visible:** outdated rows arrive and the badge
  counts to 5; `brew doctor` spins then reports; streams (`[data-stream]`) print brew's output
  line by line with a cursor, with a real Cancel / Run again; services Start/Stop flip;
  Clean Up counts the bytes down; Remove collapses the row.
- **Hero cover (the one scroll effect):** the hero pins and the page slides over it as a
  rounded sheet; the hero's content sinks under it with bemaconsultora.com's measured equation
  (`references/hero-cover.md`): once the sheet is 25% in, `d = clamp((t−0.25)/0.75)` →
  `translateY(−10.5%·d) scale(1−0.06·d) opacity(1−0.2625·d) blur(10.5·d px)`. On phones the hero
  scrolls to its bottom first, then pins. The only other scroll-driven piece is 01's scene.
- **01, the scene (asked for by the person: merge the feature cards and the Dashboard, all
  motion):** one Dashboard window pins (desktop: both columns `sticky` over a runway of 7 × 50vh;
  phones: the window pins under the menu bar and the steps scroll beneath it). Each step selects
  its view in the window's own sidebar — one highlight slides there (460ms, slight overshoot) and
  the item lights when it lands — and plays it once on entry: Updates counts 0→5; an Upgrade All
  presses itself, rows spin and leave one by one while brew's output slides up from the bottom,
  ending on "Up to date"; Doctor Warnings spins then reports; Services starts cloudflared;
  Cache counts 1.4 GB down to freed; Insights and Disk Usage stagger / grow in. A view is restored
  from its first render before replaying; `epoch` cancels the previous step's work. Left column:
  heading, lead, and the step index — the active step opens with its body and a hairline fills
  with progress toward the next; clicking a step scrolls to it. Every control in the window also
  works by hand (Update, Upgrade All, Start/Stop, Clean Up, Remove, sidebar items; Apps opens
  without a step). Replaced: ThisDay's stacked cards, the separate Dashboard section and its
  auto-tour, and the Check frequency picker (the schedule lives in 03 "Your schedule").
  Copy and rhythm (it read cramped): heading ≤ 2 lines ("All of brew, one window." / "Todo
  brew, en\u00a0una ventana." — the nbsp keeps "en una" together); lead one line; step titles one
  line, ≤ ~26 chars, 16px; bodies ≤ ~90 chars, max 38ch; rows 48px. Only the active step draws its
  progress hairline — done steps go back to a plain separator (seven full ink lines read as
  noise). Phones: the active step is the first whose text is still below the pinned window, and
  steps are 32vh tall, so the text being read is never hidden under it.
- **Sections:** the heading settles 18px as its section arrives. Nothing else in a section moves
  on scroll.
- **Controls:** 180ms color/transform; press .97; arrows nudge on hover. FAQ opens with height
  (`::details-content`).
- Only `transform` / `opacity` (heights only for collapsing rows, via WAAPI). Reduced motion:
  no entrances, every sequence completes instantly.

## 7. Navigation

- The macOS menu bar, fixed top, 33px like a notched MacBook's (44px under 1024px, for touch): the dotfn mark
  "• fn" (small dot + fn, monochrome, where macOS puts the Apple logo; links to dotfn.dev) → **BrewMenu** (bold, like the app
  name in a real menu bar) → section links (≥1024px) → GitHub ★ → `ES`/`EN` → the live status
  item → the visitor's own clock (≥640px). Under 1024px the links collapse into a `<details>`
  menu (44px button).
- Primary action: **Download** (latest release .zip). Secondary: copy
  `brew install --cask dotfn/tap/brewmenu`.

## 8. States

- GitHub data missing at build → stars hidden, version and size omitted ("Cask brewmenu",
  ".zip"). Never "0 stars". The build reads an optional `GITHUB_TOKEN` (set it on Vercel): without
  it the API rate-limits (403) and everything falls back.
- Copy button: idle "Copy" → "Copied" for 1.5s; clipboard failure → selects the command text.
- Mocks show realistic data (real formula names, real version shapes) — never lorem.

## 9. Focus, keyboard, touch

- `:focus-visible`: 2px `ink` outline, 3px offset, radius follows the control.
- Hit areas ≥ 44px on touch, ≥ 24px pointer.
- Two mocks are real controls: the hero popover (Upgrade, Upgrade All, reset are `<button>`s;
  focus moves to the next Upgrade when a row leaves) and 01's Dashboard window (`role=group`):
  sidebar items are buttons with `aria-current`, plus every row/pane control. Window buttons that
  look 22–32px tall carry a 44px hit area on phones (24px pointer) around a smaller pill.
  Every other mock is `aria-hidden` décor.
- FAQ uses `<details>`.
- Never disable zoom.

## 10. Writing

- Plain, specific, second person. Name what the app does with the brew command it runs.
- Never "seamless", "powerful", "effortless", "supercharge", "unlock".
- The license is **AGPL-3.0**. Requirements: **macOS 26 (Tahoe) or later**. Price: **Free**.
- Spanish uses voseo (rioplatense), matching the app.
- Don't claim what the app doesn't do (no ratings, no telemetry, no account).

## 11. Rejected on sight

- App Store pastiche (GET button, info strip, "Ratings & Reviews" with nothing in it) — the
  page is a product page, not a store listing.
- Fade-rise on every block of every section — motion as wallpaper. Only the section's
  hairline and heading move.
- **A flat, static page.** The redesign read as lifeless. The rule since: every mock of the app
  shows its own cause and effect when seen and answers clicks.
- **Section labels** (a hairline + mono `01 — Name` above every section): removed on request —
  the headings carry the sections on their own.
- **Decorative ambient effects** (a pointer-following sheen, a bouncing hint arrow): read as
  unnecessary. Exception, asked for by the person: the hero is a glass of beer, so it has
  carbonation and foam (§6) — bubbles belong to the liquid, never floating over other sections.
- **A macOS imitation that isn't macOS.** The first menu bar (Geist 14px, white-tinted bar, a
  generic beer icon on an amber chip) read as cheap. Anything that stands for macOS uses the
  system font stack (SF Pro / SF Mono on a Mac), Apple's neutral grays via `.mac-ui`, the
  Tahoe glass edge via `.mac-glass`, and the app's real visuals: the status item is the count +
  a filled mug in the "updates" amber with no background (#6B4D00 on the wallpaper: the app's #9E7300 measured 2.95:1 there; #D99E0D on dark), the popover
  header is the amber arrow-down circle (green check when up to date), menu bar highlights (hover, open item) are capsules (`rounded-full`), as in Tahoe —
  a 7px rounded rect read as older macOS; popovers hang ~5px
  under the menu bar; the bar is 33px, the height of the real one on a notched MacBook. SF Symbols can't ship on the web: draw our own glyph with the same
  silhouette (`mac/MugGlyph.astro`).
- Screenshots of the app where HTML can rebuild the UI — screenshots go stale (the old ones
  showed 1.2.9 after 1.5 shipped).
- Blurred color blobs behind the hero.
- **A reference's page skeleton, reskinned.** The first build read as a copy of dotphin and
  ThisDay: centered icon + "New in" pill + two-tone headline + download/brew pill, tilted
  product stage, three-glyph facts row, bottom glass bar with side pills, closing card. The
  references are mood (warmth, restraint, real UI in HTML), never the composition. Any
  section whose layout can be matched one-to-one to a reference section gets redesigned
  from BrewMenu's own subject: the menu bar, the popover, brew's own output.

## 12. Known traps

- `.claude/` is gitignored at the repo root, and `web/.gitignore` ignores `.agents/skills/`
  (installed tooling). This skill is project content: it is only versioned with the exception
  `!.agents/skills/brewmenu-web/` in `web/.gitignore`.
- The GitHub API is unauthenticated at build and can rate-limit; all fetches have fallbacks.
- Content scrolling under a transparent menu bar collides with the menu titles. The bar frosts
  (amber glass) at the first scrolled pixel and takes page tones past the hero (`data-scrolled`,
  `data-past`); the hero itself never scrolls under it, it pins and gets covered.
- A rounded sheet that starts where the hero ends shows the page background (black in dark
  mode) in its corners, plus any edge highlight as a light arc. The sheet overlaps the hero by
  its own radius (`margin-top: −r`) and has no edge line.
- A borrowed motion goes where the person points: bema's stack was first applied to the feature
  rows, but it was wanted on the hero. Ask "applied to what?" when a reference's motion arrives.
- Grid items default to `min-width: auto`: a long command (the curl one-liner) or the terminal
  `<pre>` widened the page to 928px on phones. Grids holding pills or `<pre>` get
  `[&>*]:min-w-0`.
- Unlayered base CSS beats Tailwind utilities: `p { text-wrap: pretty }` silently undid
  `truncate`. Base rules live in `@layer base` and use `text-wrap-style`, not the shorthand.
- An `overflow-x-auto` wrapper clips a mock window's shadow into a visible rectangle. Mock windows
  reflow instead of scrolling (the Dashboard drops its sidebar under 640px).
- A selection drawn by a separate sliding element is invisible to the contrast audit: the item's
  white text measured 1.08:1. The item takes the same fill itself once the highlight lands.
- Don't dim inactive steps with opacity: 0.45 took body text to ~2:1. Quiet them with `ink-3`.
- A wide table scrolled sideways hides its last column on phones — for 05 that was BrewMenu's
  answer. Under 640px each row stacks: label, ✓ BrewMenu, then "brew in a terminal: …".
- Two things that are alternatives are not steps: 07 Install had "1" / "2" over "With Homebrew" /
  "Or download". Now an "or" rule between them, no numbers.
- 07 is for converting, not for showing: a Terminal playing the real `brew install --cask` and a
  mini menu bar with the item popping in were built and removed ("too much, doesn't convert").
  Both actions stay in view with nothing to wait for; the only motion is the page's own menu bar
  item nudging when you copy or download. `brew install --cask dotfn/tap/brewmenu` needs no
  `brew trust` on Homebrew 7: naming the full tap/cask in an install counts as explicit
  permission (`Trust.explicitly_allowed?`).
- Any control on a dark terminal needs the light focus ring (`.term-window :focus-visible`).
- 04 has no shortcuts menu (removed on request); its copy column centres on the terminal.
- 04 terminal: plain streamed text, no package chips or in-output banner — tried and removed on
  request. BrewMenu's notice is one line of output ("BrewMenu › Couldn't upgrade opencode ·
  2 upgraded · Retry:") followed by the retry command. It reads as a macOS Terminal window: a
  hairline rim and top highlight (it had no edge on the dark page), a lighter title bar titled
  "BrewMenu — Upgrade All" in SF; the progress is the title bar's bottom hairline (amber), not a
  strip under the output. Commands are typed at a `~ $` prompt (22–52ms a character); blank lines
  group brew's output, BrewMenu's note and the retry; the run ends back at an idle `~ $` with the
  cursor blinking.
- Tailwind 4's `scale-x-0` sets the CSS `scale` property, not `transform`: a script writing
  `style.transform = scaleX(p)` never grew a bar that had the class (the terminal's progress and
  Cache's clean-up bar were stuck at 0). Bars driven by script start with an inline
  `transform: scaleX(0)` instead.
- 01's Upgrade All and the 04 terminal must not show the same run. 01 upgrades everything
  cleanly; 04 is Upgrade All where one package fails, BrewMenu names it, and Retry runs only that
  one — the claim of `term.point3`, shown. A long terminal line gets cut at ~70 chars on desktop.
- Prose is never Geist Mono: an old Dashboard caption was mono and read as code.
- `#features` sits on the scene (`[data-scene]`), not on the section: on the section it landed on
  the top padding, before the window pins, showing an empty band and the hero's edge. Desktop
  `scroll-margin` 33px (lands pinned, step 01); phones 64px (lands on the heading).
- `href="#top"` does nothing: the hero is `position: sticky`, so the browser treats it as already
  on screen. Every `a[href="#top"]` is handled by script: smooth scroll to 0, then the status item
  bumps and the popover opens if closed ("Then look up" lands on the menu bar).
- `/_vercel/image` doesn't exist under `astro preview`; images only render there on Vercel.
  Look at pages with `astro dev` (its dev toolbar is not part of the page).

## 13. Icon and social image

- The app icon has one source: `design/BrewMenu-Icon-Source.psd` (a flattened render: glass mug
  of beer + a package box on a dark squircle, opaque black canvas). Every icon is generated from
  it by `python3 scripts/icon/build-icons.py`: the app's `Sources/Resources/AppIcon.icns`
  (macOS grid, body 824/1024, all iconset sizes), `brewmenu.png`, and in `web/public` the
  favicons (.ico/.svg/16/32, tight crop), `apple-touch-icon.png` (opaque, zoomed past the
  artwork's wider corners), `icon-192/512.png` (manifest) and `app-icon-96.png` (03's
  notification). Never edit those files by hand; change the PSD and rerun.
- The PSD's body edge is where luminance passes 20: a faint glow and a black pixel sit just
  outside it, and counting them left a black ring on light backgrounds. The mask is the fitted
  rounded rect (r 244 on 1007) ∩ the artwork's own silhouette, both inset 3px.
- `og-image.png` (2400×1260) is the hero in small: amber wallpaper, the icon, "Homebrew, in
  plain sight.", the install command, the meta line. Rendered from HTML in Chrome so it uses the
  page's own fonts; redo it when the hero's words change.

## 14. Before calling it done

Run the audit against the built site:

```bash
pnpm build && pnpm preview --port 4321 &
# audit.mjs resolves playwright-core from the cwd's package.json: run it from a scratch
# folder that has it (`npm i -D playwright-core`), not from web/.
node ~/.cursor/skills/dotfn-audit/scripts/audit.mjs --url http://localhost:4321 \
  --config /path/to/web/dotfn-audit.json
```

What the audit can't judge — a human looks at: the popover mid-upgrade and "Up to date", the
popover's alignment under the status item at 1024 / 1440 / 1920px, dark mode, and 320px.
