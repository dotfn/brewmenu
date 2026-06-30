# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Instrucciones de trabajo para Claude Code en este repositorio. Léelo antes de hacer cualquier cambio. Si algo acá contradice un pedido del usuario, preguntá antes de actuar.

## Sobre el proyecto

BrewMenu es una app nativa de macOS que vive en la menu bar y funciona como monitor de salud de Homebrew. El detalle del producto está en `SPECT.md`. El estado actual y las tareas en curso estarán en `ROADMAP.md` (a crear). Las decisiones técnicas tomadas y su razón estarán en `DECISIONS.md` (a crear).

**Antes de proponer arquitectura, features o cambios grandes, leé `SPECT.md`.** No reinventes lo que ya está especificado.

## Comandos

```bash
# Build (funciona con CommandLineTools)
swift build

# Tests — requieren Xcode instalado (no solo CommandLineTools)
swift test

# Un test específico
swift test --filter NombreDelTest

# Tests de integración (tocan brew real, no corren en CI)
swift test --filter BrewMenuIntegrationTests
```

Antes de decir "listo": corré `swift build`. Si hay Xcode disponible, también `swift test`. Pegá la salida relevante en el mensaje final.

## Stack y restricciones

- Swift 5.9+, targeting macOS 14 (Sonoma) en adelante.
- SwiftUI + `MenuBarExtra`. Nada de AppKit salvo que sea estrictamente necesario (y en ese caso, justificarlo).
- `async/await` y actors para concurrencia. Nada de `DispatchQueue` manual salvo casos puntuales.
- **Cero dependencias externas en v1.** Si pensás que hace falta una, abrí el tema en `DECISIONS.md` con propuesta y alternativas; no la agregues sin OK explícito.
- Persistencia: JSON en `~/Library/Application Support/BrewMenu/`. SQLite/GRDB solo si v0.3+ lo justifica.
- Build con Swift Package Manager + Xcode. El proyecto debe poder buildearse desde la línea de comandos con `swift build`.

## Arquitectura

```
BrewMenu.app
├── Sources/
│   ├── BrewMenuApp/          # @main, MenuBarExtra, composición
│   ├── Features/
│   │   ├── MenuBar/          # UI del popover
│   │   ├── Settings/         # Ventana de preferencias
│   │   └── Notifications/    # Wrappers de UserNotifications
│   ├── Services/
│   │   ├── BrewService       # Único punto que ejecuta brew. Actor.
│   │   ├── EnvironmentResolver  # Detecta path de brew y arma env vars
│   │   ├── StatusChecker     # Timer + scheduling de chequeos periódicos
│   │   ├── HistoryStore      # Lee/escribe snapshots JSON en disco
│   │   └── InsightEngine     # Genera [Insight] comparando snapshots. Puro.
│   └── Models/               # OutdatedPackage, DoctorWarning, Snapshot, Insight, etc
└── Tests/
    ├── BrewMenuTests/               # Unit tests rápidos, sin tocar brew real
    └── BrewMenuIntegrationTests/    # Tocan brew de verdad. No corren en CI.
```

### Invariantes clave

- **Solo `BrewService` toca `Process`.** Es un `actor` para serializar ejecuciones (nunca dos `brew` en paralelo). Si necesitás ejecutar algo fuera de `BrewService`, preguntá primero.
- **`InsightEngine` es puro:** recibe `[Snapshot]`, devuelve `[Insight]`. Sin filesystem, sin red. Testeable con fixtures sintéticas.
- **UI nunca llama directo a servicios async pesados desde el body.** Usar `@Observable` view models que expongan estado.
- **`EnvironmentResolver` resuelve brew en orden:** `/opt/homebrew/bin/brew` → `/usr/local/bin/brew` → path custom del usuario. Corre `brew shellenv` una vez por sesión para armar el `environment` que se le pasa a cada `Process`.

### Persistencia en disco

```
~/Library/Application Support/BrewMenu/
├── settings.json
├── snapshots/        # Un JSON por chequeo, rotar a 30 días
└── logs/
    └── brewmenu.log  # Rotativo, 5 MB max
```

## Reglas de código

- **Naming:** Swift API Design Guidelines, sin atajos. `BrewService`, no `BrewSvc`. `outdatedPackages`, no `outPkgs`.
- **Archivos:** un tipo principal por archivo. El archivo se llama como el tipo (`BrewService.swift`).
- **Acceso:** `internal` por default, `private` cuando se pueda, `public` solo si el módulo lo expone.
- **Errores:** errores tipados con `enum: Error`, nunca `throws` sin definir qué se tira. Nada de `try!` fuera de tests; `try?` solo cuando el `nil` tiene sentido semántico.
- **Force unwraps (`!`):** prohibidos salvo en tests o cuando hay un comentario `// swiftlint:disable:next force_unwrapping` con razón.
- **Comentarios:** explicá *por qué*, no *qué*.
- **TODOs:** formato `// TODO(brewmenu-XX): descripción` con referencia al item de roadmap o issue. Sin issue, no hay TODO.

## Tests

- `BrewService` se testea inyectando un protocolo `ProcessRunner` mockeable, no ejecutando `brew` real.
- `InsightEngine` se testea con snapshots sintéticos como fixtures. No debe tocar filesystem.
- Tests de integración (que ejecutan `brew` de verdad) van en target aparte y se saltean en CI.

## Flujo de trabajo

1. **Antes de escribir código:** verificá que el pedido encaje con el roadmap. Si no encaja, preguntá si actualizamos `ROADMAP.md` primero.
2. **Cambios chicos (un archivo, <50 líneas):** hacelos directo y mostrá el diff.
3. **Cambios medianos o nuevos módulos:** proponé el plan primero (qué archivos creás/tocás y por qué), esperá OK, después ejecutás.
4. **Cambios de arquitectura, dependencias nuevas, o cualquier cosa que toque `SPECT.md`:** parate. Discutilo. Si se decide algo, registralo en `DECISIONS.md` con fecha antes de codear.

## Qué NO hacer

- No agregues dependencias externas sin discusión previa.
- No cambies el target de macOS sin discusión.
- No toques `SPECT.md` por iniciativa propia. Si creés que algo está mal o desactualizado, decilo en el chat.
- No agregues features que no estén en el roadmap. Si tenés una idea, proponela.
- No uses AppKit, Combine, ni librerías de terceros sin plantearlo.
- No metas `print()` en producción.
- No asumas que `brew` está en `/opt/homebrew/bin/brew`. Toda llamada pasa por `EnvironmentResolver`.

## Git y commits

- Mensajes en imperativo y en inglés: `Add EnvironmentResolver`, no `Added` ni `Agregado`.
- Un commit, una idea.
- No incluyas archivos generados (`.build/`, etc.) — están en `.gitignore`.

## Idioma

El usuario habla español rioplatense. Respondé en español. El código, nombres de variables, commits y comentarios técnicos van en inglés. Mantené el idioma del archivo que estés editando.
