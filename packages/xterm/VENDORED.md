# Vendored: xterm 4.0.0

- **Upstream:** https://github.com/TerminalStudio/xterm.dart
- **Version:** 4.0.0 (pub.dev), copied from the local pub cache
  `%LOCALAPPDATA%\Pub\Cache\hosted\pub.dev\xterm-4.0.0`
- **Vendored on:** 2026-08-29 (Loop 26 — terminal performance)

## Why this is forked

1. `RenderTerminal` constructs `TerminalPainter` inline in its initialiser list
   and stores it in a `final` field — no constructor parameter, no setter, no
   factory hook. The painter cannot be replaced from outside the package, and the
   painter is exactly where the terminal's performance problem lives (one
   `Paragraph` and one `Rect` per cell, ~20 000 draw calls for a 200×50 frame).
2. Upstream shipped 2 commits in all of 2025. There is no active branch to
   upstream to and nothing to rebase onto, so the usual cost of a fork (drift) is
   close to zero here.

See `docs/superpowers/specs/2026-08-29-terminal-performance-design.md` for the
full analysis.

## What was NOT vendored

- `example/` — a full multi-platform Flutter app, irrelevant here.
- `test/` — contains mockito-generated `*.mocks.dart`; this project forbids code
  generation (ARCHITECTURE constraint 3). Our own coverage lives in
  `test/terminal/` and `test/features/terminal/`.
- `dev_dependencies` — dropped along with the tests, so no `build_runner`,
  `mockito` or `dart_code_metrics` enters the dependency graph.
- `analysis_options.yaml` — replaced with a permissive one, so third-party code
  does not have to satisfy this project's `flutter_lints` profile while
  `flutter analyze` at the repo root stays clean.

Runtime dependencies are unchanged (`convert`, `meta`, `quiver`, `equatable`,
`zmodem`), so vendoring adds nothing new to the app's dependency graph.

## Files that diverge from upstream

| File | Divergence |
| --- | --- |
| `lib/src/ui/painter.dart` | `paintLine` rewritten to batch consecutive cells into one merged background rect per colour run and one `Paragraph` per style run. The original per-cell loop is kept verbatim as `paintLinePerCell` (`@visibleForTesting`) so `test/terminal/perf/pixel_equivalence_test.dart` can assert the two rasterise identically. |

Nothing else differs. **Keep it that way:** every new divergence must be listed
here with its reason, and must be justified by a measurement.
