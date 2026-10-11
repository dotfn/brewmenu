# TASK — Limpieza de estado (post-auditoría de arquitectura)

Backlog derivado de la revisión de arquitectura (state ownership / data flow). Cada tarea es
independiente, de bajo riesgo, y debe dejar la suite de tests en verde antes de pasar a la
siguiente. **Un commit por tarea** — no mezclar dos tareas en el mismo diff, así cualquier
regresión se puede aislar con `git bisect` sin ambigüedad.

## Regla general

Antes de marcar cualquier tarea como hecha:

1. `swift build` sin warnings nuevos.
2. `swift test` — toda la suite existente en verde (no solo los tests nuevos/modificados).
3. Los tests nuevos descritos en cada tarea, agregados y en verde.
4. El checklist de QA manual de la tarea (cuando lo tenga) verificado a mano — hay cambios acá
   (AppKit, onboarding, ciclo de vida de ventana) que ningún test unitario cubre hoy.

## Orden de ejecución

| # | Tarea | Prioridad | Cobertura de test hoy |
|---|---|---|---|
| 1 | Single source of truth para `hasCompletedOnboarding` | Alta | Ninguna (`OnboardingViewModel`/`SettingsStore` no tienen tests) |
| 2 | `liveOutdatedNames` → referencia directa a `MenuBarViewModel` | Alta | Parcial (2 tests usan el mecanismo viejo) |
| 3 | Autosave de Settings dentro de `SettingsViewModel` | Media | Ninguna (`SettingsViewModel` no tiene tests) |
| 4 | `failedInstallNames` como propiedad derivada | Baja | Parcial (varios tests dependen del valor, ninguno de la implementación) |
| 5 | `@Environment` para la familia de filas reusables | Baja | N/A (cambio de UI, sin tests automatizados) |
| 6 | ~~Split de archivo de `DashboardViewModel` (extensions)~~ | ❌ Rechazada — ver razón abajo | N/A |
| 7 | Surfacear el motivo real de un `uninstall()` fallido (encontrado en QA manual) | Alta | Ninguna hoy — `uninstall()` no tiene tests de la ruta de error |

---

## Tarea 1 — Single source of truth para `hasCompletedOnboarding` ✅ HECHO



**Problema actual:** el flag vive duplicado en `UserDefaults` (`OnboardingViewModel.needsOnboarding`,
leído sync en el init) y en `AppSettings.hasCompletedOnboarding` (persistido vía `SettingsStore` a
`settings.json`). `SettingsStore.init()` tiene un bloque de reconciliación que existe solo para tapar
el desacople. `SettingsViewModel.resetAllData()` resetea `settings.json` pero nunca toca
`UserDefaults` → "Reset all data" no vuelve a mostrar el onboarding.

**Prerrequisito de testeo:** `SettingsStore` hoy no acepta un directorio inyectable (a diferencia de
`InstalledPackagesCache`/`HomebrewAPICache`, que sí), así que no se puede testear sin tocar el
Application Support real. Alinearlo con el mismo patrón ya usado en el repo.

### Pasos

- [x] `Sources/Services/SettingsStore.swift` — agregado `init(directory: URL? = nil)` (mismo patrón que
      `InstalledPackagesCache`/`HomebrewAPICache`); sacado el bloque de reconciliación.
- [x] `Sources/Models/AppSettings.swift` — borrado el campo `hasCompletedOnboarding` (struct e
      `init(from:)`).
- [x] `Sources/Features/Onboarding/OnboardingViewModel.swift`:
  - Agregado parámetro `defaultsStore: UserDefaults = .standard` al `init`, todo uso interno de
    `UserDefaults.standard` reemplazado por `defaultsStore`.
  - `complete()` — sacado `settings.hasCompletedOnboarding = true`.
- [x] `Sources/Features/Settings/SettingsViewModel.swift` — `resetAllData()` ahora limpia
      `UserDefaults.standard.removeObject(forKey: "hasCompletedOnboarding")`.

### Tests agregados

`Tests/BrewMenuTests/OnboardingViewModelTests.swift` (nuevo, 5 tests):

- [x] `needsOnboardingIsTrueWhenFlagNotSet`
- [x] `needsOnboardingIsFalseAfterComplete` — dos `OnboardingViewModel` con el mismo suite de
      `UserDefaults`, simulando un relanzamiento.
