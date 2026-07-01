# BrewMenu — Roadmap

Estado actual de cada versión. Los ítems tachados están completos y en `main`.

---

## v0.1 — Menu bar básica ✅
- Menu bar con `MenuBarExtra` + popover SwiftUI
- `EnvironmentResolver`: detecta brew en `/opt/homebrew`, `/usr/local`, o path custom
- `BrewService` actor: ejecuta `brew outdated --json=v2`
- Listar paquetes desactualizados con versión instalada → disponible
- Botón "Upgrade All" con streaming de stdout línea por línea
- Notificación básica cuando aparecen updates nuevos

## v0.2 — Doctor y progreso ✅
- `brew doctor` integrado: parseo de warnings y errors
- Streaming real de `brew upgrade` (no spinner indeterminado)
- Cancelación de upgrade en curso
- Estado del ícono en la menu bar: 🟢🟡🟠🔴 según salud

## v0.3 — Historia e insights ✅
- `HistoryStore` actor: guarda un snapshot JSON por chequeo, rota a 30 días
- `InsightEngine` puro: compara snapshots y genera `[Insight]`
- Insights implementados: cleanup pendiente, doctor sin correr, updates estancados

## v0.4 — Servicios ✅
- `brew services list --json`: lista servicios con estado started/stopped/error
- Start / stop de servicios desde el popover
- Insight: servicio que pasó de started a stopped entre snapshots

## v0.5 — Casks ✅
- `brew list --cask --versions`: inventario de casks instalados
- Insight: cask sin actualizaciones disponibles por más de N días

## v1.0 — Distribución ✅ / ⏳
- ✅ Onboarding (3 pasos: bienvenida, notificaciones, detección de brew)
- ✅ Settings: frecuencia, login item, notificaciones por categoría, path custom de brew
- ✅ Localización EN/ES según idioma del sistema
- ✅ Ícono de app (`AppIcon.icns`, 16→1024 px con variantes @2x)
- ✅ Logging a `~/Library/Application Support/BrewMenu/logs/brewmenu.log` (rotativo 5 MB)
- ✅ Build script (`scripts/build-release.sh`): ensambla `.app`, firma ad-hoc, genera ZIP + SHA256
- ⏳ Firma con Developer ID + notarización (requiere Apple Developer Program)
- ⏳ Sitio web mínimo (README / landing page)

---

## Backlog (post-v1)
- Upgrade de paquete individual desde la lista
- Badge numérico en el ícono de la menu bar (`🍺 3`)
- Soporte para múltiples taps
- Dark/light mode del popover independiente del sistema
- Migración de persistencia a SQLite/GRDB si los insights requieren queries complejas
