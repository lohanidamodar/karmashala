import 'dart:async';
import 'dart:convert';

import 'package:agent_cli/process.dart' show EnvironmentPath;
import 'package:karmashala_automations/store.dart' show CheckoutRows;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_notifications/policy.dart';
import 'package:karmashala_session/delivery.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';

/// Set to `off` to keep the server from reading deliveries on its own — a
/// test's server, whose rows point at folders that are nobody's checkouts.
const String kDeliveryPollVariable = 'KARMASHALA_DELIVERY_POLL';

/// How often every watched checkout's pull request and checks are read again
/// — two minutes, as the app's poll was, because each read is a `gh`.
const Duration kDeliveryPollInterval = Duration(minutes: 2);

/// The shortest gap between two reads of one checkout a turn ending there
/// asks for.
const Duration kDeliveryTouchFloor = Duration(seconds: 30);

/// How many checkouts one sweep reads, newest sessions first.
const int kDeliveryCheckoutsPerSweep = 40;

/// How long after its row was created an ended session's checkout is still
/// worth reading: a PR opened at the end of the work goes red afterwards.
const Duration kDeliveryRecentWindow = Duration(days: 7);

/// **Every live session's delivery, read by the server** (slice 5c) — the
/// app's two-minute pull-request poll, moved, so a PR going red, a review
/// asking for changes, or one ready to merge is noticed with every app
/// closed. Each sweep reads, per checkout, the local half (`git.delivery`,
/// 3b) and, for a branch that has a remote, the forge's (`github.pullRequest`);
/// each session's delivery is judged for news by the one policy
/// ([news] → the attention's inbox), a changed forge reading is told to every
/// client ([ForgeReadingChanged], which a window draws instead of polling),
/// and a phone asks the stage of the last reading ([stageOf]).
///
/// Which sessions: every one not archived that claims to run, runs here, is
/// looked at by some window, had an open pull request at the last read, or
/// was started within [kDeliveryRecentWindow] — newest first, at most
/// [kDeliveryCheckoutsPerSweep] checkouts a sweep, one read at a time.
class DeliveryWatch {
  DeliveryWatch({
    required AppDatabase database,
    required this.git,
    required this.tell,
    required this.news,
    this.lookingAt,
    this.runs,
    this.interval = kDeliveryPollInterval,
    this.touchFloor = kDeliveryTouchFloor,
    DateTime Function()? clock,
    this.log,
  }) : _sessions = SessionDao(database),
       _rows = CheckoutRows(database),
       _now = clock ?? _utcNow;

  /// The server's git work (`ServerGit`), answering `git.delivery` and
  /// `github.pullRequest`.
  final Future<Object?> Function(GitWorkRequest<Object?> request) git;

  /// Tells every subscribed client — `DataService.announce`.
  final void Function(List<DataChange> changes) tell;

  /// Session [String]'s delivery asks [NotificationReason] of a person now,
  /// or nothing — the attention decides whether that is news.
  final void Function(String sessionId, NotificationReason? news) news;

  /// The rows some window is looking at: read first.
  final Set<String> Function()? lookingAt;

  /// Whether the server runs row [String]'s agent now.
  final bool Function(String sessionId)? runs;

  final Duration interval;
  final Duration touchFloor;
  final void Function(String message)? log;

  final SessionDao _sessions;
  final CheckoutRows _rows;
  final DateTime Function() _now;
  final _policy = const AgentNotificationPolicy();

  /// Each checkout's last forge reading, by its [_key], and the checkout.
  final Map<String, (EnvironmentPath, PullRequestReading)> _forge = {};
  final Map<String, String> _forgeJson = {};
  final Map<String, SessionDelivery> _bySession = {};
  final Map<String, DateTime> _lastRead = {};
  Timer? _timer;
  Future<void>? _sweeping;
  var _stopped = false;

  /// Sweeps run, for tests and diagnostics.
  int sweeps = 0;

  /// Session [sessionId]'s delivery as last read, or null (never read).
  SessionDelivery? deliveryOf(String sessionId) => _bySession[sessionId];

  /// [deliveryOf]'s stage, by name — what a phone's row shows.
  String? stageOf(String sessionId) => _bySession[sessionId]?.stage.name;

  /// Every forge reading kept: what a subscriber is greeted with.
  List<DataChange> greeting() => [
    for (final (checkout, reading) in _forge.values)
      ForgeReadingChanged(checkout, reading),
  ];

  /// Starts the schedule: a first sweep after [firstAfter], then every
  /// [interval].
  void start({Duration firstAfter = const Duration(seconds: 10)}) {
    if (_timer != null || _stopped) return;
    _timer = Timer(firstAfter, () {
      unawaited(sweep());
      _timer = Timer.periodic(interval, (_) => unawaited(sweep()));
    });
  }