- [x] `completeSkippedDoesNotPersistFlag` — **nota:** al implementarlo confirmé que
      `completeSkipped()` (botón X) nunca persistió el flag, ni antes ni después de este cambio — es
      el comportamiento real, no algo que se haya tocado. El test quedó validando *ese*
      comportamiento (que sigue apareciendo el onboarding si se sale sin completar), no lo que decía
      el plan original acá arriba.
- [x] `completeTriggersBootstrapWithPath`
- [x] `completeIsIdempotent`

`Tests/BrewMenuTests/SettingsViewModelTests.swift` (nuevo, 3 tests):

- [x] `resetAllDataClearsOnboardingFlag`
- [x] `resetAllDataResetsSettings`
- [x] `loadPopulatesSettingsFromStore`

`swift build && swift test` → **217/217 tests en verde**, sin tocar ningún test preexistente.

### QA manual (pendiente — hacer a mano)

- [ ] Borrar `~/Library/Application Support/BrewMenu`, relanzar → aparece onboarding.
- [ ] Completar onboarding, relanzar → NO vuelve a aparecer.
- [ ] Ir a Settings → General → "Reset…" → confirmar → relanzar la app → onboarding vuelve a aparecer.

---

## Tarea 2 — `liveOutdatedNames` → referencia directa a `MenuBarViewModel` ✅ HECHO

**Problema actual:** `DashboardViewModel.liveOutdatedNames` es un `Set<String>` mantenido a mano,
empujado desde `DashboardView.onChange(of: viewModel.outdatedPackages.map(\.name))`. Correcto solo
mientras `DashboardView` esté montada.

**Nota de migración (evidencia del repo):** *no* conviene agregar `menuBarViewModel` como parámetro
requerido del `init` de `DashboardViewModel` — hay ~25 call sites en `DashboardViewModelTests.swift`
que construyen el VM directamente y tendrían que tocarse todos sin necesidad. En cambio: propiedad
opcional + método `attachMenuBarViewModel(_:)`, seteado una sola vez en `BrewMenuApp.init()`. Cero
call sites de test rotos salvo los 2 que ya usan `updateLiveOutdatedNames`.

### Pasos

- [x] `Sources/Features/Dashboard/DashboardViewModel.swift` — borrados `liveOutdatedNames`/
      `updateLiveOutdatedNames(_:)`; agregados `menuBarViewModel: MenuBarViewModel?`,
      `attachMenuBarViewModel(_:)` y el computed `outdatedNames`. `outdatedInstalledCount`/
      `isOutdated(_:)` leen de `outdatedNames`.
- [x] `Sources/App/BrewMenuApp.swift` — `dashboardVM.attachMenuBarViewModel(vm)` llamado antes de
      asignarlo a `_dashboardViewModel`.
- [x] `Sources/Features/Dashboard/DashboardView.swift` — borrada la línea en `.onAppear` y todo el
      bloque `.onChange(of: viewModel.outdatedPackages.map(\.name))`.

### Tests modificados/agregados (en `DashboardViewModelTests.swift`)

- [x] Nuevo helper `makeMenuBarViewModel(outdated:)` (`@MainActor`, construye un `MenuBarViewModel`
      con `updatePackages(...)` ya aplicado).
- [x] `outdatedInstalledCountCounts` — migrado a `vm.attachMenuBarViewModel(makeMenuBarViewModel(outdated: ["git"]))`.
- [x] `isInstalledMatchesTapQualifiedSearchResultName` — mismo reemplazo con `"lumus-control"`.
- [x] Nuevo: `outdatedInstalledCountTracksAttachedMenuBarViewModelLive` — attachea un
      `MenuBarViewModel`, lee el count, llama `menuBarVM.updatePackages(...)` de nuevo con un set
      distinto **sin tocar `DashboardViewModel` para nada** → confirma que ya no hace falta ningún
      push manual (el regression test real de la clase de bug que motivó el cambio).
- [x] Nuevo: `outdatedInstalledCountIsZeroWithoutAttachedMenuBarViewModel`.

`swift build && swift test` → **219/219 tests en verde** (217 + 2 nuevos), sin tocar ningún test
que no fuera parte de esta tarea.

### QA manual (pendiente — hacer a mano)

- [ ] Abrir el Dashboard, comparar el stat card "Outdated" contra el popover del menu bar — mismos
      números.
