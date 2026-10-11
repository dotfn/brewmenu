# Homebrew internals — referencia para BrewMenu

Documento de trabajo, no para shippear. Nace de leer el código real (no READMEs) de
`Homebrew/brew` y `Homebrew/BrewUI` — la app nativa macOS que el propio equipo de Homebrew
construyó para resolver el mismo problema que BrewMenu. Todo lo que sigue está citado
archivo:línea contra esos dos repos (clonados en `/private/tmp/.../scratchpad/brew` y
`/private/tmp/.../scratchpad/BrewUI` durante el análisis — las rutas no sobreviven la sesión,
pero los nombres de archivo y líneas sí son estables contra `main` de ambos repos al
2026-10-10).

La Parte C es la que importa de verdad: qué hace BrewUI distinto de BrewMenu y qué vale la
pena portar.

---

## Parte A — `Homebrew/brew` (el CLI)

### A1. Arranque y dispatch de comandos

Tres capas antes de llegar a Ruby:

- **`bin/brew`** (Bash puro): resuelve `HOMEBREW_PREFIX`/`HOMEBREW_REPOSITORY`/`HOMEBREW_LIBRARY`
  siguiendo su propio symlink (`symlink_target_directory`, líneas 49-62), deshabilita cualquier
  función de shell con nombre de builtin (líneas 65-70, defensa contra hijacking), carga
  `brew.env` en cascada sistema→prefix→usuario, y termina con
  `exec /usr/bin/env -i "${FILTERED_ENV[@]}" /bin/bash -p brew.sh "$@"` (línea 344) — entorno
  completamente limpio más whitelist explícita.
- **`brew.sh`**: resuelve comandos triviales en Bash puro sin tocar Ruby si existe
  `cmd/<comando>.sh` (línea 603). Si no, `setup-ruby-path` y `exec` contra `brew.rb` (línea 684).
- **`brew.rb`**: extrae el nombre del comando de `ARGV` manualmente (líneas 51-61), luego
  dispatch real:
  ```ruby
  cmd_class = Homebrew::AbstractCommand.command(cmd)   # brew.rb:132
  command_instance = cmd_class.new                     # parsea los args específicos
  command_instance.run
  ```
  `AbstractCommand.command(name)` es `subclasses.find { it.command_name == name }`
  (`abstract_command.rb:44-45`); `command_name` deriva el nombre CLI del nombre de la clase por
  reflexión (`InstallCmd` → `install`, líneas 32-41). Un comando se "registra" por el simple
  hecho de ser `require`ado — `Commands.valid_internal_cmd?` literalmente hace `require` para
  comprobar que existe (`commands.rb:51-54`).

### A2. El DSL de `Formula` — metaprogramación real

```ruby
class Wget < Formula
  url "https://..."
  sha256 "..."
  depends_on "openssl" => :optional
  def install
    system "./configure", "--prefix=#{prefix}"
  end
end
```

No se parsea: es Ruby ejecutado con `module_eval`. Cadena exacta:

1. `Formulary.load_formula` (`formulary.rb:124-194`) crea un `Module.new` anónimo por fórmula
   (aislamiento de namespace) y hace `mod.module_eval(contents, path.to_s)` (línea 146), bajo
   un trust check previo (`Homebrew::Trust.require_trusted_formula!`).
2. Al abrir `class Wget < Formula`, el hook `Formula.inherited(child)` (`formula.rb:4001-4024`)
   inicializa `@stable = SoftwareSpec.new` **antes** de ejecutar una sola línea del cuerpo.
3. `url`, `sha256`, `depends_on` son métodos de clase (`class << self`, `formula.rb:3994+`) que
   delegan en ese `@stable`:
   ```ruby
   def url(val = nil, specs = {}) = stable.url(val, specs)     # formula.rb:4417
   def depends_on(dep) = specs.each { |s| s.depends_on(dep) }  # formula.rb:4725
   ```
   `depends_on` llega a `DependencyCollector#parse_spec` (`dependency_collector.rb:177-219`),
   que clasifica por tipo: `String` → `Dependency`, `Symbol` (`:xcode`, `:macos`) →
   `Requirement` (`XcodeRequirement`, `MacOSRequirement`).
4. `def install; ...; end` **no es metaprogramación** — override simple sobre el stub vacío
   `Formula#install` (`formula.rb:3512`).
5. `Formula#initialize` (`formula.rb:281-333`) hace `self.class.freeze` (congela la clase) y
   `spec_eval` (línea 437-444) **duplica** el `@stable` de clase en la instancia.
6. Especialización por plataforma: `Module#prepend` vía `extend/os/mac/...` — la clase base
   vive en `requirements/`, macOS le "parchea" comportamiento encima.
7. Carga sin tap clonado: `Formulary::FromAPILoader` (`formulary.rb:922-957`) construye la
   misma clase `Formula` desde JSON, llamando a los mismos métodos DSL programáticamente.

