import 'dart:async';
import 'dart:math' show max;

import 'package:xterm2/xterm.dart';

/// How long a pane's width has to hold still before its terminal takes it: a
/// drag is then two reflows and two SIGWINCHes, not one per column (SETTLED.md).
const kColumnResizeSettle = Duration(milliseconds: 100);

final _monotonic = Stopwatch()..start();

/// A pane's [Terminal], whose **columns** settle: a change after a quiet spell
/// lands at once, the ones hard on its heels wait for the width to hold still.
/// Rows move at once; buffer and process are still told together, by [resize].
class PaneTerminal extends Terminal {
  PaneTerminal({
    super.maxLines,
    this.settle = kColumnResizeSettle,
    Duration Function()? now,
  }) : _now = now ?? (() => _monotonic.elapsed);

  final Duration settle;
  final Duration Function() _now;

  Timer? _settling;
  int? _pendingColumns;
  int? _pixelWidth;
  int? _pixelHeight;
  Duration? _columnsMovedAt;

  /// A size nobody dragged to — a grid hint — which opens no settling window.
  void resizeNow(int columns, int rows) => super.resize(columns, rows);

  @override
  void resize(
    int newWidth,
    int newHeight, [
    int? pixelWidth,
    int? pixelHeight,
  ]) {
    final columns = max(newWidth, 1);
    final rows = max(newHeight, 1);
    if (columns == viewWidth) {
      _pendingColumns = null;
      super.resize(columns, rows, pixelWidth, pixelHeight);
      return;
    }

    final movedAt = _columnsMovedAt;
    final quiet = movedAt == null || _now() - movedAt >= settle;
    if (quiet && _settling == null) {
      _columnsMovedAt = _now();
      super.resize(columns, rows, pixelWidth, pixelHeight);
      return;
    }

    if (rows != viewHeight) {
      super.resize(viewWidth, rows, pixelWidth, pixelHeight);
    }
    _pixelWidth = pixelWidth;
    _pixelHeight = pixelHeight;
    // The view asks again at every layout; asking must not start the wait over.
    if (columns == _pendingColumns) return;
    _pendingColumns = columns;
    _settling?.cancel();
    _settling = Timer(settle, _land);
  }

  void _land() {
    final columns = _pendingColumns;
    _settling = null;
    _pendingColumns = null;
    if (columns == null) return;
    _columnsMovedAt = _now();
    super.resize(columns, viewHeight, _pixelWidth, _pixelHeight);
    // `resize` tells nobody, being normally called from a layout; this was not.
    notifyListeners();
  }

  @override
  void dispose() {
    _settling?.cancel();
    _settling = null;
    super.dispose();
  }
}
