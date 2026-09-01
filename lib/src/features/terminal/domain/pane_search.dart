import 'terminal_search.dart';

/// How far back a pane **other than the one being searched** is scanned.
///
/// The app's scale target is 100 live terminals of up to
/// `kDurableScrollbackMaxLines` each, so an unbounded cross-pane search is a
/// million lines of work. Bounding it to the most recent window is the honest
/// trade: a pane you are not looking at, you are looking in for something
/// recent — and the bar says how many panes it got through, so the bound is
/// visible rather than a silent truncation.
///
/// Paired with [kCrossPaneMatchBudget] and one pane per slice, this is the
/// number that matters: **no single turn of the event loop scans more than this
/// many lines.**
const int kCrossPaneScanLines = 2000;

/// Most matches a cross-pane search collects before it stops sweeping.
///
/// Navigation through more than this is not a feature anybody uses, and the
/// budget is what keeps a one-character query from collecting a match per line
/// of every open pane.
const int kCrossPaneMatchBudget = 1000;

/// How long the query must settle before other panes are swept.
///
/// The pane being searched is scanned on **every** keystroke, because that is
/// what the user is watching. Everything else waits for the typing to stop, so
/// a six-character query costs one sweep rather than six.
const Duration kCrossPaneDebounce = Duration(milliseconds: 180);

/// One hit, and which pane it is in.
class PaneSearchMatch {
  const PaneSearchMatch({required this.paneId, required this.at});

  final String paneId;
  final ScrollbackMatch at;

  @override
  String toString() => 'PaneSearchMatch($paneId, $at)';
}

/// The first line of [lineCount] a non-focused pane is scanned from.
///
/// Pure so the bound is testable without a terminal.
int crossPaneFirstLine(int lineCount, {int window = kCrossPaneScanLines}) =>
    lineCount > window ? lineCount - window : 0;
