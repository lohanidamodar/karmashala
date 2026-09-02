/// How deep a terminal pane's scrollback goes — live, and across a restart.
///
/// These are two different budgets, so they are two constants:
///
/// * The **live** window is RAM. Every open pane holds its own `Terminal`, and
///   a split layout can have many at once, so this is what bounds resident
///   memory while the app runs.
/// * The **durable** window is SQLite. The autosave re-encodes dirty panes
///   every 20 s and the encoder emits SGR runs, so this bounds write cost and
///   database size — not memory.
///
/// Deriving one from the other means neither can be tuned without paying the
/// other's price: a deeper history you must also hold in RAM, or a shallower
/// live buffer bought to keep snapshots cheap. Orca separates them for that
/// reason and keeps its durable window the *deeper* of the two.
///
/// Karmashala's defaults are currently the other way round — 10 000 live
/// against 2 000 durable — because Loop 29 sized the durable window by "what
/// does anyone actually scroll back to *after a restart*". Which way the
/// balance should fall is a product decision; this file only makes it one that
/// can be made, by giving each budget its own name and its own number.
library;

/// Lines a live pane keeps in memory.
const int kLiveScrollbackMaxLines = 10000;

/// Lines persisted per pane, restored on the next launch.
///
/// ~40 screens at 50 rows. Restored content is itself part of the live buffer,
/// so the stored history is a sliding window, not an ever-growing log.
const int kDurableScrollbackMaxLines = 2000;

/// Hard ceiling on one pane's encoded scrollback.
///
/// A 200-column plain line is at most ~200 bytes, so 2 000 lines is typically
/// ~80 KB; this leaves room for SGR-dense output without letting one
/// pathological pane write megabytes into SQLite.
const int kDurableScrollbackMaxBytes = 256 * 1024;

/// Lines a **cold** pane keeps parsed: the screen, and nothing above it.
///
/// The third budget, and the one the scale target actually asks about. A
/// detached pane used to keep the same [kLiveScrollbackMaxLines] window as a
/// visible one — `BufferLine`s of four 32-bit words per cell — for a pane with
/// no view and, since visibility-aware ingestion landed, nothing writing into
/// it either. Measured with `tool/benchmark/terminal_scale_bench.dart`: 117 MB
/// of parsed cells across 100 panes holding only 600 lines each; at the live
/// cap the same hundred panes would be roughly 2 GB.
///
/// So a cold pane keeps its *screen* and drops its scrollback, holding the
/// history as encoded text instead — [kColdScrollbackMaxLines] of it, replayed
/// when the session comes back. The screen is kept rather than cleared because
/// it costs the same (a buffer can never hold fewer lines than its viewport)
/// and it is what the status sources read: `terminalTailLines` infers "waiting
/// for approval" from the bottom of the grid, and a detached session must not
/// go dark just because nobody is looking at it.
///
/// The window is the durable one deliberately: what a cold pane holds is
/// exactly what would be written to SQLite if the app quit now, so the pane
/// pays one encode it already owed rather than keeping a second, differently
/// sized copy.
const int kColdScrollbackMaxLines = kDurableScrollbackMaxLines;

/// Bytes a cold pane's parked window may occupy. See [kColdScrollbackMaxLines].
const int kColdScrollbackMaxBytes = kDurableScrollbackMaxBytes;

/// Lines kept by a pane that failed to spawn. It holds one error message and
/// never grows, so it needs no real scrollback.
const int kErrorPaneScrollbackMaxLines = 1000;
