# AGENTS.md

Guidance for AI agents (and humans) working in this repo. BrewMenu is a native macOS
menu bar app for Homebrew — SwiftUI, SPM package, no Xcode project file. Read this
before touching UI code; several of the decisions here were expensive to arrive at
and are easy to accidentally undo.

## Build & test

```bash
swift build                          # debug
swift build -c release               # release
swift test                           # 228 tests, Swift Testing framework
./scripts/build-release.sh <version> # assembles build/BrewMenu.app, ad-hoc signs, zips
```

There is no `.xcodeproj`. Xcode can open `Package.swift` directly and run the
executable target, but that run has **no real `Info.plist`** (`Package.swift` excludes
it from the target's resources — only `scripts/build-release.sh` copies
`Sources/Info.plist` into the packaged `.app`). If something behaves differently
between an Xcode/`swift run` debug session and the packaged `.app`, check whether it's
Info.plist-dependent before assuming it's a build-configuration (debug vs release)
difference — both are real, distinct variables.

Deployment target is `.macOS(.v15)` (`Package.swift`). Anything from a newer SDK
needs `if #available(macOS XX, *)` with a working pre-XX fallback — see the SDK
`.swiftinterface` files under `MacOSX*.sdk/System/Library/Frameworks/*/Versions/A/
Modules/*.swiftmodule/` if you need to verify an API's exact availability rather than
guessing.

**Trust `swift build`/`swift test`, not the editor's live diagnostics.** SourceKit's
background index has repeatedly shown stale "no member X" errors on code that
compiles and passes fine — e.g. right after adding a method to `DashboardViewModel`,
call sites in `DashboardViewModelTests.swift` flagged it as missing for several
minutes. If a diagnostic disagrees with an actual `swift build`/`swift test` run, the
build is right.

**Test doubles that own on-disk state take an injectable `directory: URL? = nil`**
(`InstalledPackagesCache`, `HomebrewAPICache`, `SettingsStore`) so tests can point them
at an isolated temp directory instead of the real `~/Library/Application Support/
BrewMenu`. `OnboardingViewModel` takes an injectable `defaultsStore: UserDefaults =
.standard` for the same reason, scoped to an isolated `UserDefaults(suiteName:)` in
tests. Follow this pattern for any new actor/service that persists to disk or
`UserDefaults` — it's what makes it possible to test without touching the real
machine state.

## Architecture

- `Sources/App/BrewMenuApp.swift` — two scenes: `MenuBarExtra(.window)` (the popover,
  `MenuBarView`) and `Window("BrewMenu Dashboard", id: "dashboard")` (`DashboardView`,
  a `NavigationSplitView`). Runs as `NSApplication.shared.setActivationPolicy(.accessory)`
  (menu-bar-only, no Dock icon) — set explicitly in code, not just via Info.plist's
  `LSUIElement`, so it's identical in both debug and packaged runs.
- `DashboardViewModel` / `MenuBarViewModel` / `SettingsViewModel` — `@Observable`
  view models, one per major surface. `BrewService` wraps the actual `brew` CLI calls;
  `HomebrewAPIClient` talks to formulae.brew.sh for trending/detail/analytics data.
- `BrewMenuAppDelegate.applicationShouldTerminateAfterLastWindowClosed` returns
  `false`. AppKit's undeclared default is `true` — for an accessory/menu-bar-only app,
  that would quit the whole app (menu bar item included) the moment the Dashboard
  window closes, since `MenuBarExtra`'s popover doesn't count as a "window" for that
  check. Don't remove this override.
- The Dashboard's detail pane (`DashboardView.detailContent`) switches over
  `DashboardSection` to pick which screen renders — see the composition rule below
  before adding a new case.
- `DashboardViewModel` holds an optional `MenuBarViewModel` reference
  (`attachMenuBarViewModel(_:)`, wired once in `BrewMenuApp.init()`) so it can read
  outdated-package state directly instead of keeping its own copy. It's a plain
  optional property + setter, not a required `init` parameter — `DashboardViewModel`
  is constructed directly in ~25 places across `DashboardViewModelTests.swift`, and a
  required param would force touching every one for a dependency most of those tests
  don't care about.

