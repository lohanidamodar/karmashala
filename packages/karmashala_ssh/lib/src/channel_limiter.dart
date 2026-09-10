import 'dart:async';
import 'dart:collection';

/// Caps the channels one connection opens at once: OpenSSH's `MaxSessions`
/// defaults to 10, and a channel past the limit fails rather than waiting.
class ChannelLimiter {
  ChannelLimiter(this.limit) : assert(limit > 0), _available = limit;

  /// Maximum simultaneous channels. Deliberately below the usual server default
  /// so long-lived streaming sessions still have room beside pooled commands.
  final int limit;

  int _available;
  final Queue<Completer<void>> _waiting = Queue<Completer<void>>();

  /// Channels currently held.
  int get inUse => limit - _available;

  /// Callers queued for a slot.
  int get waiting => _waiting.length;

  /// Runs [body] holding one slot, releasing it however [body] ends.
  Future<T> withSlot<T>(Future<T> Function() body) async {
    await _acquire();
    try {
      return await body();
    } finally {
      _release();
    }
  }

  Future<void> _acquire() {
    if (_available > 0) {
      _available--;
      return Future.value();
    }
    final waiter = Completer<void>();
    _waiting.add(waiter);
    return waiter.future;
  }

  void _release() {
    if (_waiting.isEmpty) {
      _available++;
      return;
    }
    _waiting.removeFirst().complete();
  }
}
