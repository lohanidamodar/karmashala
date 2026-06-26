# Chitragupta

A **Windows-first Flutter desktop** application: a chat-first **Agent Development
Environment (ADE)** that manages local coding-agent CLIs (Claude Code, Codex CLI,
Antigravity CLI).

> **Status:** Loop 0 — Bootstrap. An adaptive three-pane desktop shell with
> placeholder panels, Riverpod, a Drift/SQLite database, central logging, theming,
> keyboard handling, and tests. **No** real Git, WSL, or agent execution yet.

See the docs for the full picture:

- [`docs/PRODUCT.md`](docs/PRODUCT.md) — product vision and domain model.
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — structure, constraints, dependencies.
- [`docs/ROADMAP.md`](docs/ROADMAP.md) — the numbered implementation loops.
- [`docs/BUILD_LOG.md`](docs/BUILD_LOG.md) — what was built, decisions, limitations.
- [`docs/adr/`](docs/adr/) — architecture decision records.

## Requirements

- **Windows 10/11** with desktop development enabled.
- **Flutter** (stable) with the **Windows desktop** toolchain. Built with
  Flutter 3.44.2 / Dart 3.12.2.
- Visual Studio with the "Desktop development with C++" workload (required by
  Flutter to build the Windows runner).

Verify your setup:

```powershell
flutter doctor
flutter devices   # should list "Windows (desktop)"
```

## Windows development

> **Important:** Use the **Windows** Flutter/Dart toolchain (from PowerShell), not a
> WSL one. The working SDK, emulators, and signing config live on the Windows side.
> See [ADR 0001](docs/adr/0001-flutter-desktop.md).

From PowerShell, in the project directory (e.g. `G:\dev\projects\chitragupta`):

```powershell
# 1. Fetch dependencies
flutter pub get

# 2. Generate Drift code (required after changing any Drift table/database)
dart run build_runner build --delete-conflicting-outputs

# 3. Run the app on Windows desktop
flutter run -d windows

# 4. Build a release executable
flutter build windows
```

### Code generation

Drift uses code generation. The generated file `lib/src/core/database/app_database.g.dart`
is produced by `build_runner` and must be regenerated whenever a Drift table or the
database definition changes:

```powershell
dart run build_runner build --delete-conflicting-outputs
```

While iterating on schema you can watch instead:

```powershell
dart run build_runner watch --delete-conflicting-outputs
```

## Quality checks

Run these before committing (from PowerShell):

```powershell
dart format .
flutter analyze
flutter test
```

## Project layout

Feature-first. See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the full map.

```
lib/
  main.dart                 # Bootstrap: logging + database, then runApp
  src/
    app/                    # Shell, theme, keyboard shortcuts, app root
    core/                   # Cross-cutting: logging, database
    features/               # projects/ sessions/ detail/ (placeholder panels)
test/                       # Mirrors lib/
docs/                       # Product, architecture, roadmap, build log, ADRs
```

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| `Ctrl+1` | Focus the Projects pane |
| `Ctrl+2` | Focus the Sessions pane |
| `Ctrl+3` | Focus the Detail pane |
| `Ctrl+B` | Toggle the Projects pane |
