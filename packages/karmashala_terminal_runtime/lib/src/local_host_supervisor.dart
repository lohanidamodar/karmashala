import 'dart:async';

import 'package:karmashala_core/logging.dart';
import 'package:karmashala_host_protocol/host_access.dart';

import 'local_host_access.dart';

/// How long the supervisor waits before each attempt, in a row, to bring this
/// machine's host back. Past the last it stops and says why: a host that exits
/// every time it starts is not mended by starting it again.
const List<Duration> kHostRestartBackoff = [
  Duration(seconds: 1),
  Duration(seconds: 2),
  Duration(seconds: 5),
  Duration(seconds: 30),
  Duration(seconds: 30),
  Duration(seconds: 30),
];

/// Where the supervisor stands with this machine's host.
enum HostSupervisionPhase {
  /// Nothing has been started or looked at yet.
  idle,

  /// The launch's start is under way.
  starting,

  /// A host of this app's build answers.
  running,

  /// The host went, or would not start; the next attempt is scheduled.
  restarting,

  /// An earlier Karmashala's host holds running sessions, so it is left
  /// running until they end or the person restarts it.
  outdated,

  /// Not restarted on the backoff any more: there is no binary, or the host
  /// kept exiting. Still looked at on a slow timer ([HostSupervision.
  /// nextAttemptAt]) — a binary that comes back is started — and the person
  /// may restart it at once.
  stopped,
}

/// One reading of the supervision, for Settings and the banner.
class HostSupervision {
  const HostSupervision({
    required this.phase,
    required this.observedAt,
    this.reading,
    this.reason,
    this.attempt = 0,
    this.maxAttempts = 0,
    this.nextAttemptAt,
    this.lastOutput = const [],
  });

  final HostSupervisionPhase phase;
  final DateTime observedAt;

  /// The last reading of the host, when one was taken.
  final HostDeployment? reading;

  /// Why it is restarting or stopped, or what the outdated host holds.
  final String? reason;

  /// Attempts made in a row without the host staying up.
  final int attempt;
  final int maxAttempts;

  /// When the next attempt runs, while [HostSupervisionPhase.restarting], or
  /// the next slow look while [HostSupervisionPhase.stopped].
  final DateTime? nextAttemptAt;

  /// The last lines the host printed, when this app started it.
  final List<String> lastOutput;

  int? get pid => reading?.hostPid;
  String? get version => reading?.hostVersion;

  /// The sessions an outdated host is running; null when it would not say,
  /// which counts as some.
  List<String>? get heldSessions => reading?.liveSessionIds;
}

/// Keeps this machine's session host up while the app is open.
///
/// **Detection.** Told by [hostLost] — the lifecycle link closed — and by the
/// `serve` this app started closing both its pipes ([LocalHostSessionAccess.
/// serveExited]). Either is checked with a handshake before anything is
/// started: a link that dropped under a host that still answers is no loss.
///
/// **Restart.** Through [LocalHostSessionAccess.deployment], the launch's own
/// path, with its arguments — which never starts a second host over a socket
/// something holds, and replaces an earlier Karmashala's host only when it
/// holds no running sessions. Attempts wait [backoff] in turn; a host that
/// stays up [stableAfter] clears the count. Past the last delay it stops and
/// keeps the host's last output as the reason. Each time a host is up again,
/// [restarted] fires so everything that rides it re-attaches.
///
/// **Stopped is not forever.** With no binary it looks again every
/// [noBinaryRecheck] — a rebuild or an update puts one back — and a [nudge]
/// (the data client redialling a server that is not there) brings that look
/// forward, at most once per [nudgeFloor]. After a crash loop the host is
/// tried once more every [crashLoopRecheck]; nudges do not shorten that, or
/// the cap would mean nothing.
///
/// **An older host holding sessions** is never killed from here: it is
/// [HostSupervisionPhase.outdated], looked at again every [outdatedRecheck]
/// (and replaced then if it holds nothing), and only [restartNow] with
/// `force` — the person's say-so — ends what it runs.
class LocalHostSupervisor {
  LocalHostSupervisor({
    required this.access,
    this.backoff = kHostRestartBackoff,
    this.stableAfter = const Duration(seconds: 30),
    this.outdatedRecheck = const Duration(seconds: 30),
    this.noBinaryRecheck = const Duration(seconds: 30),
    this.crashLoopRecheck = const Duration(minutes: 5),
    this.nudgeFloor = const Duration(seconds: 10),
    DateTime Function()? now,
    AppLogger? logger,
  }) : _now = now ?? DateTime.now,
       _log = logger ?? AppLogger.named('host.supervisor') {
    _state = HostSupervision(
      phase: HostSupervisionPhase.idle,
      observedAt: _now(),
      maxAttempts: backoff.length,
    );
    _exits = access.serveExited.listen(
      (exit) => hostLost(
        exit.lastOutput.isEmpty
            ? 'the session host exited'
            : 'the session host exited: ${exit.lastOutput.last}',
        output: exit.lastOutput,
      ),
    );
  }