### A3. Instalación: dependencias → bottle/build → link

`FormulaInstaller#install` (`formula_installer.rb:558-659`):

- **Resolución de dependencias**: no hay `resolver.rb`. `Dependency.expand`
  (`dependency.rb:197-233`) es un DFS post-order — cada dependencia expande primero sus propias
  deps y luego se añade a sí misma, dando **orden topológico** sin paso de ordenamiento
  posterior. `@expand_stack` evita ciclos.
- **Bottle vs. source**: `pour_bottle?` (líneas 257-301). Si hay bottle, se descarga de
  `ghcr.io/v2/homebrew/core` y se verifica SHA-256 antes de extraer (`Bottle#stage`,
  `bottle.rb:246-259`).
- **Build real**: `FormulaInstaller#build` (líneas 1150-1219) lanza un subproceso con
  `Sandbox.run_or_fork(*Sandbox.ruby_command("build.rb", ...))` — en macOS, `sandbox-exec -p
  <perfil-seatbelt>`. `build.rb:222` ejecuta `formula.install` dentro de ese sandbox, con red
  denegada salvo `network_access_allowed?(:build)`.
- **Linking**: `Keg#link` (`keg.rb:498-604`) crea symlinks *relativos* desde
  `Cellar/<formula>/<versión>` hacia `opt/` y hacia el prefix.
- **Rutas dinámicas**: no usa `install_name_tool` por shell — usa el gem puro-Ruby `ruby-macho`
  vendorizado (`os/mac/mach.rb`) para reescribir load commands Mach-O en memoria, y re-firma con
  `codesign` (`extend/os/mac/keg_relocate.rb`).
- **Receipt**: `Tab#write` (`tab/tab.rb:192-199`) persiste `INSTALL_RECEIPT.json`.

### A4. Cask — arquitectura deliberadamente distinta a Formula

`Cask` (`cask/cask.rb`) delega todo su DSL a un objeto `DSL` separado
(`dsl.instance_eval(&block)`), expuesto vía `def_delegators`. Las stanzas de artifact (`app`,
`pkg`, `binary`...) se generan con `define_method` iterando clases `Artifact::*`
(`dsl.rb:842-856`), derivando el nombre por reflexión del nombre de clase. Esta separación
permite reconstruir un cask sintético desde JSON de la API sin ningún `.rb` real.

`Installer#install` (`installer.rb:176-224`) es **transaccional**: `install_artifacts` ejecuta
cada `Artifact#install_phase` en orden fijo (pkg antes que app/binary — un `.app` puede
contener un instalador anidado) y hace rollback invocando `uninstall_phase` en orden inverso si
algo falla a mitad — algo que `Formula` no necesita porque instala desde un bottle atómico.

### A5. Taps y Homebrew API — el detalle de seguridad más interesante

Desde ~2023 `brew` no clona `homebrew-core`/`homebrew-cask` por defecto. Descarga un JSON
(`formula.jws.json`) cacheado en `~/Library/Caches/Homebrew/api`, con revalidación HTTP
condicional y expiración de 7 días.

Los endpoints `*.jws.json` llevan una **firma JWS real (RSA-PSS/SHA-512)** verificada contra una
clave pública embebida en el repo (`Library/Homebrew/api/homebrew-1.pem`):
```ruby
pubkey = OpenSSL::PKey::RSA.new(jws_public_key_pem)
pubkey.verify_pss("SHA512", urlsafe_decode64(signature_b64), "#{protected_b64}.#{payload}", ...)
```
Si falla: `odie "...Potential MITM attempt detected."` (`api.rb:149-158`). No confía solo en
TLS — verifica criptográficamente que el JSON lo firmó Homebrew.

Descargas de source: `DownloadStrategyDetector.detect_from_url` elige estrategia por patrón de
URL, cacheando en `~/Library/Caches/Homebrew/downloads/<sha256(url)>--<basename>`, siempre
verificado por SHA-256 contra el `sha256` declarado en la fórmula.

---

## Parte B — `Homebrew/BrewUI` (la app nativa oficial)

Swift 6.2, SwiftPM modular, **macOS 26+ únicamente**, Clean Architecture + MVVM:

```text
View → ViewModel → Repository/Interactor → Services → brew CLI o JSON API
```

### B1. Módulos (de `Package.swift`)

| Módulo | Rol |
|---|---|
| `BrewCore` | Modelos de dominio, contratos de comando, value types compartidos |
| `BrewCLI` | Descubrimiento de ejecutable, ejecución de subprocesos, transporte de comandos brew |
| `BrewNetworking` | Cliente JSON API (`formulae.brew.sh`) |
| `BrewRepositoryInterfaces` | Protocolos de repositorio + soporte de previews |
| `BrewRepositories` | Acceso a datos, mapping, inventario, caché de catálogo |
| `BrewAppEnvironment` | Slots de `@Entry`/`@Environment` compartidos para DI |
| `BrewFeature*` (Discover/Doctor/Installed/Config/Console/SelfUpgrade) | Vistas + ViewModels por área |
| `BrewUIComponents` | Theming compartido, tokens de color/tipografía |
| `BrewAccessibilityID` / `BrewUITestContract` | Contratos sin dependencias, compartidos app+tests |
| `BrewSelfUpgradeContract` / `BrewSelfUpgradeHelperCore` / `HomebrewUpgradeHelper` | Self-upgrade |