## State ownership rules

Learned the expensive way during a state-management pass — read before adding new
`@Observable` state anywhere in `Sources/Features`.

- **Never mirror another view model's state via `View.onChange` + a manual push.**
  If `DashboardViewModel` needs something `MenuBarViewModel` owns (or vice versa),
  give it a direct reference (see `attachMenuBarViewModel(_:)` above) and read the
  source directly. A `View.onChange`-pushed copy is only ever correct while that
  specific view happens to be mounted — it's a synchronization bug waiting for a
  second reader.
- **A "failed X" `Set<String>` is always derived from its error dictionary, never
  stored separately.** `failedInstallNames`/`failedUninstallNames` are computed
  (`Set(installErrors.keys)` / `Set(uninstallErrors.keys)`) — there used to be a
  parallel `Set` mutated in lockstep with each dictionary, which is just a second
  place the same fact can drift out of sync. If you add a new kind of per-item
  failure tracking, give it one `[String: String]` (name → real reason) and derive
  the "did this fail" `Set` from its keys, don't track both.
- **A flag that must be read synchronously before any `Task` runs (checked at
  `BrewMenuApp.init()` time, e.g. onboarding-completed) belongs in `UserDefaults`,
  not `AppSettings`/`SettingsStore`.** `SettingsStore.settings` is only available via
  `await`, which doesn't work at that point in the app's startup. Don't reintroduce a
  duplicate flag in `AppSettings` "for consistency" — `UserDefaults` is the one and
  only place this specific kind of flag can live correctly.
- **`DashboardViewModel` is injected via `@Environment` only for the reusable
  package-row family** (`PackageBrowseRow`/`PackageStatusIndicator`/
  `InstalledStatusButton`/`PackageInfoButton` in `StatusBadge.swift`) — every other
  view (`HomeView`, `InstalledView`, `CategoryView`, etc.) still takes it as an
  explicit `let` parameter. Don't widen the `@Environment` usage to feature-root
  views; there's no real prop-drilling to solve there, and explicit parameters keep
  those call sites compile-checked. The `.environment(dashboardViewModel)` modifier
  itself lives outside the `NavigationSplitView`'s `detail:` closure, on the whole
  view's modifier chain — scoping it to just `detail:`'s content does *not* reach
  `.sheet(...)` presentations (`PackageDetailView`, `InstallLogView`), which present
  outside that subtree.
- **Don't split a class with many `private`/`private(set)` stored properties into
  multiple `extension` files.** Swift's `private` (including `private(set)`) is
  scoped to the *file*, not the type — SE-0169 only shares private access between
  extensions of the same type in the *same* file. Moving methods that read/write
  those properties into a sibling file requires loosening them to `internal`, which
  means any `View` in the module could then mutate that state directly, bypassing
  whatever method used to be the only writer. This killed a planned
  `DashboardViewModel` file-split (see git history) — the file stays one piece
  unless it grows enough to justify actually paying that cost.

## Shared UI components — use these before writing new ones

`Sources/App/CardStyle.swift`:
- `CardCornerRadius` — the app's one corner-radius scale (`.large/.medium/.small/.compact`).
- `.cardBackground(_ radius:)` — the one card fill (`.quaternary.opacity(0.4)`) every
  card-like container uses.
