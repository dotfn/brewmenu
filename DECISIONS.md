# BrewMenu — Decisiones técnicas

Registro de las decisiones de diseño no obvias, con su contexto y razonamiento.
Cada entrada incluye la fecha en que se tomó la decisión.

---

## 2026-06 — SwiftUI + `MenuBarExtra` en lugar de AppKit puro

**Decisión:** Usar `MenuBarExtra` de SwiftUI para la presencia en la menu bar, sin tocar AppKit salvo donde es estrictamente necesario (gestión de ventanas de Settings y Onboarding con `NSWindow`).

**Por qué:** `MenuBarExtra` está disponible desde macOS 13 y es la API oficial para apps de menu bar en SwiftUI. AppKit puro requiere más boilerplate y acoplamiento con `NSStatusItem` / `NSPopover` directamente. La única excepción son las ventanas modales, que SwiftUI no permite controlar con suficiente precisión desde una app `.accessory`.

**Trade-off aceptado:** `MenuBarExtra` tiene algunas limitaciones de animación y tamaño de popover en comparación con un `NSPopover` puro. Para v1, estas limitaciones son aceptables.

---

## 2026-06 — `BrewService` como actor

**Decisión:** `BrewService` es el único punto que ejecuta `Process`, implementado como `actor` de Swift.

**Por qué:** Serializa las ejecuciones de brew automáticamente: nunca corren dos comandos `brew` en paralelo, sin necesidad de locks manuales. Si llega una segunda solicitud mientras hay un comando corriendo, el actor la encola. Esto evita corrupción del estado de Homebrew y condiciones de carrera en los resultados.

---

## 2026-06 — Protocolo `BrewServicing` para testing

**Decisión:** `BrewService` implementa el protocolo `BrewServicing`. Los tests usan implementaciones mock de ese protocolo en lugar de ejecutar `brew` real.

**Por qué:** Sin esto, los unit tests requieren una instalación de Homebrew funcional, son lentos (red + procesos reales), y no deterministas. Con el protocolo, `InsightEngine`, `StatusChecker` y `MenuBarViewModel` son testeables con fixtures sintéticas. Los tests que tocan brew real van a un target separado (`BrewMenuIntegrationTests`) y no corren en CI.

---

## 2026-06 — `InsightEngine` como enum con métodos estáticos puros

**Decisión:** `InsightEngine` es un `enum` sin casos (namespace) con métodos estáticos que reciben `[Snapshot]` y devuelven `[Insight]`. Sin filesystem, sin red, sin estado.

**Por qué:** Al ser puro, es trivialmente testeable con arrays sintéticos. No hay mocks necesarios. Cualquier cambio en las reglas de insight tiene cobertura inmediata. El trade-off es que para reglas que necesitaran acceso a disco habría que refactorizarlo, pero para v1 no aplica.

---

## 2026-06 — JSON sobre SQLite para persistencia

**Decisión:** Los snapshots se guardan como archivos JSON individuales en `~/Library/Application Support/BrewMenu/snapshots/`. No se usa SQLite en v1.

**Por qué:** Un archivo JSON por snapshot es simple de implementar, debuggear e inspeccionar manualmente. No requiere dependencias externas (GRDB) ni migraciones de esquema. El volumen de datos es bajo: máximo 30 snapshots de ~10–50 KB cada uno = <1.5 MB. Si en el futuro los insights requieren queries que no son viables con arrays en memoria, se evalúa SQLite.

---

## 2026-06 — Cero dependencias externas en v1

**Decisión:** No se agregan paquetes Swift externos al proyecto.

**Por qué:** Reduce la superficie de ataque, elimina el riesgo de incompatibilidades con futuras versiones del toolchain, y simplifica el build reproducible. Todo lo necesario para v1 (concurrencia, JSON, FileManager, UserNotifications) está en los frameworks de Apple.

**Excepción futura:** Si se decide migrar a SQLite, GRDB es la única dependencia candidata aprobada.

---

## 2026-06 — `Picker(.segmented)` en lugar de `TabView` en Settings

**Decisión:** La ventana de Settings usa un `Picker` con estilo `.segmented` + un `@ViewBuilder switch` para el contenido, en lugar de `TabView`.

**Por qué:** `TabView` en macOS aplica capas de `NSVisualEffectView` con materiales de vibrancy distintos para el selector de tabs y el contenido, resultando en tres zonas de color distintas en la misma ventana. No hay API pública para unificarlos. El `Picker` segmentado evita este problema completamente al ser un control SwiftUI estándar que no interactúa con el sistema de vibrancy de macOS.

---

## 2026-06 — `Bundle.module` con helper `L()` para localización

**Decisión:** Los strings localizados se acceden mediante una función helper `L(_ key: String.LocalizationValue) -> String` definida en `Sources/App/L10n.swift`, que pasa `bundle: .module` a `String(localized:)`.

**Por qué:** SPM crea un bundle de recursos separado (`BrewMenu_BrewMenu.bundle`) para los targets ejecutables. `String(localized:)` y `Text()` de SwiftUI usan `Bundle.main` por default, que en el contexto de un ejecutable SPM no contiene los `.strings` files. `Bundle.module` resuelve al bundle correcto tanto en Xcode como en builds de línea de comandos. El helper centraliza esta lógica para no repetir `bundle: .module` en cada call site.

---

## 2026-06 — `SMAppService` para login item

**Decisión:** La funcionalidad "Open at login" usa `SMAppService.mainApp` (API de macOS 13+), no el mecanismo legacy de `LaunchAgents` o frameworks de terceros como `LaunchAtLogin`.

**Por qué:** `SMAppService` es la API oficial y soportada desde macOS 13. Los mecanismos legacy están deprecados. El único trade-off es que `SMAppService` requiere que la app esté instalada en `/Applications` para registrarse correctamente — en desarrollo esto falla silenciosamente, lo cual es el comportamiento esperado.

---

## 2026-06 — `.icns` directo en `Sources/Resources/` (sin `.xcassets`)

**Decisión:** El ícono de la app se provee como `AppIcon.icns` en `Sources/Resources/`, referenciado en `Info.plist` con `CFBundleIconFile = AppIcon`. No se usa un `.xcassets`.

**Por qué:** El proyecto no tiene un target Xcode tradicional — es un ejecutable SPM. Los `.xcassets` son procesados por Xcode durante el build, pero `swift build` desde la línea de comandos no los soporta. Un `.icns` directo es copiado por SPM al resource bundle y por el build script al lugar correcto en el `.app`.

---

## 2026-06 — Logging a archivo con rotación (no `os_log`)

**Decisión:** Los eventos de la app se escriben a `brewmenu.log` mediante el actor `BrewLogger`, no al sistema unificado de logging de Apple (`os_log` / `Logger`).

**Por qué:** `os_log` escribe al log del sistema, accesible solo con Console.app o el comando `log`. Un archivo de texto plano en `~/Library/Application Support/BrewMenu/logs/` es más accesible para el usuario final que necesite reportar un bug, y puede adjuntarse directamente en un issue sin requerir conocimiento de herramientas de diagnóstico de macOS. La rotación a 5 MB con un backup garantiza un techo de ~10 MB de disco.
