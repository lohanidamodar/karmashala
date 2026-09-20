/// Bytes on the way in. One global parsing budget shared by every pane rather
/// than a watchdog each, and the coalescer that spends it: output is buffered
/// and handed to the terminal a frame at a time, so `cat hugefile` in a hidden
/// pane cannot stall the one on screen.
library;

export 'src/pty_output_coalescer.dart';
export 'src/terminal_ingest_budget.dart';
