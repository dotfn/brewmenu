# Architecture

BrewMenu is a native macOS menu bar app for Homebrew. It is one SwiftPM executable target plus its
tests. There are no third-party dependencies.

```text
Views → ViewModels → BrewServicing (protocol) → BrewService → brew CLI
                                             ↘ HomebrewAPIClient → formulae.brew.sh
```

## Layers

| Folder | What lives there |
| --- | --- |
| `Sources/App/` | Scenes, the app delegate, the menu bar icon, notifications, shared card styling and localisation helpers. |
| `Sources/Features/` | One folder per area (MenuBar, Dashboard, Settings, Onboarding, Notifications): SwiftUI views and their `@Observable` view models. |
| `Sources/Services/` | Everything that touches the outside world: brew, the network, the file system and background checks. |
| `Sources/Models/` | Plain value types shared across layers. Models carry no UI or I/O. |

Nothing enforces these boundaries at compile time. They are a convention, checked in review.

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

- `swift test` runs the unit tests. CI runs them on every push and pull request.
- View models are tested with mocks of `BrewServicing`. Process behaviour is tested against real
  shell commands.
- Tests wait on observable conditions with `waitUntil` (in `TestHelpers.swift`), not fixed sleeps.
- There are no UI tests. Views are verified by hand; see the checklist in the pull request template.
