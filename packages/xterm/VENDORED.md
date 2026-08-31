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

Four of the 77 `.dart` files under `lib/`, verified with `diff -rq` against the
pub cache copy of the same version. Everything else is byte-identical; the only
other differences are `pubspec.yaml` and `analysis_options.yaml` (packaging,
above) and the five removed trees.

| File | Divergence |
| --- | --- |
| `lib/src/ui/painter.dart` | `paintLine` rewritten as two passes: one merged `drawRect` per run of equal background colour, then one `Paragraph` per run of cells sharing (foreground, background, flags). Adds a record-keyed LRU for run paragraphs beside the existing per-cell `ParagraphCache`, cleared in the same places. The original per-cell loop is kept verbatim as `paintLinePerCell` (`@visibleForTesting`) so `test/terminal/perf/pixel_equivalence_test.dart` can assert the two rasterise identically. |
| `lib/ui.dart` | One added line: `export 'src/ui/painter.dart';`. Upstream keeps `TerminalPainter` package-private, which the app's perf and pixel-equivalence harness needs to reach. No other export changed. |
| `lib/src/core/escape/parser.dart` | `_csiHandleSgr` returns immediately when the CSI carried a prefix. Upstream routes **every** `m` final byte to SGR regardless of prefix, but a prefixed `m` is not SGR: `CSI > 4 ; 2 m` is xterm's `modifyOtherKeys` and `CSI > 1 m` is `modifyKeyboard`. A program probing for modifier reporting therefore had its request parsed as SGR parameters 4 and 2 and left the pane **underlined and faint**. The parser already records `_csi.prefix` (`parser.dart:222`) and other handlers already branch on it (`:331`, `:394`); SGR simply did not. We do not implement the modes — this only stops them being misread as a colour change. Pinned by `test/features/terminal/enter_key_encoding_test.dart`. |
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

Nothing else differs. **Keep it that way:** every new divergence must be listed
here with its reason, and must be justified by a measurement.