- [ ] Con el Dashboard abierto, apretar ⌘R en el popover → el stat card se actualiza solo, sin cerrar
      y reabrir el Dashboard.

---

## Tarea 3 — Autosave de Settings dentro de `SettingsViewModel` ✅ HECHO

**Problema actual:** nada persiste settings salvo `DashboardView.onChange(of:
settingsViewModel.settings) { Task { await settingsViewModel.save() } }` — la responsabilidad vive
tres niveles arriba de donde se edita el estado.

**Patrón a reusar:** el mismo idiom de `Task` cancelable que ya usan `searchTask`/`installTask` en
`DashboardViewModel` — no inventar un mecanismo de debounce nuevo.

### Pasos

- [x] `Sources/Features/Settings/SettingsViewModel.swift`:
  - Agregados `isLoading` y `saveTask: Task<Void, Never>?` (`@ObservationIgnored`).
  - `settings` ahora tiene `didSet { guard !isLoading, oldValue != settings else { return };
    scheduleSave() }`.
  - `load()` envuelve la asignación con `isLoading = true` / `isLoading = false`.
  - `scheduleSave()` — cancela el `saveTask` anterior, debounce de 400ms, llama `save()`.
  - `save()` también cancela cualquier `saveTask` pendiente al arrancar — así una llamada
    explícita (p. ej. desde `resetAllData()`) nunca queda seguida de un save redundante del
    debounce que ya estaba en vuelo.
- [x] `Sources/Features/Dashboard/DashboardView.swift` — borrado el
      `.onChange(of: settingsViewModel.settings) { ... }`.

### Tests agregados (en `SettingsViewModelTests.swift`)

- [x] `settingsChangeTriggersAutosave` — cambia `showUpdateBadge`, espera 700ms, un `SettingsStore`
      nuevo apuntando al mismo directorio confirma que quedó persistido sin que el test llamara a
      `save()`.
- [x] `loadDoesNotTriggerAutosave` — compara el `modificationDate` del archivo antes/después de
      `load()` — confirma que cargar no dispara una reescritura.
- [x] `rapidChangesCoalesceIntoOneSave` — tres cambios seguidos, bien dentro de la ventana de
      debounce uno del otro → los tres terminan persistidos (prueba que el debounce no descarta
      cambios intermedios, solo coalesce las escrituras).

`swift build && swift test` → **222/222 tests en verde** (219 + 3 nuevos).

### QA manual (pendiente — hacer a mano)

- [ ] Cambiar un toggle en General, esperar un segundo, cerrar y reabrir el Dashboard → el toggle
      sigue en su nuevo estado.
- [ ] Cambiar varios toggles rápido seguido (drag en un picker, varios clicks) → no debería haber
      lag ni múltiples escrituras a disco simultáneas.

---

## Tarea 4 — `failedInstallNames` como propiedad derivada ✅ HECHO

**Problema actual:** `failedInstallNames: Set<String>` e `installErrors: [String: String]` se
mutan siempre juntos — es el mismo hecho guardado dos veces.

**Diff mínimo:** convertir `failedInstallNames` en una computed property evita tocar los ~8 call
sites que ya la leen (`HomeView`, `PackageDetailView`, `ThirdPartyEcosystemsView`'s `AddSheet`,
etc.) — no hace falta renombrar nada.

### Pasos

- [x] `Sources/Features/Dashboard/DashboardViewModel.swift`:
  - `failedInstallNames` ahora es `var failedInstallNames: Set<String> { Set(installErrors.keys) }`.
  - `install(name:isCask:)` — sacadas las líneas `failedInstallNames.remove(name)`/`.insert(name)`;
    el estado sale solo de las asignaciones a `installErrors[name]` que ya existían.

### Tests

- [x] `DashboardViewModelTests.swift` — nuevo: `failedInstallNamesDerivesFromInstallErrors` —
      provoca un install fallido, assert `vm.failedInstallNames == Set(vm.installErrors.keys)` y
      `.contains(name)`; reintenta con éxito, assert ambos vacíos.
- [x] Los 3 tests preexistentes que ya leían `failedInstallNames`
      (`installFailureMarksFailedAndLogsVisibly`, `installFailureSurfacesRealError`,
      `installSuccessClearsPriorFailure`) siguen en verde **sin haber sido tocados** — confirma que
      el comportamiento no cambió.

`swift build && swift test` → **223/223 tests en verde** (222 + 1 nuevo).

