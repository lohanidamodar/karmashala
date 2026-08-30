import 'dart:async';

import '../data/notification_presenter.dart';
import '../domain/notification_request.dart';

/// Collects notification-worthy events and delivers **at most one** toast per
/// coalescing window.
///
/// The watcher already batches everything it sees in a single poll, so the
/// window's job is to also absorb events that land in adjacent polls. Three
/// agents finishing within a few seconds become one notification that names
/// them, not three fighting for the same corner of the screen.
class NotificationDispatcher {
  NotificationDispatcher({
    required this.presenter,
    this.window = const Duration(seconds: 4),
    this.coalescer = const NotificationCoalescer(),
  });

  final NotificationPresenter presenter;

  /// How long to keep collecting before delivering. Trailing rather than
  /// leading: it costs up to [window] of latency and buys the guarantee that a
  /// burst is exactly one interruption.
  final Duration window;

  final NotificationCoalescer coalescer;

  final List<PendingNotification> _pending = [];
  Timer? _timer;

  int get pendingCount => _pending.length;

  void add(PendingNotification event) {
    _pending.add(event);
    _timer ??= Timer(window, () => unawaited(flush()));
  }

  /// Delivers whatever has accumulated as one notification. Public so a caller
  /// — or a test — can close the window early.
  Future<void> flush() async {
    _timer?.cancel();
    _timer = null;
    if (_pending.isEmpty) return;
    final events = List<PendingNotification>.of(_pending);
    _pending.clear();
    final request = coalescer.summarize(events);
    if (request != null) await presenter.show(request);
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
    _pending.clear();
  }
}
