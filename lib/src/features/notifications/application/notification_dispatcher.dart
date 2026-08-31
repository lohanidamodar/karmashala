import 'dart:async';

import '../data/notification_presenter.dart';
import '../domain/notification_policy.dart';
import '../domain/notification_request.dart';

/// How long an event that means *something is waiting on you* may be held.
///
/// Short enough to read as immediate — under a second is the threshold where a
/// toast still feels like a consequence of what the agent just did — and wide
/// enough to absorb a fan-out batch whose agents all reach an approval prompt
/// together, so the common burst is still one interruption.
const Duration kUrgentNotificationWindow = Duration(milliseconds: 750);

/// Collects notification-worthy events and delivers **at most one** toast per
/// coalescing window.
///
/// The watcher already batches everything it sees in a single poll, so the
/// window's job is to also absorb events that land in adjacent polls. Three
/// agents finishing within a few seconds become one notification that names
/// them, not three fighting for the same corner of the screen.
///
/// **Every event has its own deadline, and the earliest one pending wins.**
/// `b8d22af` made a hook reach the registry, the tray and the inbox as it
/// lands; the toast — the one surface that reaches a user who has looked away —
/// still waited the full window, so an agent blocked on a permission prompt was
/// the most time-sensitive thing this app reports and the slowest to say so.
/// A blocked agent now waits [urgentWindow] and a finished turn waits [window],
/// whichever of them arrived first. Coalescing is untouched: a shorter deadline
/// moves *when* the window closes, never how much it collected.
class NotificationDispatcher {
  NotificationDispatcher({
    required this.presenter,
    this.window = const Duration(seconds: 4),
    this.urgentWindow = kUrgentNotificationWindow,
    this.coalescer = const NotificationCoalescer(),
  });

  final NotificationPresenter presenter;

  /// How long to keep collecting a turn ending before delivering. Trailing
  /// rather than leading: it costs up to [window] of latency and buys the
  /// guarantee that a burst is exactly one interruption. Nobody is blocked on
  /// a finished turn, so it can afford the wait.
  final Duration window;

  /// The same, for an agent that is *stopped* — waiting on an approval, or
  /// failed. See [kUrgentNotificationWindow].
  final Duration urgentWindow;

  final NotificationCoalescer coalescer;

  final List<PendingNotification> _pending = [];

  /// Time since the first event in this window, so deadlines set by different
  /// events are comparable. A stopwatch rather than wall-clock reads: this must
  /// not be moved by the system clock changing under a laptop that woke up.
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
    // Only ever brought forward. A finished turn arriving behind an approval
    // must not extend the wait, and one arriving behind another must not
    // restart it — a chatty workspace would otherwise never close the window.
    if (current != null && current <= due) return;
    _due = due;
    _timer?.cancel();
    final wait = due - elapsed;
    _timer = Timer(
      wait.isNegative ? Duration.zero : wait,
      () => unawaited(flush()),
    );
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
