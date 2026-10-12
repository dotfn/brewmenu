# Plan de mejora para BrewMenu

Basado en `HOMEBREW-INTERNALS.md` (análisis de código real de `Homebrew/brew` y
`Homebrew/BrewUI`) + lectura directa del código actual de BrewMenu. Objetivo: integrar lo mejor
de los tres proyectos sin reinventar lo que BrewMenu ya resuelve bien y sin copiar lo que
`BrewUI` hace peor de lo que parece a primera vista.

La sección 6 se suma desde una segunda fuente, [Octopi](https://github.com/aarnt/octopi) (front-end
gráfico para pacman/Arch) — un análisis de **producto**, no de código (stacks distintos, C++/Qt vs.
Swift/SwiftUI, no hay nada que portar a nivel implementación). La regla de abajo aplica igual: nada
entra acá solo porque "Octopi lo tiene".

Regla de este plan: cada ítem dice **qué archivo tocar**, **por qué** (con cita a
`HOMEBREW-INTERNALS.md` o al código real) y **cómo se sabe que está hecho**. Nada de "mejorar
la arquitectura" en abstracto.

## 0. Lo que BrewMenu ya hace bien — no tocar

Para no proponer reinventar algo que ya funciona:

- **`HomebrewAPICache`** (`Sources/Services/HomebrewAPIClient.swift:98-205`) ya implementa TTL +
  "devolver stale si el fetch falla" (`staleTrending`, línea 146) — exactamente la política que
  BrewUI documenta para Discover. Ya tiene además *debounced persist* (coalescing de escrituras
  a disco cada 500ms, líneas 181-193), algo que BrewUI **no** tiene (escribe a disco en cada
  mutación).
- **Guards anti-doble-ejecución por view model**: `installSingle` (`DashboardViewModel.swift:795-815`)
  chequea `!isInstalling`, `uninstall` (línea 820) chequea `uninstallingNames.contains(name)`.
  No es un coalescing centralizado como el `inflightByID` de BrewUI, pero cubre el caso real
  (doble clic sobre el mismo paquete) a nivel de UI, que es donde realmente ocurre.
- **El lock FIFO de `BrewService`** (`BrewService.swift:29-83`) serializa *todas* las mutaciones
  sin excepción. BrewUI's `SerialBrewCommandCenter` no logra esto para IDs distintos (reentrancy
  de actor, verificado con repro — ver `HOMEBREW-INTERNALS.md` sección B2). **No reemplazar este
  lock por un actor "simple".**
- **`BrewOperations`** (`Sources/Services/BrewOperations.swift`) ya es, en miniatura, lo que
  `BrewCommandJobsRepository` es en BrewUI: un registro central de qué está corriendo/en cola,
  observable desde cualquier pantalla.

## 1. Design tokens — ✅ hecho, con un ajuste real sobre el plan original

**Hecho**: `Sources/App/BrewTheme.swift` (nuevo) con `BrewTheme.accent` (Amber 500 `#FBB040`,
el amber de marca de Homebrew) y `BrewSpacing` (grid de 8pt: `xs 4 / sm 8 / md 12 / lg 16 / xl 24
/ xxl 32`, igual que `HOMEBREW-INTERNALS.md` B6).

**Por qué el plan original cambió al ejecutarlo** (verificado contra el código, no asumido):
los tokens de badge de BrewUI (`badge.outdated.background/.foreground`) son un **fondo tenue +
texto de color** (`color.status.warningSubtle` + `Amber Warn #9B600D`); `StatusBadge` en
BrewMenu es **relleno sólido + texto blanco** (`StatusBadge.swift:11-18`). Son patrones de
componente distintos — tomar solo el valor de color de BrewUI y meterlo donde BrewMenu usa un
*fill* detrás de texto blanco habría producido una combinación nunca verificada para contraste.
`outdatedBadge`/`deprecatedBadge`/`disabledBadge` (`StatusBadge.swift:21-32`) ya llevan su propio
ratio de contraste verificado en comentario (texto blanco sobre ese fill: ≈4.52:1 / ≈5.86:1 /
≈8.72:1) — **se dejaron sin tocar**, documentado explícitamente en `BrewTheme.swift`.

