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
| `lib/src/ui/painter.dart` | `paintLine` rewritten as two passes: one merged `drawRect` per run of equal background colour, then one `Paragraph` per run of cells sharing (foreground, background, flags). Adds a record-keyed LRU for run paragraphs beside the existing per-cell `ParagraphCache`, cleared in the same places. The original per-cell loop is kept verbatim as `paintLinePerCell` (`@visibleForTesting`) so `test/terminal/perf/pixel_equivalence_test.dart` can assert the two rasterise identically. |
| `lib/ui.dart` | One added line: `export 'src/ui/painter.dart';`. Upstream keeps `TerminalPainter` package-private, which the app's perf and pixel-equivalence harness needs to reach. No other export changed. |

### Rules the batched painter must keep

These are the reasons the two painters rasterise identically. Breaking one
breaks `pixel_equivalence_test.dart`:

- Only cells with `charWidth == 1` merge into a text run. A double-width glyph's
  font advance is not guaranteed to be exactly `2 * cellWidth`, and a zero-width
  combining mark composes with the previous glyph — either would shift every
  following glyph in the run.
- A cell with code point `0` breaks the run and draws nothing. It must not
  become a space: a space under the `underline` flag paints, an empty cell does
  not.
- The `0x20` → `0xA0` underline-on-space workaround applies to the whole run at
  once (a run has uniform flags), which is equivalent to applying it per cell.
- Background runs merge only equal, opaque colours; the merged rect is
  `span * cellWidth + 1` wide, exactly the union of the per-cell rects
  (including the same 1 px right-hand spill).
- A text run can never straddle a background run, because the text run key
  includes `background` and `flags` — the only inputs to the background colour.

Nothing else differs. **Keep it that way:** every new divergence must be listed
here with its reason, and must be justified by a measurement.
