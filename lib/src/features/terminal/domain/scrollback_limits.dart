/// How deep a pane's scrollback goes — live, and across a restart. Two
/// constants, because RAM and SQLite cannot be tuned against one number.
library;

/// Lines a live pane keeps in memory.
const int kLiveScrollbackMaxLines = 10000;

/// Lines persisted per pane, restored on the next launch. Restored content is
/// part of the live buffer, so the stored history is a sliding window.
const int kDurableScrollbackMaxLines = 2000;

/// Hard ceiling on one pane's encoded scrollback. A 200-column plain line is at
/// most ~200 bytes, so 2 000 lines is typically ~80 KB; this leaves room for
/// SGR-dense output without one pathological pane writing megabytes.
const int kDurableScrollbackMaxBytes = 256 * 1024;

/// Lines a **cold** pane keeps parsed: the screen only. The full live window
/// measured 117 MB across 100 detached panes, and ~2 GB at the live cap.
const int kColdScrollbackMaxLines = kDurableScrollbackMaxLines;

/// Bytes a cold pane's parked window may occupy. See [kColdScrollbackMaxLines].
const int kColdScrollbackMaxBytes = kDurableScrollbackMaxBytes;

/// Lines kept by a pane that failed to spawn. It holds one error message and
/// never grows, so it needs no real scrollback.
const int kErrorPaneScrollbackMaxLines = 1000;
