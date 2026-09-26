import 'dart:async';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/usage.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_environments/karmashala_environments.dart';

import '../data/data_service.dart';

/// How long an account whose last attempt failed for a reason a person must
/// fix (a lapsed sign-in) waits before the schedule asks again — the idle
/// ceiling: a fix is noticed within it, and nobody is asked every minute.
const Duration kUsageRetryAfterAuth = kUsageIdleCeiling;

/// How long after any other failure (unreachable, unusable) it asks again.
const Duration kUsageRetryAfterFailure = Duration(minutes: 5);

/// **Every agent account's usage, read by the server** — on its own schedule
/// and when a client asks (`usage.refresh`) — through each adapter's usage
/// capability, from the credentials on this machine. The one
/// [AgentUsageService] behind it holds the throttle, so no path here or at
/// the phone can ask a vendor more often than an account's floor, and a rate
/// limit in force is sat out.
///
/// Each reading off the wire is recorded in the usage history
/// (`usageSamplesOf`, kept by `usageSampleWorthKeeping`), and each account's
/// state — the reading, how the last attempt failed, when it asks next — is
/// told to every client as it changes ([UsageStateChanged]). The schedule is
/// the throttle's own: the floor while the quota moves, doubling to the idle
/// ceiling while it does not, and the instant after a window resets; a
/// session's row moving asks again (inside the floor that costs nothing).
/// Nothing here names an agent: an account is offered when its adapter
/// declares usage.
class ServerUsage {
  ServerUsage({
    required DataService data,
    required AgentUsageService service,
    this.registry = AgentRegistry.builtIn,
    Clock clock = const SystemClock(),
  }) : _data = data,
       _service = service,
       _clock = clock {
    _service.addReadingListener(_recorded);
  }

  final DataService _data;
  final AgentUsageService _service;
  final AgentRegistry registry;
  final Clock _clock;

  /// The service every usage read on this server goes through — the phone's
  /// `usage.get` too, so the throttle is one per account.
  AgentUsageService get service => _service;

  final _states = <String, AccountUsageState>{};
  final _inFlight = <String, Future<void>>{};
  Timer? _timer;
  var _running = false;

  /// One installation per account whose adapter reads usage — two installs
  /// of one CLI in one place share an account.
  List<AgentInstallation> accounts() {
    final seen = <String>{};
    return [
      for (final installation in _data.installations)
        if (registry.adapterFor(installation.agentId)?.usage != null &&
            seen.add(usageAccountKey(installation)))
          installation,
    ];
  }

  /// Every account as last read, in the installations' order.
  List<AccountUsageState> states() => [
    for (final installation in accounts()) _stateOf(installation),
  ];

  AccountUsageState _stateOf(AgentInstallation installation) =>
      _states[usageAccountKey(installation)] ??
      AccountUsageState(
        accountKey: usageAccountKey(installation),
        agentId: installation.agentId,
        environmentId: installation.environmentId,
      );

  /// Reads [accountKey] now (every account when null), through the
  /// throttle, and answers the accounts as they then stand.
  Future<List<AccountUsageState>> refresh({String? accountKey}) async {
    final asked = [
      for (final installation in accounts())
        if (accountKey == null || usageAccountKey(installation) == accountKey)
          installation,
    ];
    if (accountKey != null && asked.isEmpty) {
      throw DataRefused.notFound('no agent account $accountKey reads usage');
    }
    await Future.wait([for (final installation in asked) _read(installation)]);
    return [for (final installation in asked) _stateOf(installation)];
  }

  /// Starts the schedule: every account is read once now, then each when it
  /// is due.
  void start() {
    if (_running) return;
    _running = true;
    _data.addChangeListener(_changed);
    unawaited(_tick());
  }

  void stop() {
    _running = false;
    _timer?.cancel();
    _timer = null;
    _data.removeChangeListener(_changed);
  }

  /// A session row moving is the sign an account is being spent: ask again
  /// (inside the floor the throttle answers from memory). A new installation
  /// is a new account to read.
  void _changed(List<DataChange> changes) {
    if (!_running) return;
    final keys = <String>{};
    var accountsMoved = false;
    for (final change in changes) {
      switch (change) {
        case SessionRowChanged(:final session):
          for (final installation in _data.installations) {
            if (installation.id == session.agentInstallationId) {
              keys.add(usageAccountKey(installation));
            }
          }
        case InstallationChanged() || InstallationRemoved():
          accountsMoved = true;
        default:
          break;
      }
    }
    for (final key in keys) {
      unawaited(
        refresh(
          accountKey: key,
        ).catchError((Object _) => const <AccountUsageState>[]),
      );
    }
    if (accountsMoved) unawaited(_tick());
  }