  final LocalHostSessionAccess access;
  final List<Duration> backoff;
  final Duration stableAfter;
  final Duration outdatedRecheck;

  /// How often a supervisor stopped for want of a binary looks for one.
  final Duration noBinaryRecheck;

  /// How often a supervisor stopped by a crash loop tries the host once more.
  final Duration crashLoopRecheck;

  /// The least time between two looks a [nudge] may cause.
  final Duration nudgeFloor;
  final DateTime Function() _now;
  final AppLogger _log;

  late HostSupervision _state;
  final _changes = StreamController<HostSupervision>.broadcast();
  final _restarted = StreamController<HostDeployment>.broadcast();
  late final StreamSubscription<HostServeExit> _exits;

  Future<HostDeployment?>? _first;
  Timer? _next;
  Timer? _stable;
  DateTime? _runningSince;
  var _attempts = 0;
  var _busy = false;

  /// Whether the stop was a crash loop rather than a missing binary.
  var _crashLoop = false;

  /// Whether the person stopped the host. Nothing starts it again — no
  /// backoff, no slow look, no nudge — until [restartNow].
  var _heldStopped = false;

  /// Why a supervisor the person stopped says it is stopped.
  static const stoppedByPerson = 'you stopped it · Start runs it again';

  /// When a stopped supervisor last looked, for [nudgeFloor].
  DateTime? _lastLook;
  var _disposed = false;
  List<String> _lastOutput = const [];

  HostSupervision get state => _state;

  /// Every change of [state].
  Stream<HostSupervision> get changes => _changes.stream;

  /// Each time a host answers after a start or a loss: the lifecycle link,
  /// hooks and whatever else rides the host dial again.
  Stream<HostDeployment> get restarted => _restarted.stream;

  /// The launch's start, once. Null when it threw; a failure is retried on
  /// the backoff either way.
  Future<HostDeployment?> start() => _first ??= _startFirst();

  Future<HostDeployment?> _startFirst() async {
    _set(HostSupervisionPhase.starting);
    final reading = await _measure(() => access.deployment());
    if (_disposed) return reading;
    // Not announced: the launch dials what rides the host itself, after its
    // hook sweep, so nothing races ahead of the order host, hooks, feed.
    _settle(
      reading ?? _failed('starting the session host threw'),
      announce: false,
    );
    return reading;
  }

  /// The lifecycle link closed, or the host process went: [why] in words, and
  /// the host's last [output] when it is known.
  void hostLost(String why, {List<String>? output}) {
    if (_disposed) return;
    if (output != null && output.isNotEmpty) _lastOutput = output;
    // Already on it, not started yet, or left to the person.
    if (_busy ||
        _state.phase == HostSupervisionPhase.idle ||
        _state.phase == HostSupervisionPhase.starting ||
        _state.phase == HostSupervisionPhase.restarting ||
        _state.phase == HostSupervisionPhase.stopped) {
      return;
    }
    unawaited(_confirmLoss(why));
  }

  /// A lifecycle link opened: a host is there, whoever started it. Taken as a
  /// reason to look, so a host started by hand while supervision had given up
  /// is shown as running.
  void hostAttached() {
    if (_disposed || _busy || _state.phase == HostSupervisionPhase.running) {
      return;
    }
    unawaited(_confirmAttached());
  }