---

## Tarea 5 — `@Environment` para la familia de filas reusables ✅ HECHO

**Problema actual:** `dashboardViewModel` se re-threadea sin uso propio a través de
`PackageBrowseRow → PackageStatusIndicator → InstalledStatusButton` y
`PackageBrowseRow → PackageInfoButton` (`Sources/Features/Dashboard/StatusBadge.swift`).

**Alcance:** solo estos 4 tipos. Las vistas raíz de cada sección (`HomeView`, `InstalledView`,
`CategoryView`, etc.) siguen recibiendo `dashboardViewModel` por parámetro explícito — no
convertirlas a `@Environment`, ahí no hay drilling real que resolver.

**Nota:** el proyecto no usa `#Preview` en ningún lado (confirmado), así que no hay que preocuparse
por previews rotas al sacar el parámetro. `InstalledPackageRow` queda **fuera** de esta tarea a
propósito — su `dashboardViewModel: DashboardViewModel? = nil` es deliberadamente opcional y no es
parte de esta familia de filas.

### Pasos

- [x] `Sources/Features/Dashboard/StatusBadge.swift` — `PackageStatusIndicator`,
      `InstalledStatusButton`, `PackageInfoButton`, `PackageBrowseRow` ahora usan
      `@Environment(DashboardViewModel.self) private var dashboardViewModel` en vez de un
      parámetro explícito; sus llamadas internas entre sí (`PackageBrowseRow` →
      `PackageInfoButton`/`PackageStatusIndicator` → `InstalledStatusButton`) ya no lo pasan.
- [x] `Sources/Features/Dashboard/DashboardView.swift` — agregado `.environment(dashboardViewModel)`.
      **Ajuste sobre el plan original:** no quedó dentro del `detail:` closure como decía el paso de
      acá arriba, sino afuera del `NavigationSplitView` completo (encadenado junto con
      `.searchable`, etc.) — un `.environment(...)` scoped solo a `detail:` no llega a los
      `.sheet(...)` de más abajo (`PackageDetailView`, `InstallLogView`), que presentan por fuera
      de ese subárbol. Hoy ninguno de esos sheets usa los 4 tipos de esta tarea, pero dejarlo mal
      scoped era una trampa silenciosa para el día que alguno los use.
- [x] Actualizados los 5 call sites reales que pasaban `dashboardViewModel:` a estos 4 tipos:
      `HomeView.swift` (trending + `RecommendedCard`), `InstalledPackageRow.swift`,
      `ThirdPartyEcosystemsView.swift`, `SearchResultsView.swift`. (`InstalledView`,
      `CategoryView`, `EcosystemView`, `EcosystemsOverviewView` no construían estos 4 tipos
      directamente — solo `InstalledPackageRow`, que sí los usa — así que no había nada que tocar
      ahí; el plan original los listaba de más.)

### Validación

Sin tests automatizados aplicables (cambio puro de plumbing de SwiftUI, sin lógica de negocio).
`swift build && swift test` → **223/223 tests en verde**, sin cambios — es el regression guard
automático de que nada de lógica se movió. Regression guard real = QA manual:

- [ ] Home → Trending: instalar un paquete, ver info, confirmar que el botón de estado cambia.
- [ ] Home → Recommended: mismo chequeo.
- [ ] Installed: ver info de un paquete instalado.
- [ ] Search Results: instalar un resultado de búsqueda.
- [ ] Third-Party → una sección con "Available packages": instalar desde ahí.
- [ ] Cualquier Ecosystem/Category: uninstall con confirmación.

---

## Tarea 6 — Split de archivo de `DashboardViewModel` (extensions) ❌ RECHAZADA

**Problema actual:** un solo archivo de ~700 líneas cubriendo 5 sub-áreas (browse/install, search,
detalle de paquete, resolución del "Add" sheet, browsing de taps). Ya está organizado con
`// MARK:` — el split iba a ser mover código, no rediseñar nada.