  Future<void> _tick() async {
    _timer?.cancel();
    _timer = null;
    final now = _clock.nowUtc();
    final due = [
      for (final installation in accounts())
        if (_dueAt(installation) case final at? when !at.isAfter(now))
          installation,
    ];
    await Future.wait([for (final installation in due) _read(installation)]);
    _arm();
  }

  void _arm() {
    if (!_running) return;
    DateTime? next;
    for (final installation in accounts()) {
      final at = _dueAt(installation);
      if (at != null && (next == null || at.isBefore(next))) next = at;
    }
    if (next == null) return;
    var wait = next.difference(_clock.nowUtc());
    if (wait < const Duration(seconds: 1)) wait = const Duration(seconds: 1);
    _timer = Timer(wait, () => unawaited(_tick()));
  }

  /// When [installation]'s account is next asked about: now for one never
  /// read, else what its state says (null: only when a client asks).
  DateTime? _dueAt(AgentInstallation installation) {
    final state = _states[usageAccountKey(installation)];
    if (state == null) return _clock.nowUtc();
    return state.nextAt;
  }

  Future<void> _read(AgentInstallation installation) {
    final key = usageAccountKey(installation);
    // A block, not `=> _inFlight.remove(key)`: that returns the removed
    // future — this one — and `whenComplete` would await it, forever.
    return _inFlight[key] ??= _readNow(installation).whenComplete(() {
      _inFlight.remove(key);
    });
  }

  Future<void> _readNow(AgentInstallation installation) async {
    final now = _clock.nowUtc();
    try {
      final usage = await _service.fetch(installation, _data.environments);
      _put(
        installation,
        usage: usage,
        failure: null,
        nextAt: _nextAsk(installation),
      );
    } on UsageException catch (error) {
      final until = error.retryIn == null ? null : now.add(error.retryIn!);
      _put(
        installation,
        usage: _service.remembered(installation),
        failure: UsageFailure(
          message: error.message,
          kind: error.kind,
          until: until,
        ),
        nextAt: switch (error.kind) {
          // Asked again when a client asks, or its installation changes.
          UsageFailureKind.notAsked => null,
          UsageFailureKind.rateLimited ||
          UsageFailureKind.serverBusy => until ?? now.add(kUsageMinInterval),
          UsageFailureKind.auth => now.add(kUsageRetryAfterAuth),
          UsageFailureKind.unreachable ||
          UsageFailureKind.unusable => now.add(kUsageRetryAfterFailure),
        },
      );
    } on Object catch (error) {
      _put(
        installation,
        usage: _service.remembered(installation),
        failure: UsageFailure(
          message: 'Could not read usage: $error',
          kind: UsageFailureKind.unusable,
        ),
        nextAt: now.add(kUsageRetryAfterFailure),
      );
    }
  }

  void _put(
    AgentInstallation installation, {
    required AgentUsage? usage,
    required UsageFailure? failure,
    required DateTime? nextAt,
  }) {
    final state = AccountUsageState(
      accountKey: usageAccountKey(installation),
      agentId: installation.agentId,
      environmentId: installation.environmentId,
      usage: usage,
      failure: failure,
      nextAt: nextAt,
    );
    final before = _states[state.accountKey];
    _states[state.accountKey] = state;
    if (before == null || !before.sameAs(state)) _data.announceUsage(state);
  }

  /// A reading that came off the wire, however it was asked for (the phone's
  /// `usage.get` too): into the history.
  void _recorded(AgentInstallation installation, AgentUsage usage) {
    _data.recordUsage(usageSamplesOf(usageAccountKey(installation), usage));
    _put(
      installation,
      usage: usage,
      failure: null,
      nextAt: _nextAsk(installation),
    );
  }

  /// When the throttle's schedule asks next, to the second — so the same
  /// reading told twice is the same state.
  DateTime _nextAsk(AgentInstallation installation) {
    final at = _clock.nowUtc().add(_service.dueIn(installation));
    return DateTime.fromMillisecondsSinceEpoch(
      (at.millisecondsSinceEpoch / 1000).round() * 1000,
      isUtc: true,
    );
  }
}