  void stop() {
    _stopped = true;
    _timer?.cancel();
    _timer = null;
  }

  /// A write the data service told: a checkout a turn ended in (or a git
  /// write) is read again now, at most once per [touchFloor].
  void changed(List<DataChange> changes) {
    for (final change in changes) {
      if (change is! CheckoutTouched) continue;
      final checkout = EnvironmentPath(
        environmentId: change.environmentId,
        path: change.path,
      );
      final last = _lastRead[_key(checkout)];
      if (last != null && _now().difference(last) < touchFloor) continue;
      unawaited(_readSessionsAt(checkout));
    }
  }

  /// One sweep over every watched checkout; a sweep asked for while one runs
  /// joins it.
  Future<void> sweep() => _sweeping ??= _sweep().whenComplete(() {
    _sweeping = null;
  });

  Future<void> _sweep() async {
    sweeps++;
    final byCheckout = _watchedByCheckout();
    for (final entry in byCheckout.entries) {
      if (_stopped) return;
      await _read(entry.value.$1, entry.value.$2);
    }
  }

  Future<void> _readSessionsAt(EnvironmentPath checkout) async {
    final key = _key(checkout);
    final watched = _watchedByCheckout(all: true)[key];
    if (watched == null) return;
    await _read(watched.$1, watched.$2);
  }

  /// The watched sessions, grouped by the checkout each works in, newest
  /// first, capped.
  Map<String, (EnvironmentPath, List<Session>)> _watchedByCheckout({
    bool all = false,
  }) {
    final now = _now();
    final looking = lookingAt?.call() ?? const <String>{};
    final rows =
        [
          for (final row in _sessions.getAll())
            if (!row.isArchived &&
                (row.status.claimsLive ||
                    looking.contains(row.id) ||
                    (runs?.call(row.id) ?? false) ||
                    (_bySession[row.id]?.pullRequest?.isOpen ?? false) ||
                    now.difference(row.createdAt) <= kDeliveryRecentWindow))
              row,
        ]..sort((a, b) {
          final aLooked = looking.contains(a.id) ? 0 : 1;
          final bLooked = looking.contains(b.id) ? 0 : 1;
          if (aLooked != bLooked) return aLooked - bLooked;
          return b.createdAt.compareTo(a.createdAt);
        });
    final out = <String, (EnvironmentPath, List<Session>)>{};
    for (final row in rows) {
      final directory =
          row.worktree ?? _rows.repository(row.repositoryId)?.path;
      if (directory == null) continue;
      final key = _key(directory);
      final group = out[key];
      if (group != null) {
        group.$2.add(row);
        continue;
      }
      if (!all && out.length >= kDeliveryCheckoutsPerSweep) continue;
      out[key] = (directory, [row]);
    }
    return out;
  }

  Future<void> _read(EnvironmentPath checkout, List<Session> sessions) async {
    _lastRead[_key(checkout)] = _now();
    final first = sessions.first;
    final repository = first.worktree == null
        ? null
        : _rows.repository(first.repositoryId)?.path;
    SessionDelivery local;
    try {
      local =
          await git(
                GitDelivery(CheckoutRef.at(checkout), repository: repository),
              )
              as SessionDelivery;
    } on Object catch (error) {
      log?.call('delivery: ${checkout.path} could not be read ($error)');
      return;
    }
    var reading = PullRequestReading.none;
    final branch = local.branch;
    if (branch != null && local.hasRemote == true) {
      try {
        reading =
            await git(
                  GitHubPullRequest(CheckoutRef.at(checkout), branch: branch),
                )
                as PullRequestReading;
      } on Object {
        // No forge, no `gh`, not signed in: nothing a person is asked for.
      }
    }
    if (_stopped) return;
    final key = _key(checkout);
    final json = jsonEncode(reading.toJson());
    _forge[key] = (checkout, reading);
    if (_forgeJson[key] != json) {
      _forgeJson[key] = json;
      tell([ForgeReadingChanged(checkout, reading)]);
    }
    for (final session in sessions) {
      final delivery = local.copyWith(
        pullRequest: reading.pullRequest,
        mergeStrategies: reading.strategies,
        branchProtection: reading.protection,
        agentRunning: runs?.call(session.id),
        hasWorktree: session.worktree != null,
      );
      _bySession[session.id] = delivery;
      news(session.id, _policy.deliveryNewsIn(delivery));
    }
  }

  static String _key(EnvironmentPath path) =>
      '${path.environmentId}\u0000${path.path}';

  static DateTime _utcNow() => DateTime.now().toUtc();
}