Tampoco se aplicó `BrewTheme.accent` a los botones `.borderedProminent` existentes (12+ sitios,
confirmado por grep) — esa regla es justamente la que BrewUI documenta (B6): accent del sistema
en todo control estándar, amber de marca solo en elementos dibujados a mano por la app. Forzar
amber en un `.borderedProminent` habría violado la regla que se estaba portando.

**El bug real que sí se corrigió**: `MenuBarIcon.swift`'s `menuBarColor` usaba `.orange` plano
para los estados `.updates`/`.warning`, contradiciendo su propio comentario ("Orange everywhere
'updates available' shows up... this used to be yellow") y el resto de la app, que ya usa
`outdatedBadge` para ese mismo estado semántico (`HomeView.swift:103`). Corregido a
`.outdatedBadge` — ahora el ícono de la menu bar, `HomeView`'s `StatCard` y `StatusBadge`
comparten literalmente el mismo color para "hay actualizaciones pendientes", que es lo que el
comentario original ya decía que pasaba.

**Spacing**: `BrewSpacing` queda disponible para código nuevo; no se re-escribió el spacing
existente (`.padding(8)`, etc.) en los ~60+ sitios que lo usan — swap mecánico de bajo valor que
no cambia nada visible; se adopta hacia adelante, no retroactivamente.

**Verificado**: `swift build` limpio, `swift test` — 297/297 tests pasan.

## 2. Networking — revalidación condicional (ETag) en `HomebrewAPIClient` — ✅ hecho

**Hecho**: `HomebrewAPICache.CacheFile` ganó `var etags: [String: String]` (una sola tabla,
mapa aparte en vez de un campo por entry, así un `api-cache.json` viejo sin esa clave sigue
decodificando igual). `get(_:)` ahora acepta `etag:`, manda `If-None-Match`, y devuelve
`GetResult(data: Data?, etag: String?)` donde `data == nil` es un `304`. `fetchTrending`,
`fetchPackageDetail` lo usan: si hay un ETag guardado y el servidor responde `304`, solo se
llama `touchTrending`/`touchPackageDetail` (resetea el reloj del TTL, no re-decodifica nada).
`fetchDescription` se dejó **sin** ETag — su caché nunca expira (`description(for:)` no tiene
TTL), así que ese `get` solo se llama una vez por nombre; no hay un segundo fetch que revalidar.

**Tests añadidos** (`Tests/BrewMenuTests/HomebrewAPIClientTests.swift`): un test de integración
(un fetch 200 guarda el `ETag` de la respuesta) y tres tests directos sobre
`HomebrewAPICache` (round-trip de `etag(for:)`, que un ETag nuevo con valor `nil` no borra uno
ya guardado, que `touchTrending`/`touchPackageDetail` preservan los datos y no fabrican una
entrada donde no había ninguna). El camino 304 end-to-end por `HomebrewAPIClient` **no** se
testeó con un fetch real de por medio — los TTLs (24h/6h) no se pueden hacer pasar dentro de un
test unitario sin inyectar un reloj, que `HomebrewAPICache` no tiene hoy; se testeó la pieza de
estado que un 304 depende de, directamente, en vez de forzar esa inyección de reloj solo para
este cambio.

**Verificado**: `swift test --filter HomebrewAPI` — 13/13 pasan (incluye los 4 tests nuevos);
`swift test` completo — 297/297.

## 3. Self-upgrade — ya resuelto; no hace falta tocar nada

**Correctud verificada, no asumida**: la hipótesis original de este plan (`AppRelauncher`
reinicia a ciegas sin saber si el upgrade funcionó) **no se sostiene contra el código real**.

`MenuBarViewModel.upgradePackage("brewmenu")` (`MenuBarViewModel.swift:129-160`) solo pone
`needsRestart = true` en la línea 146, **dentro del camino feliz**, después de que
`try await service.runUpgrade(name)` ya resolvió sin lanzar. `BrewService.runUpgrade`
(`BrewService.swift:175-196`) chequea `result.isSuccess` y **lanza** `BrewError.commandFailed`
ante cualquier exit code ≠ 0 (líneas 186-194) — eso cae al `catch` de la línea 154, que pone
`upgradeFailure`/`status = .error` y nunca toca `needsRestart`. El botón "Restart" (y por lo
tanto `AppRelauncher.restart()`) **nunca se muestra** si el `brew upgrade --cask` de BrewMenu
falló. No hay relanzamiento silencioso de una versión vieja tras un upgrade roto — eso ya está
cubierto por la misma estructura `try/catch` que maneja cualquier otro upgrade.

Lo que BrewUI añade encima de esto (un alert "upgrade exitoso" al reabrir, vía
`UserDefaults(suiteName:)` + helper separado, `HOMEBREW-INTERNALS.md` B4) es **solo una
confirmación cosmética** post-relanzamiento — en BrewMenu, para el momento en que se decide
relanzar, el éxito ya es un hecho conocido, no una incógnita por confirmar después. Construir
esa pieza acá sería resolver un problema que no existe (YAGNI): el único efecto visible sería un
toast "¡Actualizado!" que nadie pidió. Si en el futuro se agrega un paso de verificación
*posterior* al upgrade en sí (p. ej. confirmar que el bundle relanzado realmente corresponde a la
nueva versión, no solo que `brew upgrade` devolvió 0), ahí sí valdría revisar este patrón — hoy
no aplica.

**Resultado**: sección cerrada sin cambios de código. Ver `HOMEBREW-INTERNALS.md` B4 solo como
referencia si alguna vez se necesita un helper real (por ejemplo, si BrewMenu empieza a requerir
privilegios elevados para algo del upgrade, cosa que hoy no hace).

## 4. Candidatos de mayor esfuerzo (evaluar, no ejecutar aún)

Estos no son parte del plan inmediato — quedan documentados para decidir después de 1-3.

### 4a. `swift-subprocess` en vez de `Process`+`openpty` manual — ❌ decidido no hacerlo (por ahora)

`ProcessRunner.swift` tiene ~250 líneas dedicadas a manejar pty (`PTYPair`), coordinación de
cancelación (`LaunchGuard`, `ContinuationBox`) y drenaje de pipes a mano — con comentarios que
documentan condiciones de carrera reales que hubo que resolver (`-[NSConcreteTask terminate]:
task not launched`, confirmado en producción). `swift-subprocess` (el mismo paquete que adoptó
BrewUI) resuelve el pty + process-group + teardown con dos líneas:
```swift
platformOptions.createSession = true
platformOptions.teardownSequence = [.gracefulShutDown(toProcessGroup: true, allowedDurationToNextStep: .seconds(2))]
```
(`HOMEBREW-INTERNALS.md` B2). Es una dependencia nueva (hoy BrewMenu tiene cero según
`ARCHITECTURE.md`: *"There are no third-party dependencies"*) — por eso no es parte del plan
inmediato, pero el ahorro de código de concurrencia hecho a mano es real y verificado por el
propio equipo de Homebrew resolviendo el mismo problema.

**Decisión (2026-10-11): no migrar, por ahora.** Tres razones:

1. `ProcessRunner.swift` no está roto — es ~250 líneas con comentarios que documentan bugs
   reales de producción ya resueltos (`-[NSConcreteTask terminate]: task not launched`, el pty
   para que `curl` no detecte "no es un tty", el drenado a EOF antes del buffer de 64KB).
   Migrarlo no arregla nada que falle hoy, cambia código probado por código nuevo a cambio de
   "menos líneas" — ninguna de las auditorías/investigaciones de esta sesión encontró un bug
   real ahí.
2. "Cero dependencias de terceros" es una propiedad deliberada de este proyecto (`ARCHITECTURE.md`),
   no un accidente — ser la primera dependencia trae costo más allá del código (otro
   `Package.resolved`, otro punto de falla en CI).
3. **Verificado el prerrequisito que esta sección dejaba pendiente**: el mínimo declarado de
   `swift-subprocess` es macOS 13 (compatible con el `.v15` de BrewMenu en el papel), pero hay
   un issue abierto en su propio repo (`swiftlang/swift-subprocess#192`) sobre que, bajo Swift
   6.2+, intenta usar las nuevas Span APIs vía un shim de compatibilidad al targetear macOS
   viejos, y en la práctica terminó forzando el platform target a `macOS(.v26)` para compilar —
   fricción activa ahora mismo, no un "sí, andá tranquilo".

**Qué lo reabriría**: un bug real nuevo en `ProcessRunner` que `swift-subprocess` resuelva de
forma demostrable, o que BrewMenu suba su deployment target por otra razón de peso (dejando de
ser un costo extra el `.v26` que el issue de arriba exige hoy).

### 4b. Consola histórica de comandos

BrewMenu muestra output en vivo por operación (sheet de instalación, banner de upgrade) pero no
tiene una pestaña tipo `BrewFeatureConsole` con historial navegable de jobs pasados con su
transcript completo y colores ANSI. Es una feature nueva, no una mejora de algo existente —
evaluar si el usuario la pide antes de construirla (YAGNI: hoy nadie se quejó de no poder ver
qué corrió `brew` hace 10 minutos).

## 5. Qué deliberadamente NO portar

- **No modularizar en múltiples targets SwiftPM** (BrewUI tiene 19). BrewMenu es un solo
  ejecutable y el tamaño actual no justifica esa fricción — `ARCHITECTURE.md` ya documenta la
  separación por carpetas (`App`/`Features`/`Services`/`Models`) como convención suficiente.
- **No copiar `SerialBrewCommandCenter` tal cual** — tiene un bug de serialización real (ver
  sección 0 y `HOMEBREW-INTERNALS.md` B2). El lock FIFO actual es la pieza correcta.
- **No adoptar Clean Architecture con capas Interactor/Repository separadas** si MVVM +
  `BrewServicing` ya cubre la testabilidad que BrewMenu necesita hoy.

## 6. Octopi — dos candidatos concretos (pendientes de ejecutar)

Filtrados de un análisis de producto completo (no de código — ver el hilo de la sesión que lo
generó, 2026-10-12). El criterio de corte fue explícito: solo entra lo que suma profundidad
*opcional* sin tocar el journey principal (Home/popover siguen siendo "¿está todo bien?") y sin
contradecir la filosofía ya construida de "nunca dejar al usuario adivinando qué pasó". Todo lo
que no pasó ese filtro está en la sección 7.

### 6a. Ver qué instaló un paquete, en su propia ficha de detalle

**Qué**: una sección/tab "Files" en `PackageDetailView` con los archivos reales que instaló el
paquete (binarios, man pages, licencias) — inspirado en el tab Files de Octopi.

**Por qué**: es la única feature de Octopi que agrega profundidad real sin competir con la
prioridad de BrewMenu (responder "¿está todo bien?" rápido) — vive adentro de una ficha que el
usuario ya abrió a propósito para explorar, no en Home ni en el popover.

**Cómo** (verificado contra `brew` real, no asumido):
- `brew list <formula>` y `brew list --cask <cask>` ya devuelven el path de cada archivo
  instalado, uno por línea — confirmado corriendo ambos contra un formula y un cask reales
  instalados en esta máquina.
- Para casks, filtrar las entradas bajo `.metadata/` (son el `INSTALL_RECEIPT.json`/config
  interno de Homebrew, no algo que la app en sí instaló — confirmado en el output real).
- Nuevo método en `BrewServicing`: `fetchPackageFiles(name:isCask:) async throws -> [String]`.
  Se calcula on-demand al abrir la ficha, no en el load general — mismo patrón ya establecido
  por `fetchPackageDiskUsage` (`PackageDiskUsage.swift`'s propio doc comment: "computed on
  demand... too slow to do on every load").
- v1: lista plana simple, no árbol — un árbol de carpetas es una mejora visual después, no un
  prerrequisito para que la feature sea útil.

**Cómo se sabe que está hecho**: abrir la ficha de un paquete instalado, ver sus archivos reales
sin salir de la app ni abrir una terminal.

### 6b. Distinguir origen (tap oficial vs. tercero) en Outdated Packages

**Qué**: cuando un paquete desactualizado viene de un tap no oficial, decirlo — no un color
nuevo en el ícono de la menu bar (ese verde/ámbar/rojo es semántico de *severidad*, mezclarlo
con *origen* lo haría ambiguo), sino un badge/texto en la lista de Outdated Packages y en el
popover.

**Por qué**: coherente con "nunca dejar adivinando" — un update de un tap de terceros no pasó
por la misma revisión que homebrew/core, es información real y accionable (¿reviso el changelog
antes de actualizar esto?), no decoración.

**Cómo** (verificado contra el código real, no asumido — y el hallazgo bueno es que **no hace
falta ninguna llamada nueva a brew**):
- `OutdatedPackage` (de `brew outdated --json=v2`) no trae tap — confirmado leyendo
  `Sources/BrewCore/Models/OutdatedPackage.swift`.
- Pero `InstalledPackage` sí (`let tap: String`, `InstalledPackage.swift:6`), y ambas listas ya
  están cargadas en memoria al mismo tiempo en `DashboardViewModel`.
- `Tap.isOfficial` ya existe (`Tap.swift:22`, `homebrew/core`/`homebrew/cask` hardcodeados ahí
  mismo) — reusar, no reinventar.
- Nuevo computed en `DashboardViewModel`: cruzar cada `OutdatedPackage` por nombre contra
  `installedPackages` para encontrar su `.tap`, envolver en `Tap(name:).isOfficial`.

**Cómo se sabe que está hecho**: instalar algo de un tap de terceros, dejarlo desactualizado, ver
la distinción (no solo el nombre) en Outdated Packages y el popover.

## 7. Qué deliberadamente NO tomar de Octopi

- **Click directo a la acción sin confirmar** (tray icon con updates → upgrade inmediato, doble
  click sin preguntar nada): contradice la filosofía que esta misma sesión reforzó hoy mismo —
  alert explícito y accionable en fallos de uninstall, botón de refresh que limpia errores
  viejos, mensajes traducidos a lenguaje humano en vez de texto crudo de brew. BrewMenu es
  "nunca sorprender"; Octopi, construido para un público que ya sabe usar pacman de memoria, es
  "mínima fricción". Son públicos distintos — perseguir el de Octopi significaría pelearse con
  decisiones ya tomadas, no sumar una feature neutral.
- **Columna de tamaño de descarga antes de instalar**: evaluado y descartado por ahora.
  `formulae.brew.sh` no expone el tamaño del bottle en su JSON — solo URL + sha256 del blob
  (confirmado contra la API real); conseguir el tamaño real exigiría un `HEAD` request extra por
  paquete listado, costo no trivial para un dato "nice to have" que `brew install` ya muestra en
  su propio log en vivo. BrewMenu ya tiene el concepto análogo post-instalación
  (`PackageDiskUsage`, cuánto espacio ocupa en disco lo ya instalado) — cubre el caso de uso real
  ("¿cuánto me está comiendo esto?") sin el costo de red extra.
- **Cancelación tipo `killall pacman`** (mata todos los procesos de ese nombre en el sistema, no
  solo el propio): `ProcessRunner`'s process groups (`setpgrp` + SIGTERM→SIGKILL escalonado) ya
  resuelven esto mejor — nada que tomar acá.
- **Suite de binarios separados** (notifier/cachecleaner/repoeditor aparte de la app principal):
  BrewMenu ya es una sola app coherente con MenuBarExtra + Dashboard — fragmentarla en varios
  ejecutables sería ir para atrás, no adelante.

## Estado

1. **Design tokens — ✅ hecho.** `Sources/App/BrewTheme.swift`, fix de contraste en
   `MenuBarIcon.swift`. `swift build` limpio, 297/297 tests.
2. **ETag en `HomebrewAPIClient` — ✅ hecho.** `Sources/Services/HomebrewAPIClient.swift` +
   4 tests nuevos en `Tests/BrewMenuTests/HomebrewAPIClientTests.swift`. 297/297 tests.
3. **Self-upgrade — ✅ cerrado sin cambios de código.** El problema que motivaba esta sección
   no existe en el código real; verificado, no asumido (ver sección 3).
4. **`swift-subprocess` (4a) — ❌ decidido no hacerlo por ahora** (ver sección 4a: no está
   roto, cero-dependencias es deliberado, y el propio paquete tiene fricción activa de
   deployment target). **Consola histórica (4b) — sigue pendiente de decisión del usuario**,
   feature nueva, nadie la pidió (YAGNI).
5. **Octopi (6a/6b) — aprobadas, pendientes de ejecutar.** El usuario pidió explícitamente un
   plan con lo mejor de Octopi sin abandonar la filosofía de BrewMenu — 6a (ficha de archivos
   por paquete) y 6b (distinguir origen oficial/tercero en Outdated) son las dos que pasaron
   ese filtro, ambas con factibilidad ya verificada contra `brew` real y el código actual (ver
   sección 6). Lo que no pasó el filtro está documentado en la sección 7, no es deuda pendiente.

Las secciones 1-3 de este plan están completas y verificadas (`swift build` + `swift test`,
299/299 a esta fecha). 4a quedó cerrado con una decisión documentada, no es trabajo pendiente.
Lo que sigue abierto: 4b (si el usuario la pide) y 6a/6b (aprobadas, listas para implementar).