  /// Something that needs the host found it missing — the data client's
  /// redial. While stopped for want of a binary, looks now instead of at the
  /// next [noBinaryRecheck], at most once per [nudgeFloor]; ignored otherwise
  /// (running, restarting and outdated already have their own timers, and a
  /// crash loop keeps its slow one).
  void nudge(String why) {
    if (_disposed ||
        _busy ||
        _heldStopped ||
        _state.phase != HostSupervisionPhase.stopped ||
        _crashLoop) {
      return;
    }
    final last = _lastLook;
    if (last != null && _now().difference(last) < nudgeFloor) return;
    _next?.cancel();
    unawaited(_look(why));
  }

  /// A stopped supervisor's look: start the host if it can be started now.
  Future<void> _look(String why) async {
    if (_disposed ||
        _busy ||
        _heldStopped ||
        _state.phase != HostSupervisionPhase.stopped) {
      return;
    }
    _lastLook = _now();
    await _attemptNow(why);
  }

  /// The person asked: the count is cleared and the host is started, or —
  /// when one answers — stopped and started. [force] ends what it runs.
  Future<HostDeployment?> restartNow({bool force = false}) async {
    if (_disposed) return null;
    _heldStopped = false;
    _next?.cancel();
    _attempts = 0;
    _lastOutput = const [];
    _set(HostSupervisionPhase.restarting, reason: 'restart requested');
    _busy = true;
    HostDeployment? reading;
    try {
      final seen = await _measure(() => access.observe());
      final answering =
          seen != null &&
          (seen.isReady ||
              seen.hostUnresponsive ||
              seen.status == HostDeploymentStatus.protocolMismatch);
      reading = await _measure(
        answering
            ? () => access.restartHost(force: force)
            : () {
                access.forget();
                return access.deployment();
              },
      );
    } finally {
      _busy = false;
    }
    if (_disposed) return reading;
    _settle(reading ?? _failed('restarting the session host threw'));
    return reading;
  }

  /// The person asked: the host is stopped and held stopped — the loss is
  /// theirs, not a crash to recover from. [force] ends what it runs.
  Future<HostDeployment?> stopNow({bool force = false}) async {
    if (_disposed) return null;
    _heldStopped = true;
    _next?.cancel();
    _stable?.cancel();
    _busy = true;
    HostDeployment? reading;
    try {
      reading = await _measure(() => access.stopHost(force: force));
    } finally {
      _busy = false;
    }
    if (_disposed) return reading;
    final refused = reading?.status == HostDeploymentStatus.cannotStart;
    if (refused) _heldStopped = false;
    _set(
      refused ? _state.phase : HostSupervisionPhase.stopped,
      reason: refused ? reading!.reason : stoppedByPerson,
    );
    return reading;
  }

  Future<void> _confirmLoss(String why) async {
    _busy = true;
    final seen = await _measure(() => access.observe());
    _busy = false;
    if (_disposed) return;
    if (seen != null && seen.isReady) {
      // Still there — or already back, started by somebody else.
      _settle(seen);
      return;
    }
    final quick =
        _runningSince != null &&
        _now().difference(_runningSince!) < stableAfter;
    _stable?.cancel();
    _runningSince = null;
    // A host that stayed up earns a fresh count; one that went at once
    // carries the count on, which is what ends a crash loop.
    if (!quick) _attempts = 0;
    _log.warning('The session host was lost ($why); starting it again.');
    _scheduleAttempt(why);
  }

  Future<void> _confirmAttached() async {
    _busy = true;
    final seen = await _measure(() => access.observe());
    _busy = false;
    if (_disposed || seen == null || !seen.isReady) return;
    _next?.cancel();
    _settle(seen);
  }

  Future<void> _attemptNow(String why) async {
    if (_disposed) return;
    _busy = true;
    access.forget();
    final reading = await _measure(() => access.deployment());
    _busy = false;
    if (_disposed) return;
    _settle(reading ?? _failed(why), why: why);
  }

