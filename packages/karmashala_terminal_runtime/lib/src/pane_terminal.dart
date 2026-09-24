import 'dart:async';
import 'dart:math' show max;

import 'package:xterm2/xterm.dart';

/// How long a pane's size has to hold still before its terminal takes it: a
/// drag is then two reflows and two SIGWINCHes, not one per column, and a
/// burst of row changes reaches the agent as its last size (SETTLED.md).
const kColumnResizeSettle = Duration(milliseconds: 100);

final _monotonic = Stopwatch()..start();

/// Whether terminal views may hear about writes. Suspended while the window is
/// minimized or hidden: a view told of a write asks for a frame and paints it.
class TerminalViewGate {
  bool _suspended = false;
  final _owed = <PaneTerminal>{};

  bool get isSuspended => _suspended;

  void suspend() => _suspended = true;

  /// Tells each terminal written to meanwhile's views once, so they repaint
  /// with what is there now.
  void resume() {
    if (!_suspended) return;
    _suspended = false;
    final owed = _owed.toList();
    _owed.clear();
    for (final terminal in owed) {
      terminal._notifyViews();
    }
  }
}

/// The gate every pane shares unless a test hands it another one.
final TerminalViewGate terminalViewGate = TerminalViewGate();

/// A pane's [Terminal], whose **size** settles: a change after a quiet spell
/// lands at once, the ones hard on its heels wait for the box to hold still.
/// Buffer and process are still told together, by [resize].
///
/// Its plain listeners are its views, held back while [TerminalViewGate] is
/// suspended; whatever must hear every write uses [addOutputListener].
class PaneTerminal extends Terminal {
  PaneTerminal({
    super.maxLines,
    this.settle = kColumnResizeSettle,
    Duration Function()? now,
    TerminalViewGate? viewGate,
  }) : _now = now ?? (() => _monotonic.elapsed),
       _viewGate = viewGate ?? terminalViewGate;

  final Duration settle;
  final Duration Function() _now;
  final TerminalViewGate _viewGate;
  final _outputListeners = <void Function()>{};
  bool _disposed = false;

  @override
  void notifyListeners() {
    for (final listener in _outputListeners.toList()) {
      listener();
    }
    if (_viewGate.isSuspended) {
      _viewGate._owed.add(this);
      return;
    }
    super.notifyListeners();
  }

  void _notifyViews() {
    if (!_disposed) super.notifyListeners();
  }

  Timer? _settling;
  (int, int)? _pending;
  int? _pixelWidth;
  int? _pixelHeight;
  Duration? _movedAt;

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
    if (columns == viewWidth && rows == viewHeight) {
      _pending = null;
      super.resize(columns, rows, pixelWidth, pixelHeight);
      return;
    }

    final movedAt = _movedAt;
    final quiet = movedAt == null || _now() - movedAt >= settle;
    if (quiet && _settling == null) {
      _movedAt = _now();
      super.resize(columns, rows, pixelWidth, pixelHeight);
      return;
    }

    _pixelWidth = pixelWidth;
    _pixelHeight = pixelHeight;
    // The view asks again at every layout; asking must not start the wait over.
    if ((columns, rows) == _pending) return;
    _pending = (columns, rows);
    _settling?.cancel();
    _settling = Timer(settle, _land);
  }

  void _land() {
    final size = _pending;
    _settling = null;
    _pending = null;
    if (size == null) return;
    _movedAt = _now();
    super.resize(size.$1, size.$2, _pixelWidth, _pixelHeight);
    // `resize` tells nobody, being normally called from a layout; this was not.
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _viewGate._owed.remove(this);
    _outputListeners.clear();
    _settling?.cancel();
    _settling = null;
    super.dispose();
  }
}

/// Listening to a terminal's writes whether or not anyone can see them.
extension TerminalOutputListeners on Terminal {
  /// Hears every write, even while [TerminalViewGate] holds the views back.
  void addOutputListener(void Function() listener) {
    final self = this;
    if (self is PaneTerminal) {
      self._outputListeners.add(listener);
    } else {
      addListener(listener);
    }
  }

  void removeOutputListener(void Function() listener) {
    final self = this;
    if (self is PaneTerminal) {
      self._outputListeners.remove(listener);
    } else {
      removeListener(listener);
    }
  }
}