- `LoadingView` — centered loading spinner, `label:`/`fillHeight:` cover the real variants.
- `RestartBanner` — the "BrewMenu updated — restart to apply" banner (popover + Dashboard).
- `SearchField` — the rounded search field used by `InstalledView`'s toolbar search
  and `MenuBarView`'s popover filter. Global "search all of Homebrew"
  (`DashboardView`'s `.searchable(placement: .sidebar)`) is a *different*, intentionally
  separate feature — don't merge them.
- `SectionHeader` — the title above a group of rows/cards. `.standard` (Dashboard
  window) vs. `.compact` (popover) is a deliberate scale difference, not drift.
  **No `.glassEffect()` on this, ever** — see the Liquid Glass rule below.
- `ScrollableEmptyState` — wraps a non-scrollable empty state (`ContentUnavailableView`)
  in a `ScrollView` it'll never actually scroll in. Required for every
  `ContentUnavailableView`-only branch in the Dashboard — see the titlebar-separator
  section below for why.

`Sources/Features/Dashboard/StatusBadge.swift`:
- `StatusBadge` — the pill badge (Outdated/Deprecated/Disabled).
- `PackageStatusIndicator` — the trailing installed/outdated/installing/install icon.
- `PackageInfoButton` — the info-circle button that opens a package's detail sheet.
- `PackageBrowseRow` — the row shape shared by every "browse to install" list
  (Trending, Search Results, Third-Party's available-packages section): icon,
  monospaced name, optional `leading`/`trailing` slots, info button, status indicator.

Before adding a new row/card/header/button anywhere in `Sources/Features/Dashboard` or
`Sources/Features/MenuBar`, check whether it's the same shape as something already
above — 2+ genuinely identical occurrences is the bar for extracting a shared
component (not 1, not "looks similar"), matching what's already here.

## Design philosophy

- **Flat by default.** Dashboard content (Home, Installed, Categories, Ecosystems,
  Package Detail) deliberately avoids native List/Section chrome in favor of the flat
  card/row language above. `ThirdPartyEcosystemsView` is the one exception — it
  needs real `List { Section }` for its per-tap grouping, and needs `.listStyle(.plain)`
  specifically (see gotcha below).
- **Native chrome stays native where it's already conventional**: the sidebar
  (`List(selection:)` inside `DashboardView`) and Settings (`Form { Section }` with
  `.formStyle(.grouped)`) intentionally keep standard macOS chrome — don't flatten those.
- **Ponytail engineering**: reuse over rewrite, minimal diffs, no abstraction for a
  single call site, no speculative future-proofing. When in doubt, grep for the
  pattern first (`grep -rn` across `Sources/Features`) before writing new code.

## Liquid Glass / HIG rules

Apple's Liquid Glass guidance draws a hard line between the **navigation layer**
(toolbars, sidebars, tab bars — gets `.glassEffect()`) and the **content layer** (list
rows, section headers, cards — does *not*). We hit this directly: an earlier version
wrapped `SectionHeader` in `.glassEffect()` and it read as a narrow, misplaced pill
competing with the real toolbar chrome. Rule going forward:

- **Never** apply `.glassEffect()`/`Glass` to content-layer views (rows, section
  headers, cards). Native `List`/`Form`/toolbar/sidebar components already get Liquid
  Glass automatically on macOS 26 — you don't opt them in, you just don't fight them.
- Destructive actions use `role: .destructive` on the `Button`, not a manual
  `.foregroundStyle(.red)` — the system applies the correct tint automatically,
  including under Increased Contrast. See `ThirdPartyEcosystemsView`'s "Remove Tap"
  and every `confirmationDialog` in `InstalledPackageRow`/`MenuBarView` for the pattern.
- Prefer native `.searchable(placement:)` over a custom search-field component when
  the search is toolbar-scoped (macOS renders it in the same glass toolbar surface as
  other controls automatically) — `SearchField` still exists for the one case
  (`MenuBarView`'s popover) that isn't inside a `NavigationSplitView`/`NavigationStack`
  and can't use `.searchable` at all.
- Any macOS-26-only API needs `if #available(macOS 26, *)` with a real pre-26 fallback
  (deployment target is `.v15`) — verify the API actually exists in the SDK's
  `.swiftinterface` before writing the gate; don't guess signatures.
- **`.alert()` cannot show a custom icon or tint on macOS.** `NSAlert` (what
  SwiftUI's `.alert()` uses under the hood) dropped its distinct
  informational/warning/critical icon styling in Big Sur — it only ever shows the
  app's own icon, and there's no public API to force a colored warning icon into it.
  If a failure needs a red icon specifically, that requires a custom-built view (a
  banner/sheet, not `.alert()`), which trades away the system's native accessibility/
  keyboard handling — confirm that trade is actually wanted before building one; for
  most failures, improving the `.alert()`'s title/message text is the right fix, not
  chasing an icon the API can't give you.

## Known gotcha: toolbar icon-button state swaps break the hover chrome

**Symptom**: an icon-only toolbar button (`ToolbarItem(placement: .primaryAction)`,
no explicit `.buttonStyle`) that swaps between an idle icon and a `ProgressView` while
some action runs — the circular hover highlight looks right, but the *resting* state
looks broken/malformed, or the pill visibly changes size when the state flips.

**What it is not**: not a sizing problem you fix by wrapping both branches in a
`.frame(width:height:)` — that was tried first, fixed the size-jump, but made the
resting-state chrome look worse, not better.

**What it actually is**: macOS computes the automatic circular hover chrome for
icon-only toolbar buttons from the `Button` itself. An `if isRefreshing { ProgressView()
} else { Button { ... } }` at the `ToolbarItem`'s root swaps the *type* of view
mounted there on every toggle — the system loses track of which `Button` it computed
that chrome for, and recreates it, which is what breaks the resting state (the
hover-triggered recompute happens live and still looks right; only the cached resting
appearance breaks). Fix: keep **one** `Button` permanently mounted, and swap only its
`label:` content between the icon and the `ProgressView`, with `.disabled(isRunning)`
instead of removing the button. See the refresh button in `HomeView.swift` for the
working pattern.

## Known gotcha: the Dashboard's titlebar separator

This took several wrong turns to get right — read this before touching anything
related to `titlebarSeparatorStyle`, `NavigationSplitView` chrome, or a "line
appears/disappears under the header" report in the Dashboard window.

**Symptom**: a hairline separator under the window's titlebar/toolbar
(`NSWindow`/`NSSplitViewItem.titlebarSeparatorStyle`, left at `.automatic`, the
correct HIG default — do not override it) appears or disappears inconsistently
switching between sidebar sections, or even revisiting the *same* section.

**What it is not**: not a race to "win" by reapplying `.none` on a timer, in
`layout()`, via KVO, or deferred through `DispatchQueue`/`Task` — all of those were
tried and each either didn't fully work or worked in debug but not in the packaged
release build (Swift/AppKit's exact layout timing differs between configs). Don't
reintroduce any of that; the user explicitly wants 100% native `NSWindow` behavior,
no imperative patches.

**What it actually is — two distinct root causes, both compositional**:

1. **A section's scrollable container isn't the single top-level view of its detail
   pane.** AppKit's automatic separator computes "is this pane's content scrolled
   under the toolbar" from the *outermost* scrollable view's own safe-area offset. If
   a `List`/`ScrollView` sits one level down inside a `VStack` (e.g. a search field or
   error banner as a sibling above it), that section computes its scroll-edge state
   differently from a section where the `List` is handed directly to the pane. Fix:
   make the scrollable container the single top-level view everywhere, and attach any
   fixed header content via `.safeAreaInset(edge: .top)` on that container instead of
   a `VStack` sibling (see `InstalledView`, `RecommendedTapsView`). A bare `VStack`
   wrapping a single conditional branch has the same problem even with no siblings —
   use `Group` instead (see `ToolSection` in `DashboardView.swift`).

2. **A branch has no scrollable container at all** (a bare `ContentUnavailableView`
   empty state). With nothing to measure, AppKit falls back to carrying over whatever
   separator state the *previously displayed* section left behind — so the same,
   unchanging empty state shows or hides the line depending on navigation history.
   Fix: wrap every such branch in `ScrollableEmptyState` (`CardStyle.swift`) — a real
   `ScrollView` (with `.containerRelativeFrame(.vertical)` to preserve the fill/center
   layout) that never actually needs to scroll, existing purely so the separator
   computation has something real to measure.

If a new Dashboard section is added, or an existing one's top-level structure
changes, check both: is the scrollable container (if any) the single top-level view,
and is every non-scrollable empty-state branch wrapped in `ScrollableEmptyState`?

Separately, `ThirdPartyEcosystemsView` needs `.listStyle(.plain)` for an unrelated,
earlier-diagnosed reason: the default/`.inset` macOS `List` style gives `Section`
headers their own vibrancy-backed material with a baked-in bottom hairline that visibly
doubles with the List's own row separator once `.scrollContentBackground(.hidden)`
removes the opaque backing that normally hides the seam. Don't remove `.plain` there
without re-solving that separately.
