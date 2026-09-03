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

The measurements behind this fork are recorded in the commits that made it.
full analysis.

## What was NOT vendored

- `example/` — a full multi-platform Flutter app, irrelevant here.
- `bin/`, `script/` — upstream's own developer tooling; nothing in this app runs
  them, and `bin/` would otherwise be an executable entry point on the package.
- `media/` — README screenshots and GIFs; several MB of images that would ship
  in the repository for nothing.
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

Six of the 77 `.dart` files under `lib/`, verified with `diff -rq` against the
pub cache copy of the same version. Everything else is byte-identical; the only
other differences are `pubspec.yaml` and `analysis_options.yaml` (packaging,
above) and the five removed trees.

| File | Divergence |
| --- | --- |
| `lib/src/ui/controller.dart` | `TerminalController.highlight` and `TerminalHighlight` take an `underline` flag (default `false`, so every existing highlight is unchanged). It is carried, not acted on, here — `render.dart` and `painter.dart` do the drawing. Added for the Ctrl+hover link affordance: a *filled* highlight over a link is a wash that makes the link less readable than the output around it, which is the opposite of what an affordance should do. Pinned by `test/features/terminal/terminal_link_click_test.dart`. |
| `lib/src/ui/painter.dart` | `paintLine` rewritten as two passes: one merged `drawRect` per run of equal background colour, then one `Paragraph` per run of cells sharing (foreground, background, flags). Adds a record-keyed LRU for run paragraphs beside the existing per-cell `ParagraphCache`, cleared in the same places. The original per-cell loop is kept verbatim as `paintLinePerCell` (`@visibleForTesting`) so `test/terminal/perf/pixel_equivalence_test.dart` can assert the two rasterise identically. **Layout budget:** `beginFrame` refills `maxRunLayoutsPerFrame` (48) and `_drawRun` paints runs past it cell by cell (`_paintRunPerCell`) instead of laying out a paragraph for them. Measured: a 200x50 viewport being filled with fresh `ls --color`-shaped lines laid out 686 run paragraphs a frame with **zero** cache hits and spent 15.6 ms of a 16.7 ms frame inside `ParagraphBuilder`/`build`/`layout` — 93% of the paint, on text that scrolls away in a second. The run cache is keyed on the run's *text*, so it cannot hit on text a terminal is printing for the first time; the per-cell cache is keyed on (code point, colours, flags) and hits essentially always. 16.7 ms -> 3.0 ms median a frame, at the price of 1.9-3.1 ms more raster work on the frames that fall back (`tool/benchmark/raster_cost_bench.dart`). Pinned by `test/terminal/perf/paint_layout_cost_test.dart`; benchmarked by `tool/benchmark/paint_stream_bench.dart`. Separately, `paintHighlight` takes `underline`: it draws a 1px rule along the bottom of the run instead of filling it. The filled path is upstream's, unchanged, so nothing that does not pass the flag is affected. |
| `lib/ui.dart` | Two added lines: `export 'src/ui/painter.dart';` and `export 'src/ui/render.dart';`. Upstream keeps `TerminalPainter` and `RenderTerminal` package-private; the app's perf and pixel-equivalence harness needs the painter, and `paint_layout_cost_test.dart` needs the render object to prove `paint` refills the painter's per-frame layout budget. No other export changed. |
| `lib/src/core/escape/parser.dart` | `_csiHandleSgr` returns immediately when the CSI carried a prefix. Upstream routes **every** `m` final byte to SGR regardless of prefix, but a prefixed `m` is not SGR: `CSI > 4 ; 2 m` is xterm's `modifyOtherKeys` and `CSI > 1 m` is `modifyKeyboard`. A program probing for modifier reporting therefore had its request parsed as SGR parameters 4 and 2 and left the pane **underlined and faint**. The parser already records `_csi.prefix` (`parser.dart:222`) and other handlers already branch on it (`:331`, `:394`); SGR simply did not. We do not implement the modes — this only stops them being misread as a colour change. Pinned by `test/features/terminal/enter_key_encoding_test.dart`. |
| `lib/src/ui/render.dart` | A drag selection's start is held as a `CellAnchor` (`_dragAnchor`) instead of being re-derived from a screen position on every update. `TerminalGestureHandler.onDragUpdate` passes the position the drag *began* at every time, and upstream fed it back through `getCellOffset`, which adds the **current** scroll offset — so as soon as the buffer moved under the pointer (output arriving, or the view scrolling) the start of the selection slid onto a different line and everything that had scrolled off the top fell out of it. Selecting a build log while it was still printing gave you the last screen, not what you dragged over. The anchor follows its buffer line, and once scrollback evicts that line the start is clamped to the oldest surviving one rather than the selection being dropped. Held separately from the selection's own anchors because `setSelection` takes ownership of those and disposes them on the next call; released in an added `dispose()` override. Pinned by `test/features/terminal/selection_anchor_test.dart`. Separately, `_paintSegment` forwards a highlight's `underline` flag to `paintHighlight`; `_paintSelection` passes nothing and is unchanged. Also: `_paint` opens with `_painter.beginFrame()` — the painter's per-frame paragraph-layout budget is refilled by its caller, and "one frame" is one `paint` — and a `@visibleForTesting TerminalPainter get painter` exists solely so a test can prove that call is still there. Without it the app would paint its first screenful of new output and then fall back to per-cell drawing forever, and no painter-level test could see it, because the perf harness refills the budget itself. **Finally, `_updateViewportSize` reconciles instead of only remembering.** Upstream sends a resize only when the grid it computes differs from `_viewportSize` — what it last *sent* — but `Terminal`'s own grid can be changed without going through the render object at all: `CSI 8 ; rows ; cols t` (XTWINOPS) reaches `Terminal.resize` straight from the parser, so a program in the pane can set it. Once the two disagree, upstream's cache says "already sent that" for ever, and the pane is drawn in one grid while its buffer and its PTY believe another until the box happens to change by a whole cell. Now the terminal's actual grid is compared too (floored at 1x1, the way `Terminal.resize` stores it), so any divergence is repaired on the next layout — the box decides, which is what `autoResize: true` means. With `autoResize: false` nothing is sent either way, so a caller managing its own size is unaffected. Costs two int comparisons in `performLayout`; no per-frame work is added and the keystroke path is untouched. Pinned by `test/features/terminal/window_resize_test.dart`. |
| `lib/src/utils/circular_buffer.dart` | `_adoptChild` and `_moveChild` detach the outgoing occupant of a slot only if it is still homed there (`_isHomedAt`/`_evict`). Upstream detaches unconditionally, which detaches the aliases `Buffer.scrollUp` creates while they are still live at a lower index — a single line object is referenced from two slots between iterations of `lines[i] = lines[i + n]` — and the next `insert` then asserts `attached`. Real Codex TUI output trips it after 2 304 bytes. `_moveChild` also uses `_attach` rather than `_move`, which sets the same field without asserting the item is already attached. Measured: Loop 41 §6.1, with the fixture in `test/features/agents/fixtures/codex-tui.raw`; `test/features/terminal/command_blocks_terminal_test.dart` pins that a genuinely evicted line still detaches. |

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
- A run painted cell by cell because the frame's layout budget was spent must be
  the *same picture* as the same run painted as one paragraph. It is, and that
  is not an assumption: `_paintRunPerCell` calls the same `paintCellForeground`
  the per-cell reference painter calls, over the same cells, after the merged
  background rect is already down — which is exactly
  `paintViewportPerCellTwoPass`, the reference `pixel_equivalence_test.dart`
  compares against. Keep the fallback going through `paintCellForeground`; do
  not re-derive colours or the `0x20` -> `0xA0` substitution in it.

Nothing else differs. **Keep it that way:** every new divergence must be listed
here with its reason, and must be justified by a measurement.
