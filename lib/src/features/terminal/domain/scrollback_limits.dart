/// How deep a terminal pane's scrollback goes — live, and across a restart.
///
/// Two budgets, so two constants: the **live** window is RAM and the
/// **durable** window is SQLite, and deriving one from the other means neither
/// can be tuned without paying the other's price. The defaults are 10 000 live
/// against 2 000 durable, because the durable window was sized by what anyone
/// actually scrolls back to after a restart.
library;

/// Lines a live pane keeps in memory.
const int kLiveScrollbackMaxLines = 10000;

/// Lines persisted per pane, restored on the next launch.
///
/// ~40 screens at 50 rows. Restored content is itself part of the live buffer,
/// so the stored history is a sliding window, not an ever-growing log.
const int kDurableScrollbackMaxLines = 2000;

/// Hard ceiling on one pane's encoded scrollback. A 200-column plain line is at
/// most ~200 bytes, so 2 000 lines is typically ~80 KB; this leaves room for
/// SGR-dense output without one pathological pane writing megabytes.
const int kDurableScrollbackMaxBytes = 256 * 1024;

/// Lines a **cold** pane keeps parsed: the screen, and nothing above it.
///
/// A detached pane used to keep the whole live window of `BufferLine`s — four
/// 32-bit words per cell — measured at 117 MB across 100 panes holding only 600
/// lines each, and roughly 2 GB at the live cap. So it keeps its *screen*,
/// which costs nothing (a buffer can never hold fewer lines than its viewport)
/// and is what `terminalTailLines` reads, and holds the rest as encoded text —
/// in the durable window, which it would have had to encode on quit anyway.
const int kColdScrollbackMaxLines = kDurableScrollbackMaxLines;

/// Bytes a cold pane's parked window may occupy. See [kColdScrollbackMaxLines].
const int kColdScrollbackMaxBytes = kDurableScrollbackMaxBytes;

/// Lines kept by a pane that failed to spawn. It holds one error message and
/// never grows, so it needs no real scrollback.
const int kErrorPaneScrollbackMaxLines = 1000;
