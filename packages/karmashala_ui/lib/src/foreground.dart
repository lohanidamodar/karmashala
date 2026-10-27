import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Whether the app is on screen, as the OS last said: true while resumed or
/// inactive (still visible — the app switcher, a call), false while hidden
/// or paused. A phone in the background keeps its Dart timers running, and
/// with no frame to build nothing stops them, so recurring work asks here.
class AppForeground extends ChangeNotifier implements ValueListenable<bool> {
  AppForeground._();

  static final instance = AppForeground._();

  _Observer? _observer;
  bool _value = true;

  @override
  bool get value {
    _bind();
    return _value;
  }

  /// Completes at once in front, else when the app comes back.
  Future<void> whenInFront() {
    if (value) return Future<void>.value();
    final back = Completer<void>();
    void listener() {
      if (!_value) return;
      removeListener(listener);
      back.complete();
    }

    addListener(listener);
    return back.future;
  }

  @override
  void addListener(VoidCallback listener) {
    _bind();
    super.addListener(listener);
  }

  void _bind() {
    if (_observer != null) return;
    final WidgetsBinding binding;
    try {
      binding = WidgetsBinding.instance;
    } on Object {
      // No binding yet (a pure-Dart test): in front, and asked again later.
      return;
    }
    _observer = _Observer(this);
    binding.addObserver(_observer!);
    _value = _inFront(binding.lifecycleState);
  }

  void _set(AppLifecycleState state) {
    final now = _inFront(state);
    if (now == _value) return;
    _value = now;
    notifyListeners();
  }

  static bool _inFront(AppLifecycleState? state) =>
      state != AppLifecycleState.hidden && state != AppLifecycleState.paused;
}

class _Observer with WidgetsBindingObserver {
  _Observer(this._foreground);

  final AppForeground _foreground;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      _foreground._set(state);
}

/// A [Timer] that runs only while the app is in front ([AppForeground]).
/// Periodic, it is stopped in the background — not merely unheeded — and on
/// return fires once at once, since whatever it shows is stale, then keeps
/// its period again. A one-shot that falls due in the background fires on
/// return instead.
class ForegroundTimer implements Timer {
  ForegroundTimer(Duration duration, void Function() callback)
    : this._(duration, (_) => callback(), periodic: false);

  ForegroundTimer.periodic(Duration period, void Function(Timer) callback)
    : this._(period, callback, periodic: true);

  ForegroundTimer._(this._period, this._callback, {required this._periodic}) {
    AppForeground.instance.addListener(_onForeground);
    if (!_periodic || AppForeground.instance.value) _arm();
  }

  final Duration _period;
  final void Function(Timer) _callback;
  final bool _periodic;
  Timer? _timer;
  var _owed = false;
  var _cancelled = false;
  var _tick = 0;

  @override
  int get tick => _tick;

  @override
  bool get isActive => !_cancelled;

  @override
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _timer?.cancel();
    _timer = null;
    AppForeground.instance.removeListener(_onForeground);
  }

  void _arm() {
    _timer?.cancel();
    _timer = _periodic
        ? Timer.periodic(_period, (_) => _fire())
        : Timer(_period, _due);
  }

  void _due() {
    _timer = null;
    if (AppForeground.instance.value) {
      _fire();
    } else {
      _owed = true;
    }
  }

  void _fire() {
    if (_cancelled) return;
    _tick++;
    if (!_periodic) cancel();
    _callback(this);
  }

  void _onForeground() {
    if (_cancelled) return;
    final inFront = AppForeground.instance.value;
    if (_periodic) {
      if (!inFront) {
        _timer?.cancel();
        _timer = null;
      } else if (_timer == null) {
        _arm();
        _fire();
      }
    } else if (inFront && _owed) {
      _owed = false;
      _fire();
    }
  }
}