**Por qué se rechazó (descubierto al planificar la implementación, no estaba contemplado cuando se
escribió esta tarea):** en Swift, `private`/`private(set)` está scoped al *archivo*, no al tipo —
una `extension DashboardViewModel` en un archivo distinto no tiene acceso a los `private`
declarados en el archivo base, aunque sea el mismo tipo (SE-0169 solo comparte acceso privado entre
extensions del *mismo* archivo). Casi todas las stored properties (`service`, `logger`, `taps`,
`installErrors`, `searchTask`, etc.) son `private`/`private(set)` hoy y se leen/escriben desde
métodos que este plan quería mover a otros archivos. Hacer el split tal cual estaba escrito
requería aflojar esos modificadores a `internal` — es decir, cualquier `View` del módulo pasaría a
poder escribir `dashboardViewModel.taps = []` directo, sin pasar por `addTap()`/`removeTap()`, algo
que hoy el compilador impide.

El costo real (perder encapsulamiento en ~15 properties) es más alto que el beneficio (navegación
más fácil, que el jump bar de Xcode con los `// MARK:` que el archivo ya tiene resuelve bastante
bien sin tocar nada) — mismo criterio con el que se rechazó el split en múltiples stores y el
`AppCoordinator` en la síntesis final de la auditoría. Se deja `DashboardViewModel.swift` como un
solo archivo.

**Qué evidencia lo reabriría:** el archivo creciendo mucho más allá de las ~700 líneas actuales, o
un segundo desarrollador reportando fricción real para navegarlo — no antes.

---

## Tarea 7 — Surfacear el motivo real de un `uninstall()` fallido ✅ HECHO

**Encontrada en QA manual de la Tarea 5** (no es una regresión de ninguna tarea anterior — el gap
ya existía): al desinstalar `sqlite` desde Trending, Homebrew lo rechazó (`Error: Refusing to
uninstall ... — brew uninstall --ignore-dependencies sqlite`, porque otro paquete instalado
depende de él) y la UI solo mostró un tacho rojo permanente con el tooltip genérico "Uninstall
failed — try again", sin decir por qué. Confirmado en `~/Library/Application
Support/BrewMenu/logs/brewmenu.log` — el motivo real sí se logueaba a archivo, pero nunca llegaba a
la UI. Sensación resultante: la app parece rota en vez de explicar lo que pasó.

**Problema actual:** `install()` sí guarda el motivo real (`installErrors: [String: String]`,
mostrado en tooltips/labels con el texto de Homebrew). `uninstall()` no tiene su equivalente —
`failedUninstallNames: Set<String>` es un booleano sin contexto, y encima es el mismo patrón de
estado duplicado que la Tarea 4 arregló para instalar (un `Set` mantenido a mano en paralelo a
donde debería vivir el motivo real).

**Mejora pedida además de mostrar el mensaje:** el mensaje crudo de Homebrew ("Refusing to
uninstall /opt/homebrew/Cellar/sqlite/3.53.4") es específico ese caso — el 90% de los `uninstall`
fallidos van a ser exactamente este (algo instalado depende del paquete) — necesita traducirse a
algo que un usuario no técnico entienda y pueda accionar, no mostrarse crudo. Para cualquier otro
motivo de falla (poco común), cae al mensaje real de Homebrew tal cual, mismo criterio que ya usa
`install()`.

### Pasos

- [x] `Sources/Features/Dashboard/DashboardViewModel.swift`:
  - Agregado `private(set) var uninstallErrors: [String: String] = [:]`, junto a `installErrors`.
  - `failedUninstallNames` ahora es computed: `Set(uninstallErrors.keys)` (mismo criterio que la
    Tarea 4 — nace derivado, no repite el error que se acaba de arreglar del otro lado).
  - `uninstall(name:isCask:)` limpia `uninstallErrors[name] = nil` al arrancar; en el catch, setea
    `uninstallErrors[name] = Self.friendlyUninstallError(error, name: name)`.
  - Nuevo `private static func friendlyUninstallError(_ error:name:) -> String`: si el `stderr` de
    un `BrewError.commandFailed` contiene `"Refusing to uninstall"`, devuelve *"\(name) couldn't be
    removed — another installed package still depends on it. To remove it anyway, run \"brew
    uninstall --ignore-dependencies \(name)\" in Terminal."*. Cualquier otro error cae a
    `error.localizedDescription` tal cual (mismo fallback que `install()`).
- [x] `Sources/Features/Dashboard/StatusBadge.swift` (`InstalledStatusButton`) — `.help(...)` usa
      `dashboardViewModel.uninstallErrors[name]` cuando existe.
- [x] `Sources/Features/Dashboard/InstalledPackageRow.swift` — mismo cambio en el trash button.
- [x] Limpieza: sacada la entrada muerta `"Uninstall failed — try again"` de
      `en.lproj`/`es.lproj/Localizable.strings` (ya no la usa ningún `.swift`).

### Tests agregados (en `DashboardViewModelTests.swift`)

- [x] `uninstallFailureDependencyRefusalShowsFriendlyMessage` — usa el error exacto capturado en
      producción (`"Error: Refusing to uninstall /opt/homebrew/Cellar/sqlite/3.53.4\n  brew
      uninstall --ignore-dependencies sqlite"`), assert que el mensaje menciona
      `--ignore-dependencies` y no arranca con `"Command failed"`.
