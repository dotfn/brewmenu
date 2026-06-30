# BrewMenu — Especificación técnica

## 1. Resumen

App nativa de macOS que vive en la menu bar y actúa como **monitor de salud de Homebrew**. No reemplaza a `brew` en la terminal; lo complementa con visibilidad pasiva, notificaciones y detección de problemas que el usuario típicamente ignora (cleanups pendientes, servicios caídos, doctor con warnings, espacio recuperable, etc).

**Diferencial:** no es un launcher de comandos con GUI. Es un monitor que aprende del estado del sistema a lo largo del tiempo y avisa cuando algo cambia o se degrada.

## 2. Objetivos y no-objetivos

### Objetivos (v1)

- Mostrar estado de Homebrew de un vistazo desde la menu bar.
- Detectar paquetes desactualizados sin intervención del usuario.
- Permitir ejecutar `brew upgrade` con feedback de progreso.
- Notificar cuando aparecen updates, fallos o warnings de `brew doctor`.
- Funcionar sin tocar la configuración existente de Homebrew del usuario.

### No-objetivos (explícitos)

- No es un reemplazo de la CLI. Si el usuario quiere control fino, abre Terminal.
- No instala paquetes nuevos en v1 (solo upgrade de existentes).
- No gestiona taps en v1.
- No funciona en Linux/Linuxbrew.
- No se distribuye por el Mac App Store (requeriría sandboxing, incompatible con ejecutar `brew`).

## 3. Plataforma y stack

- **Target:** macOS 14 (Sonoma) en adelante.
- **Lenguaje:** Swift 5.9+.
- **UI:** SwiftUI con `MenuBarExtra`.
- **Concurrencia:** `async/await`, actors.
- **Persistencia:** JSON en `~/Library/Application Support/BrewMenu/` para v1. Migrar a SQLite (GRDB) si los insights requieren queries.
- **Notificaciones:** `UserNotifications`.
- **Autostart:** `SMAppService` (no `LaunchAtLogin` legacy).
- **Distribución:** DMG firmado con Developer ID + notarización. Sin App Store.

### Dependencias externas

Ninguna en v1. Todo con frameworks de Apple. Si más adelante se necesita SQLite, agregar GRDB vía SPM.

## 4. Arquitectura

```
BrewMenu.app
├── App/                       # @main, MenuBarExtra
├── Features/
│   ├── MenuBar/               # UI del popover de la menu bar
│   ├── Settings/              # Ventana de preferencias
│   └── Notifications/         # Wrappers de UserNotifications
├── Services/
│   ├── BrewService            # Única capa que ejecuta `brew`. Actor.
│   ├── EnvironmentResolver    # Detecta path de brew y arma env vars
│   ├── StatusChecker          # Timer + scheduling de chequeos
│   ├── HistoryStore           # Lee/escribe snapshots en disco
│   └── InsightEngine          # Genera insights comparando snapshots
└── Models/                    # OutdatedPackage, DoctorWarning, Snapshot, etc
```

**Reglas:**

- Solo `BrewService` toca `Process`. El resto lo consume.
- `BrewService` es un `actor` para serializar ejecuciones (no correr dos `brew` en paralelo).
- UI nunca llama a `Process` directamente.
- `InsightEngine` es puro: recibe snapshots, devuelve `[Insight]`. Testeable sin filesystem.

## 5. Ejecución de `brew`

Este es el problema técnico más delicado. Una app de SwiftUI lanzada desde Finder/Login Items hereda el entorno de `launchd`, no del shell del usuario.

### Resolución del binario

`EnvironmentResolver` busca el binario en este orden:

1. `/opt/homebrew/bin/brew` (Apple Silicon, default actual).
2. `/usr/local/bin/brew` (Intel).
3. Path custom configurado por el usuario en Settings.

Si no encuentra ninguno, la app muestra estado de error con instrucciones para instalar Homebrew o configurar el path manualmente.

### Variables de entorno

Antes de ejecutar cualquier comando, `EnvironmentResolver` corre `brew shellenv` una vez por sesión y parsea la salida para armar un `[String: String]` con `HOMEBREW_PREFIX`, `HOMEBREW_CELLAR`, `HOMEBREW_REPOSITORY`, `PATH`, `MANPATH`, `INFOPATH`. Ese diccionario se le pasa a cada `Process` en `environment`.

### Comandos usados

| Comando                      | Frecuencia        | Costo  | Uso                              |
|------------------------------|-------------------|--------|----------------------------------|
| `brew outdated --json=v2`    | cada 1h           | bajo   | Lista de updates pendientes      |
| `brew update`                | cada 6h           | red    | Refrescar metadata               |
| `brew doctor`                | cada 24h          | medio  | Detectar warnings                |
| `brew cleanup --dry-run`     | cada 24h          | bajo   | Calcular espacio recuperable     |
| `brew services list --json`  | cada 1h           | bajo   | Estado de servicios (v0.4)       |
| `brew list --cask`           | cada 6h           | bajo   | Inventario de casks (v0.5)       |
| `brew upgrade [pkg…]`        | a demanda         | alto   | Acción del usuario               |