Regla dura: **las features no se importan entre sí**. El shell las compone a través de
abstracciones compartidas en `BrewAppEnvironment`.

Dependencia notable: `swift-subprocess` (paquete oficial `swiftlang/swift-subprocess`), exacta
`1.0.0`, confinada a `BrewCLI`. Justificación textual del propio `Package.swift`: *"a
controlling-terminal pty needs `setsid()` between fork and exec, which `Foundation.Process`
cannot express"*.

### B2. `BrewCLI` — ejecución de comandos (leído directo, línea por línea)

**`BrewExecutableLocator`** (`BrewExecutableLocator.swift:32-54`): lista fija, sin PATH, sin
`brew shellenv`:
```swift
let candidates = [
    URL(fileURLWithPath: "/opt/homebrew/bin/brew"),
    URL(fileURLWithPath: "/usr/local/bin/brew"),
]
```
Deliberado — BrewUI nunca lee el entorno del usuario para configurar Homebrew.

**`ZshBrewCommandRunner`** (`ZshBrewCommandRunner.swift`) es el wrapper que siempre se usa en
producción. Arma un entorno mínimo (`HOME`, `USER`, `TMPDIR`, `LANG`, sin heredar nada del
proceso), construye `PATH` = solo el dir de `brew` + su `sbin` + `/usr/bin:/bin` (líneas 43-45),
y ejecuta:
```swift
"/usr/bin/env", ["-i"] + assignments + [
    "/bin/zsh", "--no-rcs", "--no-global-rcs", "-c",
    "[[ -t 1 ]] || printf '\\n%s\\n' \"$0\" >&2; printf '\\n%s\\n' \"$0\"; exec /usr/bin/env -i \"$@\"",
    startup.marker,
] + assignments + [executableURL.path] + arguments
```
— argv **literal**, nunca interpolación shell. El truco del marcador (`ZshStartupOutput`,
líneas 73-103): imprime un UUID único en stdout *y* stderr antes de re-`exec`ear con un entorno
limpio; todo lo que llega antes de ver ese UUID en cada stream es descartado como "ruido de
`/etc/zshenv`" (que siempre corre y no se puede deshabilitar), preservado solo si el proceso
muere antes de llegar al marcador (diagnóstico de arranque fallido).

**`BrewCommandService`** (el `underlying` real, sobre `Subprocess`): dos caminos.
- **Pipes** (`runOnPipes`, líneas 253-297): stdout/stderr separados, para comandos cuyo output
  se va a parsear (`brew info --json`). Drena con `async let` concurrente — esperar a la salida
  antes de leer deadlockea en outputs grandes.
- **Pseudo-terminal** (`runOnPseudoTerminal`, líneas 76-123): un solo dispositivo pty para ambos
  streams (todo reportado como `.stdout`), para comandos cuyo output se muestra al usuario
  (`brew install`/`upgrade`). Usa `TerminalLineAssembler` para distinguir líneas completadas
  (`\n`) de redraws de progreso (`\r`) — un download entero no es "una línea" por la medida de
  newlines, sino filas que se reescriben in-place.
- **Lo que hace `swift-subprocess` innecesario de reinventar**:
  ```swift
  platformOptions.createSession = true
  platformOptions.teardownSequence = [.gracefulShutDown(toProcessGroup: true, allowedDurationToNextStep: .seconds(2))]
  ```
  (líneas 358-365) — `createSession` pone al hijo y sus descendientes en un process group bajo
  una terminal controladora *de verdad*; el teardown señala al grupo completo, así cancelar un
  install mata el `curl`/`git` que está esperando. Un solo flag, no código custom de pty/kill.

**`SerialBrewCommandCenter`** (actor): el único canal de ejecución mutante.
- Serializa con un actor interno (`SerialBrewWorkQueue`, líneas 16-20) — no hay colas FIFO
  manuales con continuations, el actor mismo es la cola.
- Coalesce por `BrewOperationID`: si ya hay un `Task` corriendo para ese id,
  `run(...)` devuelve `try await existing.value` (línea 129-131) en vez de lanzar otro.
- Publica fase (`AsyncStream<BrewOperationPhase>`) y output
  (`AsyncStream<(BrewOperationID, BrewCommandOutputLine)>`) por listener, más streams "de todo"
  (`allPhaseChanges()`/`allOutputChanges()`) que alimentan la consola sin que cada feature
  conozca la consola.
