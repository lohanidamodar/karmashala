import 'dart:async';

import 'package:agent_cli/descriptors.dart' show AgentActivityStatus;
import 'package:karmashala_agent_status/karmashala_agent_status.dart'
    show HostedAgentStatus;

import 'daemon_agent_status.dart';

/// How long the screen of a session whose reader cannot tell its status must
/// stay unchanged before its turn is taken as over: a reader that only ever
/// says working or unknown would otherwise hold its turn open forever.
const Duration kTurnQuietPeriod = Duration(seconds: 8);

/// **The one decision whether a session's turn is still running.** A turn
/// settles on idle or failed, on an ACP turn's end, or — for a session seen
/// working whose reader has since lost it (`unknown`) — on a screen that has
/// shown nothing new for [quietPeriod]. Asked on demand ([running]), and told
/// as it happens ([settled]) to the queue and the open-turn record.
class TurnSettlement {
  TurnSettlement({
    required this.status,
    this.quietPeriod = kTurnQuietPeriod,
    this.poll = const Duration(seconds: 1),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final DaemonAgentStatus status;
  final Duration quietPeriod;

  /// How often a screen is read while its turn's end is awaited by quiet.
  final Duration poll;
  final DateTime Function() _clock;

  /// Sessions seen working and not since seen idle, failed or quiet.
  final _midTurn = <String>{};
  final _screens = <String, ({String text, DateTime since})>{};

  /// Sessions whose screen is read on each [poll] until it goes quiet.
  final _watched = <String>{};
  final _settled = StreamController<String>.broadcast(sync: true);
  StreamSubscription<HostedAgentStatus>? _statuses;
  Timer? _timer;

  /// Each session whose turn settled, as it settles.
  Stream<String> get settled => _settled.stream;

  void start() => _statuses ??= status.changes.listen(_onStatus);

  Future<void> close() async {
    _timer?.cancel();
    _timer = null;
    await _statuses?.cancel();
    await _settled.close();
  }

  /// Whether [sessionId]'s turn is running now: an ACP turn open, the
  /// agent working or asking, or a turn its reader lost on a screen still
  /// moving.
  bool running(String sessionId) {
    final runtime = status.acpRuntimeOf(sessionId);
    if (runtime != null) return runtime.inTurn;
    // A turn its process took with it is over, whatever was last read of it.
    if (!status.holds(sessionId)) {
      if (_midTurn.contains(sessionId)) _settle(sessionId);
      return false;
    }
    final kind = status.statusOf(sessionId)?.report.status;
    if (_working(kind)) return true;
    if (!_unread(kind) || !_midTurn.contains(sessionId)) return false;
    return !quiet(sessionId);
  }

  /// Row [sessionId]'s agent just started, by whatever path: its start-up is
  /// a turn of its own until it reads idle or its screen goes quiet, so a
  /// reader that never says idle still lets it settle.
  void started(String sessionId) {
    if (status.acpRuntimeOf(sessionId) != null) return;
    _midTurn.add(sessionId);
    _screens.remove(sessionId);
    quiet(sessionId);
  }

  /// Whether [sessionId]'s screen has shown nothing new for [quietPeriod].
  /// Not yet, it is read on each [poll] until it has, and [settled] tells it.
  bool quiet(String sessionId) {
    if (_quietNow(sessionId)) {
      // Told once, as the turn settles; the screen stays the baseline.
      if (_midTurn.contains(sessionId) || _watched.contains(sessionId)) {
        _settle(sessionId, keepScreen: true);
      }
      return true;
    }
    if (status.holds(sessionId)) _watch(sessionId);
    return false;
  }

  void _onStatus(HostedAgentStatus change) {
    final sessionId = change.sessionId;
    final kind = change.report.status;
    if (_working(kind)) {
      _midTurn.add(sessionId);
      _watched.remove(sessionId);
      _screens.remove(sessionId);
      return;
    }
    if (_unread(kind)) {
      // The screen as the turn was lost is where its quiet is measured from.
      if (_midTurn.contains(sessionId)) quiet(sessionId);
      return;
    }
    _settle(sessionId);
  }

  void _settle(String sessionId, {bool keepScreen = false}) {
    _midTurn.remove(sessionId);
    _watched.remove(sessionId);
    if (!keepScreen) _screens.remove(sessionId);
    if (!_settled.isClosed) _settled.add(sessionId);
  }

  bool _quietNow(String sessionId) {
    final text = status.liveScreenOf(sessionId)?.tailText(40).join('\n');
    if (text == null) {
      _screens.remove(sessionId);
      return false;
    }
    final now = _clock();
    final seen = _screens[sessionId];
    if (seen == null || seen.text != text) {
      _screens[sessionId] = (text: text, since: now);
      return false;
    }
    return now.difference(seen.since) >= quietPeriod;
  }

  void _watch(String sessionId) {
    _watched.add(sessionId);
    _timer ??= Timer.periodic(poll, (_) => _tick());
  }

  void _tick() {
    for (final sessionId in _watched.toList()) {
      if (!status.holds(sessionId)) {
        _watched.remove(sessionId);
        _screens.remove(sessionId);
      } else if (_quietNow(sessionId)) {
        _settle(sessionId, keepScreen: true);
      }
    }
    if (_watched.isEmpty) {
      _timer?.cancel();
      _timer = null;
    }
  }

  static bool _working(AgentActivityStatus? status) =>
      status == AgentActivityStatus.working ||
      status == AgentActivityStatus.awaitingApproval;

  static bool _unread(AgentActivityStatus? status) =>
      status == null || status == AgentActivityStatus.unknown;
}
