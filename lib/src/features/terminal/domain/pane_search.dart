import 'terminal_search.dart';

/// How far back a pane **other than the one being searched** is scanned: at the
/// 100-pane target an unbounded sweep is a million lines of work.
const int kCrossPaneScanLines = 2000;

/// Most matches a cross-pane search collects before it stops sweeping — what
/// keeps a one-character query from collecting a match per line of every open
/// pane.
const int kCrossPaneMatchBudget = 1000;

/// How long the query must settle before other panes are swept. The pane being
/// searched is scanned on **every** keystroke, because that is what the user is
/// watching; everything else waits, so a six-character query costs one sweep.
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
