import 'dart:async';

import 'package:karmashala_notifications/toasts.dart';
import 'package:karmashala_notifications/policy.dart';

/// How long an event that means *something is waiting on you* may be held —
/// under a second still reads as immediate, and absorbs a fan-out burst.
const Duration kUrgentNotificationWindow = Duration(milliseconds: 750);

/// Collects notification-worthy events and delivers at most one toast per
/// window. Every event has its own deadline, and the earliest pending wins.
class NotificationDispatcher {
  NotificationDispatcher({
    required this.presenter,
    this.window = const Duration(seconds: 4),
    this.urgentWindow = kUrgentNotificationWindow,
    this.coalescer = const NotificationCoalescer(),
    this.perSession = false,
  });

  final NotificationPresenter presenter;

  /// One notification per session in each window, rather than one summary
  /// naming them all: a phone keeps a notification per session, replaced by
  /// the next for it (Stage 3 step 2).
  final bool perSession;

  /// How long to keep collecting a turn ending before delivering. Trailing, so
  /// a burst is exactly one interruption; nobody is blocked on a finished turn.
  final Duration window;

  /// The same, for an agent that is *stopped* — waiting on an approval, or
  /// failed. See [kUrgentNotificationWindow].
  final Duration urgentWindow;

  final NotificationCoalescer coalescer;

  final List<PendingNotification> _pending = [];

  /// Time since the first event in this window. A stopwatch, not wall-clock:
  /// the system clock moving under a woken laptop must not shift a deadline.
  final Stopwatch _waiting = Stopwatch();

  /// The earliest deadline anything pending asked for, measured on [_waiting].
  Duration? _due;

  Timer? _timer;

  int get pendingCount => _pending.length;

  /// How long an event for [reason] may be held. Public so the rule is
  /// assertable rather than inferred from a stopwatch on a shared runner.
  Duration windowFor(NotificationReason reason) =>
      reason.needsUser ? urgentWindow : window;

  void add(PendingNotification event) {
    _pending.add(event);
    if (!_waiting.isRunning) _waiting.start();
    final elapsed = _waiting.elapsed;
    final due = elapsed + windowFor(event.reason);
    final current = _due;
    // Only ever brought forward: a later event must not extend or restart the
    // wait, or a chatty workspace would never close the window.
    if (current != null && current <= due) return;
    _due = due;
    _timer?.cancel();
    final wait = due - elapsed;
    _timer = Timer(
      wait.isNegative ? Duration.zero : wait,
      () => unawaited(flush()),
    );
  }

  /// Forgets [openId]'s pending ask: answered before its window closed, it
  /// must not go up after the withdrawal that meant to take it down.
  void dropAsk(String openId) {
    _pending.removeWhere(
      (event) =>
          event.session.openId == openId &&
          event.reason == NotificationReason.needsInput,
    );
    if (_pending.isNotEmpty) return;
    _timer?.cancel();
    _timer = null;
    _due = null;
    _waiting
      ..stop()
      ..reset();
  }

  /// Delivers whatever has accumulated as one notification. Public so a caller
  /// — or a test — can close the window early.
  Future<void> flush() async {
    _timer?.cancel();
    _timer = null;
    _due = null;
    _waiting
      ..stop()
      ..reset();
    if (_pending.isEmpty) return;
    final events = List<PendingNotification>.of(_pending);
    _pending.clear();
    if (perSession) {
      final bySession = <String, List<PendingNotification>>{};
      for (final event in events) {
        (bySession['${event.session.key}'] ??= []).add(event);
      }
      for (final group in bySession.values) {
        final request = coalescer.summarize(group);
        if (request != null) await presenter.show(request);
      }
      return;
    }
    final request = coalescer.summarize(events);
    if (request != null) await presenter.show(request);
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
    _due = null;
    _waiting
      ..stop()
      ..reset();
    _pending.clear();
  }
}