Todos los chequeos periódicos son cancelables y no se solapan. Si la app va a ejecutar un comando y ya hay uno corriendo, encola.

### Streaming de stdout

`BrewService.runStreaming(args:onLine:)` lee stdout línea por línea con un `FileHandle.readabilityHandler` y dispara un callback. Se usa para `brew upgrade` largo y para mostrar progreso real, no spinner indeterminado.

## 6. Estados de la menu bar

| Ícono | Estado    | Condiciones                                                       |
|-------|-----------|-------------------------------------------------------------------|
| 🟢    | OK        | 0 outdated, doctor OK, sin warnings activos.                      |
| 🟡    | Updates   | >0 outdated, sin errores críticos.                                |
| 🟠    | Warning   | doctor con warnings, o insight crítico (cleanup viejo, etc).      |
| 🔴    | Error     | brew no encontrado, último upgrade falló, doctor con errors.      |

El popover muestra siempre: versión de brew, contador de outdated, estado del último doctor, último chequeo, y acceso a acciones.

## 7. Insights (el diferencial)

El `InsightEngine` corre después de cada snapshot y genera mensajes accionables. Lista inicial:

- **Cleanup pendiente:** si pasaron >14 días sin cleanup y `--dry-run` reporta >1 GB recuperable.
- **Doctor sin correr:** si pasaron >30 días sin un doctor exitoso.
- **Servicio caído:** servicio que estaba `started` en el snapshot anterior y ahora aparece `stopped` o `error` (v0.4+).
- **Update estancado:** paquete que aparece como outdated por más de 14 días sin upgrade.
- **Cask abandonado:** cask cuya versión local lleva >90 días sin moverse y el latest tampoco (señal débil pero útil).
- **Updates acumulados:** >20 paquetes outdated.

Cada insight tiene severidad (info / warning / critical), texto corto para notificación, texto largo para el popover, y opcionalmente una acción ("Ejecutar cleanup", "Correr doctor", etc).

## 8. Persistencia

Estructura en `~/Library/Application Support/BrewMenu/`:

```
BrewMenu/
├── settings.json              # Preferencias del usuario
├── snapshots/
│   ├── 2026-06-29T10-00.json  # Un snapshot por chequeo (rotar a 30 días)
│   └── …
└── logs/
    └── brewmenu.log           # Rotativo, 5 MB max
```

Un snapshot contiene: timestamp, versión de brew, lista de outdated, lista de servicios, output resumido de doctor, tamaño de cleanup --dry-run.

## 9. Notificaciones

Disparadores:

- Aparece un paquete nuevo en outdated (con throttle: máx 1 notif por hora).
- Falla un `brew upgrade` automático.
- Nuevo warning de doctor que antes no estaba.
- Nuevo insight de severidad `critical`.

Todas las notifs son agrupables y respetan el modo "no molestar" del sistema. Settings permite silenciar por categoría.

## 10. Settings

Mínimo viable:

- Abrir al iniciar sesión (toggle).
- Frecuencia de chequeo (1h / 6h / 24h / manual).
- Path custom de brew.
- Notificaciones por categoría (toggles).
- Botón "Reset all data" que borra `Application Support`.

## 11. Roadmap

- **v0.1** — Menu bar + outdated + upgrade all + notif básica + EnvironmentResolver sólido.
- **v0.2** — Doctor integrado + streaming de progreso real + cancelación.
- **v0.3** — HistoryStore + primeros 3 insights (cleanup, doctor viejo, updates estancados).
- **v0.4** — Servicios (list/start/stop) + insight de servicio caído.
- **v0.5** — Casks con detección de updates.
- **v1.0** — Onboarding, settings completos, firma + notarización, sitio web mínimo.

## 12. Riesgos conocidos

- Cambios futuros en el formato JSON de `brew outdated` o `brew services list`. Mitigación: parsing tolerante con `Codable` + tests sobre fixtures.
- `brew upgrade --cask` puede requerir sudo en algunos casos. Mitigación: detectar el fallo, mostrar mensaje claro, no intentar elevar privilegios desde la app en v1.
- Homebrew puede instalarse en paths no estándar. Mitigación: campo de path custom en Settings.
- Notarización requiere cuenta de Developer ($99/año). Sin eso la app se bloquea por Gatekeeper.

## 13. Testing

- `BrewService` testeable inyectando un `ProcessRunner` mockeable.
- `InsightEngine` testeable con snapshots sintéticos como fixtures.
- Tests de integración reales (que toquen brew de verdad) en target separado, no en CI por defecto.

## 14. Decisiones abiertas

- ¿Mostrar contador en el ícono (`🍺3`) o solo cambio de color? Decidir tras prototipo.
- ¿Persistencia en JSON o SQLite desde v0.3? Empezar con JSON, migrar si los queries duelen.
- ¿Soportar múltiples instalaciones de brew en la misma máquina? Probablemente no en v1.