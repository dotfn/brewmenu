# Architecture

BrewMenu is a native macOS menu bar app for Homebrew. It is two SwiftPM targets (`BrewCore`,
`BrewMenu`) plus their tests. There are no third-party dependencies.

```text
Views → ViewModels → BrewServicing (protocol) → BrewService → brew CLI
                                             ↘ HomebrewAPIClient → formulae.brew.sh
BrewCore: models, BrewError, L10n — no UI, no process or network code
```

## Layers

| Folder/target | What lives there |
| --- | --- |
| `Sources/BrewCore/` (separate SPM target `BrewCore`) | Plain value types, `BrewError`, `L10n`/localisation helpers — the domain layer the rest of the app depends on. No UI, no process or network code, so it can't accidentally pick up a dependency on either. |
| `Sources/App/` | Scenes, the app delegate, the menu bar icon, notifications, shared card styling. |
| `Sources/Features/` | One folder per area (MenuBar, Dashboard, Settings, Onboarding, Notifications): SwiftUI views and their `@Observable` view models. |
| `Sources/Services/` | Everything that touches the outside world: brew, the network, the file system and background checks. |

Nothing enforces the `App`/`Features`/`Services` split at compile time — it's a convention, checked
in review. `BrewCore` is the one boundary the compiler actually enforces: `Sources/Features/**` and
`Sources/Services/**` can't see each other's internals, but both can only reach models/errors/L10n
through `BrewCore`'s public API.

## Services

- **`BrewService`** (actor) runs brew through `ProcessRunner`. It is the only place that parses brew
  output. View models depend on the `BrewServicing` protocol, which keeps them testable with mocks.
- **Serialised brew commands.** Every mutating entry point takes a FIFO gate (`acquireBrewLock`).
  Homebrew takes its own lock, so two mutating commands must never run at once. A cancelled
  command releases the gate only after its process has exited.
- **`ProcessRunner`** runs each command as the leader of its own process group, so cancelling stops
  brew and everything it started. Output is drained to end-of-file before a result is reported.
- **`OrderedStream`** delivers streamed output to the main actor in order.
- **`StatusChecker`** runs the periodic check. Each result carries the time its query started.
  `MenuBarViewModel` drops results older than its last foreground fetch, so a late check cannot
  overwrite fresh state.
- **`EnvironmentResolver`** finds the brew binary and the `brew shellenv` output. A failed bootstrap
  is retried by the next operation.
- **Stores:** `SettingsStore`, `HistoryStore`, `InstalledPackagesCache` and `HomebrewAPIClient`'s
  cache each take an injectable directory, so tests never touch real data.

## Data locations

| Data | Location | Rebuildable |
| --- | --- | --- |
| Settings and history snapshots | `~/Library/Application Support/BrewMenu` | No |
| Installed-package snapshot, catalogue responses, askpass helper | `~/Library/Caches/BrewMenu` | Yes |
| Log (`brewmenu.log`, one backup) | `~/Library/Logs/BrewMenu` | — |

Setting `BREWMENU_DATA_DIR` moves all three under one folder. Use it for any run that must not
touch real data.

## Testing

- `swift test` runs the unit tests (`Tests/BrewMenuTests`, 299 as of this writing). CI
  (`.github/workflows/ci.yml`) runs them on pushes and pull requests to `main`.
- View models are tested with mocks of `BrewServicing`. Process behaviour is tested against real
  shell commands.
- Tests wait on observable conditions with `waitUntil` (in `TestHelpers.swift`), not fixed sleeps.
- **UI tests** (`Tests/BrewMenuUITests`, XCUITest) drive the real app through `XCUIApplication` —
  launch smoke test, upgrade flow, visual regression. SwiftPM has no XCUITest support, so these
  run through a generated Xcode project instead: `xcodegen generate` (config in `project.yml`)
  produces `BrewMenu.xcodeproj`, then `xcodebuild -project BrewMenu.xcodeproj -scheme BrewMenu
  -destination 'platform=macOS' test -only-testing:BrewMenuUITests`. `UITestEnvironment`
  (`Tests/BrewMenuUITests/UITestSupport.swift`) points the launched app at a throwaway data
  directory and a committed fake `brew` script (`Fixtures/fake-brew`) — no real Homebrew call.
  Wired as `.github/workflows/ui_tests.yml`, **manual (`workflow_dispatch`) only** — a hosted
  runner's accessibility permissions for driving the menu bar aren't verified yet, so it's kept off
  the pull request path.
- The committed `BrewMenu.xcodeproj` is generated output, not hand-edited — change `project.yml`
  and re-run `xcodegen generate` instead of editing the `.xcodeproj` directly.