- Tras cualquier comando mutante, llama `reconciler.reconcile()` (línea 181) **antes** de
  publicar la fase terminal — el id sigue "en vuelo" durante el reconcile, así un re-submit no
  puede arrancar un segundo `brew` mientras el inventario todavía se está actualizando.

> **⚠️ Discrepancia verificada (no solo sospecha — con repro):** el comentario del propio código
> dice *"Runs async mutating work strictly one-at-a-time, including across `await` inside
> commands (serial policy)"* (`SerialBrewCommandCenter.swift:15`). Esto es **falso para IDs
> distintos**. `SerialBrewWorkQueue` es un actor Swift, y los actores son reentrantes por
> defecto: cuando su `run(_:)` se suspende en el `await` real de `commandRunner.run(...)`
> (spawnear el subproceso), el actor queda libre para aceptar la siguiente llamada de otra
> `Task` con otro `BrewOperationID` — que arranca su propio `brew` antes de que el primero
> termine. Dos paquetes distintos instalándose/actualizándose casi al mismo tiempo (patrón real:
> cada ViewModel dispara su propia `Task { try await brewCommandCenter.perform(...) }`) pueden
> correr **dos `brew` reales en paralelo**. El *coalescing* de un mismo ID sí funciona y está
> bien testeado (`inflightByID[id]` devuelve la misma `Task`); lo que no hay es ningún test que
> dispare dos IDs distintos concurrentemente, que es justo el caso que rompe la garantía
> documentada — confirmado con un repro mínimo que imita la misma estructura
> actor+Task+actor y muestra ambas operaciones arrancando y terminando juntas.
>
> Esto importa porque Homebrew toma su propio lock de proceso para operaciones mutantes — dos
> `brew` corriendo a la vez sobre el mismo Cellar es exactamente el escenario que ese lock existe
> para evitar, y BrewUI depende de él en runtime en vez de serializar él mismo del lado Swift.

### B3. Capa de datos — Repositories + Networking

**`BrewAPIClient`** (`BrewNetworking`): un solo `URLSessionBrewAPIClient`, sobre `URLSession`
puro — sin librería HTTP de terceros, sin `URLSessionConfiguration` custom, **sin timeout ni
retry explícitos** (depende de los 60s default de `URLSession.shared`). Revalidación
condicional real: manda `If-None-Match: <etag>`, mapea `304` → `.notModified`, `2xx` → `.updated(data:, etag:)`.

**Catálogo** (`BrewCatalogueRepository`): TTL 1h, coalescing de refetches concurrentes por
`[HomebrewPackageKind: Task<...>]`, cache en disco JSON plano
(`~/Library/Caches/sh.brew.app/{formula,cask}-cache.json`), ETag en `UserDefaults` (no en el
archivo). **No** cae a datos cacheados si el fetch de red falla a este nivel — ese fallback
vive una capa arriba.

**Discover/analíticas** (`BrewDiscoverPackagesRepository`): TTL 24h (Homebrew publica analíticas
una vez al día), coalescing por un único `loadTask`, fetch de fórmulas+casks **en paralelo**
(`async let`), y solo marca el refresh como fresco si *ambos* fetches+stores tuvieron éxito. Ahí
sí vive el fallback real: si ya había datos `.loaded` y el refresh falla, el error se loggea
pero **no pisa el estado** — la lista vieja sigue visible. Si nunca hubo datos, pasa a
`.failed(error)`.

**Inventario instalado** (`BrewInstalledPackagesRepository`): no usa el cliente JSON — usa
`BrewCLI` con `brew info --installed --json=v2`. Cache **solo en memoria** (actor
`InstalledInventoryCache`, TTL 1h, sin persistencia a disco — deliberado, es el único dato que
no es "rebuildable catalogue/analytics"). El grafo de dependencias se construye una vez por
snapshot (`PackageDependencyGraph`, índice inverso `dependentsByDependencyPackageID`, O(n)
build / O(1) lookup). Tras cualquier mutación, el repositorio implementa
`BrewOperationReconciling.reconcile()` y vuelve a correr `brew info --installed` — invalidación
por evento, no por TTL.

**Decodificación tolerante a fallos parciales** (confirma literalmente lo que dice su propio
`ARCHITECTURE.md`): el catálogo decodifica elemento por elemento con `container.superDecoder()`
dentro de un `do/catch` por item — un formula/cask roto no tira el array completo, solo se
agrega a `decodeFailures` (aunque ese campo, al día del análisis, se calcula y nunca se
consume/loggea — gap real entre intención y uso). Las analíticas, en cambio, son estrictas: un
campo requerido ausente tira el decode completo, y el mapeo a dominio (`rankedPackageCounts()`)
lanza ante conteos no numéricos o identidad de paquete ambigua.

### B4. Self-upgrade — sin privilegios, con contrato JSON