- [x] `uninstallFailureOtherReasonFallsBackToRealMessage` — error que no matchea el patrón, assert
      que `uninstallErrors[name]` es el `error.localizedDescription` real, sin heurística.
- [x] `failedUninstallNamesDerivesFromUninstallErrors` — falla → `failedUninstallNames ==
      Set(uninstallErrors.keys)`; reintento exitoso → ambos vacíos.
- [x] El test preexistente `uninstallFailureMarksFailedAndKeepsPackage` sigue en verde **sin
      tocarlo** — confirma que el comportamiento visible no cambió, solo se le agregó contexto.

**Ajuste posterior (feedback de QA manual — el mensaje en un tooltip seguía siendo "hay que
descubrirlo"):** se agregó un `.alert()` en `DashboardView`, mismo patrón que
`SettingsViewModel.saveError` → `GeneralTab` ya usa (`Binding` derivada de una property opcional,
no `.alert(item:)`). Dispara una sola vez por fallo, desde cualquier lugar que triggeree un
`uninstall` (Installed, cualquier Ecosystem/Category, Trending, Search Results) — no hace falta
pasar el mouse por ningún ícono para verlo.

- [x] `DashboardViewModel` — nueva `var uninstallFailureAlertName: String?`, seteada junto con
      `uninstallErrors[name]` en el catch de `uninstall()`. `uninstallErrors[name]` sigue viviendo
      después de cerrado el alert, así el tooltip del tacho lo sigue explicando si el usuario vuelve
      más tarde.
- [x] `DashboardView.swift` — `.alert(...)` agregado junto a los otros `.sheet(...)` de la raíz.
- [x] Test nuevo: `uninstallFailureSetsAlertName` — falla → se setea; se limpia (simulando el botón
      OK); un reintento exitoso posterior no lo vuelve a setear.

`swift build && swift test` → **227/227 tests en verde** (223 + 4 nuevos entre ambas rondas de la
Tarea 7).

**Segundo ajuste (feedback de QA visual — el copy se repetía, y se pidió ícono/color rojo en el
alert):** investigado — en macOS moderno (Big Sur+) `NSAlert` (lo que `.alert()` de SwiftUI usa por
debajo) ya no soporta un ícono/color custom, solo muestra el ícono de la app; no hay API pública
para forzarlo. Se evaluaron dos caminos (alert nativo solo con mejor copy, vs. reemplazarlo por un
banner propio estilo el de "Deprecated"/"Disabled" de `PackageDetailView` con ícono rojo real) — se
eligió quedarse con el alert nativo (accesibilidad/atajos de teclado del sistema, consistente con el
alert de `saveError` que ya existe) y mejorar solo el texto:

- [x] Título: `"Couldn't remove \(name)"` → `"Can't remove \(name)"`.
- [x] Mensaje (`friendlyUninstallError`): ya no repite "\(name) couldn't be removed" (redundante con
      el título) — ahora arranca explicando el motivo ("Another installed package still depends on
      \(name), so Homebrew won't remove it automatically") y separa el comando en su propia línea
      ("To force it anyway, run this in Terminal:\n\nbrew uninstall --ignore-dependencies \(name)").
- [x] Test existente `uninstallFailureDependencyRefusalShowsFriendlyMessage` sigue en verde sin
      tocarlo (sus asserts — contiene `--ignore-dependencies`, no arranca con `"Command failed"` —
      no dependían del texto exacto).

`swift build && swift test` → **227/227 tests en verde**, sin cambios.

### QA manual (pendiente — hacer a mano)

- [ ] Provocar el mismo caso real (desinstalar algo de lo que dependa otra cosa instalada) — tiene
      que aparecer el alert de inmediato, con el mensaje completo y el comando para forzarlo.
- [ ] Cerrar el alert (OK), volver a pasar el mouse por el tacho rojo — el tooltip todavía tiene que
      explicar el motivo.
- [ ] Provocar un `uninstall` fallido por otro motivo (si es posible) y confirmar que el alert
      muestra el mensaje real de Homebrew, no el heurístico de dependencias.

**Tercer ajuste (pedido en la misma revisión visual): botón de refresh global.** El problema de
fondo: `installErrors`/`uninstallErrors` solo se limpian cuando ese paquete puntual se reintenta y
sale bien — un fallo permanente (p. ej. `libcap` sin bottle para esta plataforma) se queda rojo el
resto de la sesión, sin ninguna forma de descartarlo. Se evaluó separar "refrescar datos" de
"descartar errores" en dos acciones — se optó por una sola: un botón de refresh re-consulta lo
instalado de verdad (por si algo cambió afuera de la app, p. ej. corriendo el comando
`--ignore-dependencies` que sugiere el alert de la Tarea 7) **y** limpia ambos diccionarios de
errores en el mismo click.

- [x] `DashboardViewModel` — nuevo `private(set) var isRefreshing: Bool` y `func refresh() async`:
      re-llama `refreshInstalled()` y limpia `installErrors`/`uninstallErrors`.
- [x] `DashboardView.swift` — botón `arrow.clockwise` en el toolbar (`.primaryAction`), visible en
      **cualquier** sección del Dashboard, no solo Home — el estado que limpia no es específico de
      una pantalla. Muestra un `ProgressView` mientras `isRefreshing`.
- [x] Test nuevo: `refreshClearsErrorsAndRefetchesInstalled` — provoca un install y un uninstall
      fallidos, confirma que `refresh()` limpia ambos diccionarios y refleja el nuevo
      `installedPackages`.

`swift build && swift test` → **228/228 tests en verde** (227 + 1 nuevo).

- [x] QA manual, intento 1: el botón funcionaba, pero al cambiar entre el ícono y el `ProgressView`
      la píldora del toolbar cambiaba de tamaño. Arreglado (mal) envolviendo ambas ramas en un
      `Group().frame(width: 24, height: 24)` — mismo patrón que usa el refresh del popover
      (`MenuBarView.header`), pero ese botón vive en una vista propia, no en un `ToolbarItem` real.
- [x] QA manual, intento 2: con el fix anterior, el círculo de hover quedaba bien pero el estado en
      reposo se veía roto. Causa real: `ToolbarItem` con `if isRefreshing { ProgressView() } else {
      Button {...} }` voltea el *tipo* de vista en la raíz del toolbar item — macOS calcula el
      chrome circular automático de los botones de ícono en base a ese `Button`, y perderlo/
      recrearlo en cada toggle rompe el estado en reposo aunque el hover, calculado en el momento,
      seguía viéndose bien. Arreglado con un único `Button` que nunca se destruye — solo el
      contenido de su `label:` cambia entre `Image` y `ProgressView`, más `.disabled(isRefreshing)`.
      `swift build && swift test` → 228/228, sin cambios de tests (puro layout ambas veces).
- [x] QA manual, intento 2: confirmado que el botón se ve bien en reposo/hover — pero apareció en
      **todas** las secciones (Insights, Settings, etc.), no solo Home, porque estaba en el toolbar
      global de `DashboardView` en vez de en `HomeView`. La idea original era solo Home. Movido: el
      `.toolbar` sale de `DashboardView.swift` y pasa a `HomeView.swift`, envolviendo el
      `if isLoading {...} else {...}` existente en un `Group` para poder encadenar `.toolbar`
      después (si no, el botón parpadeaba al entrar/salir del estado de carga).
      `swift build && swift test` → 228/228, sin cambios de tests (puro layout).
- [ ] QA manual pendiente: confirmar que el botón solo aparece en Home, y que se sigue viendo bien
      en reposo/hover en esta nueva ubicación.

---

## Al terminar todo el backlog

- [ ] `swift build && swift test` en verde de punta a punta.
- [ ] Recorrido manual completo: onboarding desde cero → dashboard → instalar/desinstalar → settings
      → reset all data → onboarding de nuevo.
- [ ] Revisar que no haya quedado código muerto (`liveOutdatedNames`, el campo viejo de
      `AppSettings`, etc. no deberían aparecer en ningún `grep` del repo).