  /// Decides what [reading] means for supervision; a host that is up is
  /// announced on [restarted] unless [announce] is false.
  void _settle(HostDeployment reading, {String? why, bool announce = true}) {
    _next?.cancel();
    if (reading.isReady && !reading.hostOutdated) {
      final replaced =
          _state.phase != HostSupervisionPhase.running ||
          _state.pid != reading.hostPid;
      if (_state.phase != HostSupervisionPhase.running) {
        _runningSince = _now();
        _stable?.cancel();
        _stable = Timer(stableAfter, () {
          _attempts = 0;
          _lastOutput = const [];
        });
      }
      _set(HostSupervisionPhase.running, reading: reading);
      if (replaced && announce) _restarted.add(reading);
      return;
    }
    if (reading.hostOutdated) {
      _set(
        HostSupervisionPhase.outdated,
        reading: reading,
        reason: reading.reason,
      );
      // An outdated host of this protocol still serves the lifecycle feed.
      if (reading.isReady && announce) _restarted.add(reading);
      // Looked at again, so it is replaced once what it runs has ended.
      _next = Timer(
        outdatedRecheck,
        () => unawaited(_attemptNow('looking at the older session host again')),
      );
      return;
    }
    if (reading.status == HostDeploymentStatus.noBinary) {
      // Nothing was started, so nothing crashed: a binary that comes back
      // starts on a fresh count.
      _attempts = 0;
      _stop(reading: reading, reason: reading.reason, crashLoop: false);
      return;
    }
    // Would not start, would not answer, or nobody is there: another attempt.
    _stable?.cancel();
    _runningSince = null;
    _scheduleAttempt(reading.reason, reading: reading);
  }

  void _scheduleAttempt(String why, {HostDeployment? reading}) {
    if (_disposed) return;
    _next?.cancel();
    final output = _lastOutput.isNotEmpty
        ? _lastOutput
        : access.lastServeOutput;
    if (_attempts >= backoff.length) {
      _log.error(
        'Stopped restarting the session host after $_attempts attempts: $why',
      );
      _stop(
        reading: reading,
        reason:
            'It was started again $_attempts times in a row and went down or '
            'failed each time, so it is now tried only every '
            '${_describe(crashLoopRecheck)}. Last: $why',
        output: output,
        crashLoop: true,
      );
      return;
    }
    final delay = backoff[_attempts++];
    _set(
      HostSupervisionPhase.restarting,
      reading: reading,
      reason: why,
      nextAttemptAt: _now().add(delay),
      output: output,
    );
    _next = Timer(delay, () => unawaited(_attemptNow(why)));
  }

  /// Stopped, with the slow look scheduled.
  void _stop({
    required String? reason,
    required bool crashLoop,
    HostDeployment? reading,
    List<String> output = const [],
  }) {
    _next?.cancel();
    _crashLoop = crashLoop;
    final delay = crashLoop ? crashLoopRecheck : noBinaryRecheck;
    _set(
      HostSupervisionPhase.stopped,
      reading: reading,
      reason: reason,
      nextAttemptAt: _now().add(delay),
      output: output,
    );
    _next = Timer(
      delay,
      () => unawaited(
        _look(
          crashLoop
              ? 'trying the session host again after it kept exiting'
              : 'looking for the session host binary again',
        ),
      ),
    );
  }

  static String _describe(Duration delay) =>
      delay.inMinutes >= 1 ? '${delay.inMinutes} min' : '${delay.inSeconds} s';

  /// [read], with a throw turned into null: supervision never fails.
  Future<HostDeployment?> _measure(
    Future<HostDeployment> Function() read,
  ) async {
    try {
      return await read();
    } on Object catch (error) {
      _log.warning('Reading the session host failed: $error');
      return null;
    }
  }

  HostDeployment _failed(String why) => HostDeployment(
    status: HostDeploymentStatus.cannotStart,
    observedAt: _now(),
    reason: why,
  );

  void _set(
    HostSupervisionPhase phase, {
    HostDeployment? reading,
    String? reason,
    DateTime? nextAttemptAt,
    List<String> output = const [],
  }) {
    if (_disposed) return;
    _state = HostSupervision(
      phase: phase,
      observedAt: _now(),
      reading: reading ?? _state.reading,
      reason: reason,
      attempt: _attempts,
      maxAttempts: backoff.length,
      nextAttemptAt: nextAttemptAt,
      lastOutput: output,
    );
    _changes.add(_state);
  }

  Future<void> dispose() async {
    _disposed = true;
    _next?.cancel();
    _stable?.cancel();
    await _exits.cancel();
    await _changes.close();
    await _restarted.close();
  }
}