`HomebrewUpgradeHelper` es un **`com.apple.product-type.tool` plano**, embebido en
`Contents/Helpers/` del bundle, firmado en copia. No es XPC, no es `SMJobBless`/`SMAppService`,
no hay `LaunchDaemon`. Corre con el mismo UID que la app — **no hay prompt de sudo** porque
`brew upgrade --cask homebrew-app` opera sobre un prefix de propiedad del usuario.

Ciclo completo:

1. **Guard previo**: `HelperSelfUpgradeHandoff.performUpgrade()` comprueba
   `commandCenter.runningPhases().values.contains(where: \.isUnfinishedMutation)` y **rechaza**
   el handoff si hay algo mutante corriendo — cerrar la app mataría el `brew install` que esté
   en curso.
2. **Contrato**: `SelfUpgradeHandoffSpec` (`Codable` struct) se escribe como JSON a un archivo
   temporal (razón explícita en comentario: *"a UI-test relaunch environment carries the whole
   fixture tree and would put argv over `ARG_MAX`"* — por eso va por archivo y no por argv).
   Campos: PID del padre, ruta del bundle, argv/env de relanzamiento, ruta de `brew`,
   argv/env del upgrade, ruta de log, nombre de `UserDefaults` suite, clave + valores de
   éxito/fallo, timeouts.
3. **Lanzamiento**: la app hace `process.run()` del helper con `--spec <path>` y **solo
   entonces** `NSApplication.shared.terminate(nil)`.
4. **Helper**: como no es hijo del proceso de la app (lo lanzó, pero no puede `wait()`
   sobre él tras recibir el handoff — en la práctica el helper sobrevive a la terminación), hace
   polling de `kill(pid, 0)` cada 100ms hasta 30s. Si no muere a tiempo, aborta sin tocar nada
   (`.abandoned`).
5. **Upgrade real**: corre `brew upgrade --cask homebrew-app` con el **mismo**
   `ZshBrewCommandRunner` que usa toda la app para cualquier otro comando — no hay una ruta de
   ejecución especial para self-upgrade. Log a `~/Library/Logs/sh.brew.app/self-upgrade.log`.
6. **Resultado**: `UserDefaults(suiteName: "sh.brew.app").set(succeeded ? ... : ..., forKey:
   ...)` — nombre de suite = bundle identifier de la app, no un archivo compartido.
7. **Relanzamiento**: `NSWorkspace.openApplication`, bloqueando con un semáforo hasta 30s para
   asegurar que el OS confirmó el lanzamiento antes de que el helper termine.
8. **App relanzada**: en `init()`, **antes de construir cualquier caché**, consume y borra la
   clave de `UserDefaults` (`SelfUpgradeLaunchNotice.consume()` — no-nil exactamente una vez por
   intento completado) y muestra un `.alert` de éxito/fallo en el primer render.

El orden de pasos (esperar→upgrade→record→relanzar) vive en un struct (`SelfUpgradeHelperRun`)
con todos los side-effects (AppKit, `UserDefaults`, `kill`) detrás de un `Effects` inyectable —
la secuencia se testea sin proceso real ni reloj real.

### B5. Arquitectura de features — el patrón `*Root`

Sin contenedor DI custom: `@Environment` + `@Entry` de SwiftUI. Cada dependencia es un
`@Entry var x: any Protocol = UnimplementedX()` — un default que "explota" si nadie la inyectó,
cableado una sola vez en el composition root (`BrewApp.swift`) vía
`.environment(\.doctorRepository, doctorRepository)` en el `WindowGroup`.

Patrón en 3 capas, ejemplo real (`DoctorColumnsRoot`/`DoctorColumns`/`DoctorViewModel`):
```swift
public struct DoctorColumnsRoot: View {
    @Environment(\.doctorRepository) private var doctorRepository
    @Environment(\.brewCommandCenter) private var brewCommandCenter
    var body: some View {
        DoctorColumns(doctorRepository: doctorRepository, brewCommandCenter: brewCommandCenter, ...)
    }
}
struct DoctorColumns: View {
    @State private var viewModel: DoctorViewModel
    init(doctorRepository: any DoctorRepository, ...) {
        _viewModel = State(initialValue: DoctorViewModel(doctorRepository: doctorRepository, ...))
    }
}
```
1. **`*Root`**: lee `@Environment`, pasa dependencias no-opcionales al `init` de la vista de
   contenido. Nunca construye ViewModels.
2. **Vista de contenido**: `init` no-opcional, dueña del `@State private var viewModel`
   (lo construye ella, no lo recibe).
3. **Vista de detalle**: pasiva, recibe el VM ya construido.

El shell (`MainWindowView`) solo decide *qué* `*Root` montar según la selección del sidebar —
nunca conoce repositorios internos de una feature.

ViewModels son `@Observable @MainActor final class` (Observation moderno, no
`ObservableObject`/Combine), con dependencias `@ObservationIgnored private let`. Cualquier
comando mutante se dispara con `brewCommandCenter.perform(command, id:)` — como
`BrewCommandJobsRepository` ya observa `allPhaseChanges()`/`allOutputChanges()` del mismo
centro, el output aparece en la consola automáticamente, sin que la feature conozca la consola.

**Consola** (`ConsoleTranscript`): calcula el prefijo común entre el documento renderizado y las
líneas nuevas, aplica solo el `Edit` mínimo (offset + longitud a reemplazar) sobre un
`NSTextView` — re-renderizar todo por línea sería cuadrático y rompería la selección del
usuario. Clampa los rangos de selección guardados contra el nuevo tamaño del documento antes de
reaplicar.

**Localización**: un `Localizable.xcstrings` por target UI (`Homebrew/`, `BrewUIComponents`,
cada `BrewFeature*`), cero copy en capas no-UI (`BrewCore`/`BrewCLI`/`BrewNetworking`/etc. tiran
errores tipados, `BrewErrorCopy` les pone palabras). `#bundle` explícito siempre — sin él, un
string de un paquete se busca en el bundle de la app y nunca localiza, en silencio.

**Accesibilidad para tests**: `BrewAccessibilityID` es un enum sin dependencias, compartido por
app y UI tests — un cambio de caso rompe la compilación en vez de dejar un test roto buscando un
string que ya no existe.

### B6. Design system — tokens completos (de `AGENTS.md`)

Fuente autoritativa real en código: `Sources/BrewUIComponents/Theme/BrewColors.swift` (+
`BrewFonts.swift`, `BrewSpacing.swift`, `BrewSymbols.swift`), respaldado por `.colorset` en
`Resources/Media.xcassets` — **cada token tiene variante universal, dark y high-contrast**
(confirmado en el asset catalog real, p. ej. `Surface.colorset/Contents.json` con 3 variantes).

**Principio de marca**: amber/dorado de Homebrew en componentes 100% custom de BrewUI;
**color de acento del sistema** (`.tint()`) en todo control SwiftUI estándar (Toggle, Checkbox,
Picker, focus ring) — porque macOS no expone si el usuario personalizó su accent color, así que
no se puede "caer a amber solo si es el default".

**Paleta fuente** (no usar directo — son la base de los tokens semánticos):
```text
Amber 500  #FBB040   Amber 400  #FCC96B   Amber 600  #E8971C   Amber 700  #98620F   Amber 100 #FEF3DC
Hops Dark  #1A1A1A   Hops 900   #222222   Hops 800   #2D2D2D   Hops 700   #3A3A3A   Hops 600  #4A4A4A
Cellar White #F5F5F0 Cellar 50 #FAFAF7    Cellar 100 #EFEFEA   Cellar 900 #1A1A18
Green OK #297C4E/#52C98A   Red Error #CD312C/#EE918E   Yellow Warn #F0AD4E/#F5C26B   Blue Info #2D71AE/#7AB3E0
```

**Tokens semánticos clave** (light / dark):
```text
color.background.windowBase      Cellar White #F5F5F0   /  Hops Dark #1A1A1A
color.background.surface         Cellar 50 #FAFAF7      /  Hops 900 #222222
color.background.surfaceElevated #FFFFFF                /  Hops 800 #2D2D2D
color.text.primary               Cellar 900 #1A1A18     /  #F0F0ED
color.text.secondary             #5C5C58                /  #B0B0B0
color.text.brand                 Amber 700 #98620F      /  Amber 600 #E8971C   (amber en blanco solo llega a 2.4:1 — nunca amber-sobre-blanco crudo)
color.brand.primary (fill)       Amber 500 #FBB040      — solo componentes custom (progress, cursor consola, botón primario, indicador sidebar)
color.status.success/.warning/.error/.info  — con variantes *Subtle para tint de fila
console.background               #1E1E1E  (siempre oscura, nunca invierte en light mode — "terminal roots")
console.textCommand              Amber 400 #FCC96B
console.textArgument             #A8D8A8
console.textError                #FF7B72
```

**Tipografía**: split sans-serif (prosa, system `.title`/`.body`) + monospace (código, SF Mono)
calcado del propio brew.sh, anclado a fuentes de sistema para Dynamic Type.
```text
fontSize.body 13/18   fontSize.caption 11/14   fontSize.code 12/18 (SF Mono)
```

**Spacing** (grid de 8pt, medio paso de 4pt): `xxs 2 / xs 4 / sm 8 / md 12 / lg 16 / xl 24 / xxl 32`.
`layout.sidebarWidth 220pt`, `layout.minWindowWidth 800pt`, `layout.minWindowHeight 520pt`.

**Radios**: `sm 4pt` (badges) / `md 6pt` (botones, campos, cards) / `lg 10pt` (paneles, popovers)
/ `xl 14pt` (modales).

**Elevación**: `.ultraThinMaterial`/`.regularMaterial` preferido sobre sombras explícitas;
sombras solo donde no hay vibrancy.

**Iconografía**: SF Symbols, peso mínimo Regular (Medium en toolbars), nunca multicolor salvo el
icono de la app. Mapeo por contexto: Package→`shippingbox`, Cask→`app.badge`,
Install→`arrow.down.circle`, Upgrade→`arrow.triangle.2.circlepath`,
Outdated→`exclamationmark.triangle`.

**Motion**: `fast 0.15s easeOut` (botones/badges), `standard 0.25s easeInOut` (transiciones de
panel), `spring(response: 0.35, dampingFraction: 0.75)` (sidebar expand/collapse). Checa
`accessibilityReduceMotion`.

**Accesibilidad**: contraste mínimo AA 4.5:1 en texto. Amber sobre blanco da 2.7:1 — nunca texto
amber sobre blanco, solo fondo-amber-con-texto-oscuro-encima. Target de click mínimo 44×44pt.

---

## Parte C — Comparación con BrewMenu y qué portar

BrewMenu ya resolvió, de forma independiente y a veces convergente, varios de los mismos
problemas que BrewUI. Esto es una comparación honesta, no "BrewUI mejor en todo".

### C1. Ejecución de comandos

| | BrewMenu (`ProcessRunner.swift`) | BrewUI (`BrewCLI`) |
|---|---|---|
| Transporte | `Foundation.Process` + `Pipe`/`openpty` manual | `swift-subprocess` (`Subprocess.run`) |
| Process group | `/usr/bin/perl -e 'setpgrp(0,0); exec...'` como wrapper | `platformOptions.createSession = true` (un flag) |
| Cancelación | `kill(-pid, SIGTERM)` + `SIGKILL` tras grace period, manual | `teardownSequence: [.gracefulShutDown(toProcessGroup: true, ...)]` |
| pty para progreso | `openpty()` crudo + `PTYPair` propio, con manejo manual de `ONLCR`, cierre de fds, semáforos de drenaje | Lo mismo conceptualmente, pero el pty/process-group lo da la librería; el código propio se concentra en `TerminalLineAssembler` (parsear redraws, no en gestionar el fd) |
| Shell/entorno | `brew shellenv` + merge con `ProcessInfo` — hereda bastante del entorno real | Nunca lee `brew shellenv`; `PATH` = solo dir de `brew` + sbin + `/usr/bin:/bin`, env construido desde cero |
| Filtrado de ruido de shell | No aplica (no pasa por `/bin/zsh -c`) | Marcador UUID en ambos streams para descartar banners de `/etc/zshenv` |
| Lock de mutación | FIFO manual con `CheckedContinuation` + array de waiters (`BrewService.swift:29-83`) — serializa **todas** las mutaciones, sin importar el paquete | Actor (`SerialBrewWorkQueue`) — **no serializa de verdad** entre IDs distintos (ver aviso abajo); solo dedupea el mismo ID |
| Coalescing de operación duplicada | No existe — dos llamadas a upgrade del mismo paquete lanzan dos `brew` (mitigado por el lock FIFO, que las serializa, pero sigue corriendo dos veces) | `inflightByID[id]` devuelve la `Task` existente — esto sí funciona bien |

**Importante, invierte la intuición inicial**: el propio BrewUI tiene un bug verificado (ver B2)
donde su "cola serial" no serializa entre paquetes distintos — los actores de Swift son
reentrantes, así que dos `brew` pueden correr en paralelo sobre el mismo Cellar. El lock FIFO
manual de `BrewService.swift`, aunque es más código, **sí logra serialización real de todas
las mutaciones** — es la pieza de BrewMenu que *no* hay que cambiar por "simplicidad" copiando
el patrón de BrewUI tal cual. Si se adopta el coalescing por `BrewOperationID` (sí vale la pena,
ver C5), debe ir **encima** del lock FIFO existente, no reemplazándolo por un actor desnudo.

**Lo más valioso a portar**: el flag `createSession`/`teardownSequence` de `swift-subprocess`
reemplazaría ~150 líneas de `PTYPair`/`LaunchGuard`/`ContinuationBox` hechas a mano en
`ProcessRunner.swift`, con menos superficie para bugs de carrera (el propio archivo tiene
comentarios extensos documentando condiciones de carrera que tuvo que resolver a mano —
`LaunchGuard`, `ContinuationBox` — que `swift-subprocess` resuelve en la librería). Es una
dependencia nueva, pero viene de `swiftlang` oficial y Homebrew mismo la adoptó para este
problema exacto.

El coalescing de `BrewOperationID` es una mejora barata y real: hoy, si el usuario hace doble
clic en "Upgrade" antes de que la UI se actualice, BrewMenu lanza dos `brew upgrade` para el
mismo paquete (el lock FIFO los serializa, pero igual corren dos veces). Un
`[OperationID: Task]` resuelve esto con poco código.

### C2. Self-upgrade

| | BrewMenu (`AppRelauncher.swift`) | BrewUI (helper + contrato) |
|---|---|---|
| Mecanismo | Script `/bin/sh` detached: `kill -0 $pid` en loop + `open -a` | Ejecutable dedicado (`HomebrewUpgradeHelper`) + JSON spec |
| ¿Corre el upgrade? | No — asume que `brew upgrade` ya corrió *antes* de reiniciar; solo relanza | Sí — el helper ejecuta `brew upgrade --cask ...` él mismo, después de que la app ya cerró |
| Guard contra mutación concurrente | No existe | Rechaza el handoff si hay una operación mutante corriendo |
| Reporta éxito/fallo del upgrade | No — el restart ocurre igual, sin saber si el upgrade funcionó | `UserDefaults(suiteName:)` con resultado, consumido al relanzar, mostrado en un alert |
| Log dedicado | No | `~/Library/Logs/sh.brew.app/self-upgrade.log` |
| Privilegios | Ninguno (igual que BrewUI) | Ninguno |

**Gap real y concreto**: si en BrewMenu el propio `brew upgrade --cask dotfn/tap/brewmenu`
falla a mitad (red caída, el cask tiene un bug) *después* de que la UI ya decidió reiniciar,
hoy no hay forma de que el usuario se entere — simplemente relanza la versión vieja en
silencio. El patrón "contrato JSON + helper separado + UserDefaults suite + alert post-relanzamiento"
no requiere privilegios ni es mucho código (los tres archivos de
`BrewSelfUpgradeHelperCore` suman ~250 líneas) y cierra ese agujero. No hace falta un target
Xcode nuevo necesariamente — se podría empezar simplificado: un archivo JSON temporal en vez de
`UserDefaults` suite, leído al arrancar.

### C3. Capa de datos / caché

BrewMenu ya tiene `InstalledPackagesCache`, `HistoryStore`, `SettingsStore` con directorios
inyectables — el patrón "cada store toma su directorio, testeable sin tocar datos reales" ya
está. Lo que BrewUI añade y BrewMenu no tiene explícitamente:

- **ETags + revalidación condicional** contra formulae.brew.sh — si BrewMenu hoy refetchea el
  catálogo completo cada vez (hay que confirmar contra `HomebrewAPIClient`), añadir
  `If-None-Match`/`304` ahorra ancho de banda y tiempo real en cada chequeo periódico.
- **Coalescing de refresh concurrente** (`loadTask`/`refreshTasks` por tipo): evita que abrir
  dos pestañas o que el chequeo periódico y una apertura manual disparen dos fetches a la vez.
- **Retención explícita de datos viejos ante fallo de red** (política documentada: "cold-load
  failures surface; background failures can retain cached data") — vale la pena como regla
  explícita en BrewMenu, no solo comportamiento incidental.

### C4. Design system

Esta es la ganancia más barata y de mayor impacto visual: BrewMenu **no tiene ningún archivo de
tokens de color/tipografía/spacing hoy** (confirmado, no existe `*Color*`/`*Theme*`/`*Design*` en
`Sources/`). BrewUI publicó un sistema completo, ya pensado específicamente para "Homebrew en
macOS nativo", con contraste AA verificado por tests (`BrewColorTokenContrastTests`) y
high-contrast ya resuelto. Portar los tokens de la Parte B6 (paleta amber/hops/cellar, la regla
"system accent en controles estándar, amber solo en componentes 100% custom", la paleta fija de
consola) le da a BrewMenu identidad visual consistente con el ecosistema Homebrew sin diseñar
desde cero, y evita el error de contraste más común (amber-sobre-blanco, que falla AA).

### C5. Qué portar primero (orden sugerido por costo/beneficio)

1. **Design tokens** (B6) — cero riesgo, cero dependencia nueva, impacto visual inmediato.
2. **Coalescing de operación por ID** en `BrewService` — pocas líneas, cierra un bug real
   (doble-upgrade por doble-clic). Mantener el lock FIFO existente tal cual (no es el cuello de
   botella a resolver — BrewUI, que sí lo reemplazó por un actor simple, terminó sin
   serialización real entre paquetes distintos; ver B2/C1).
3. **ETag/revalidación condicional** en el cliente de `formulae.brew.sh` de BrewMenu, si no lo
   tiene ya.
4. **Reportar resultado del self-upgrade** tras relanzar (aunque sea con un archivo JSON simple
   en vez del patrón completo de `UserDefaults` suite).
5. **Evaluar `swift-subprocess`** para `ProcessRunner` — mayor beneficio a largo plazo (menos
   código de concurrencia hecho a mano), pero es una dependencia nueva y un refactor real, no un
   parche.

---

*Generado a partir de lectura directa de código en una sesión de análisis. Si algo de esto deja
de ser cierto contra una versión futura de `brew` o `BrewUI`, confiar en el código de ese
momento, no en este documento.*
