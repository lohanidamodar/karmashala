import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import '../../../core/logging/app_logger.dart';
import '../../../core/util/clock.dart';
import '../../agents/data/agent_state_file_status_source.dart';
import '../../agents/data/agent_status_service.dart';
import '../../agents/domain/agent_registry.dart';
import '../../agents/domain/agent_status.dart';
import '../domain/agent_session_key.dart';
import '../domain/watched_session.dart';

/// How often the registry recomputes every known session's status.
///
/// Inherited from the per-card poller this replaces, so a badge is no less
/// responsive than it was — the difference is that there is now one of these
/// for the whole app instead of one per rendered row.
const Duration kStatusCycleInterval = Duration(milliseconds: 1200);

/// How many sessions may be given a *fallback probe* — the disk half of a
/// status — in one cycle.
///
/// The only budget that matters. Hooks and terminal grids are already in
/// memory, so every session gets those every cycle whatever the workspace's
/// size; a transcript read is the one cost that grows with the session count,
/// so it is the one thing rationed. At the default cycle that is ~20 probes a
/// second, and a probe whose file has not changed is a `stat` and nothing else.
const int kStatusProbeBudget = 24;

/// How many probes may be in flight at once.
///
/// Bounded rather than serial: Loop 87's audit found the old watcher awaiting
/// each transcript in a `for` loop, so one slow file pushed the whole pass past
/// its own interval and the first session in the list always won. Bounded
/// rather than unbounded: a `Future.wait` over everything is how you turn a
/// slow disk into a thousand open handles.
const int kStatusProbeConcurrency = 4;

/// How long between full CLI-store scans looking for transcripts we do not have
/// a path for yet.
///
/// One scan for the whole app, not one per session per tick. The thing being
/// waited for — the agent writing its first turn — happens once, seconds to
/// minutes after launch, and never again.
const Duration kTranscriptSearchInterval = Duration(seconds: 10);

/// How recently a session's status must have changed for it to count as
/// "recently active" when the probe budget is being shared out.
const Duration kStatusRecentlyActiveWindow = Duration(seconds: 60);

/// The most often a hook naming a session we do not track may force a full
/// cycle.
///
/// A hook for a session already tracked is answered in place, in O(1), with no
/// rationing at all — that is the whole point of the event path. The one case
/// that needs the loader is a session the workspace has not enumerated yet
/// (adoption, or a CLI that has just announced its own id), and that is a
/// once-per-session event. The floor is here so a hook naming a session that
/// *never* becomes tracked cannot turn the cheap path into a polling loop.
const Duration kHookCycleFloor = Duration(seconds: 1);

/// How long the fallback rotation may take to come back round to a session
/// before the registry says so in the log.
///
/// It limits nothing — crossing it drops no session and changes no behaviour.
/// It is the point at which the *fallback* has stopped being a fallback: a
/// transcript reading two minutes old is not something anyone should be reading
/// a badge from, and a workspace large enough to cause that should be visible
/// as a line in the log rather than felt as badges that are quietly wrong.
///
/// Hook-backed sessions never wait for the rotation, so crossing this says
/// precisely "the unhooked half of this workspace has outgrown the budget" —
/// which is the thing the 60-session cap did, and did in silence. At the
/// default budget it stays quiet through the audit's whole 500-session tier and
/// speaks up somewhere past eight hundred sessions with no hooks installed.
const Duration kProbeRotationCeiling = Duration(minutes: 2);

/// One session's current status, as the registry holds it.
class SessionStatusEntry {
  const SessionStatusEntry({
    required this.session,
    required this.report,
    required this.sampledAt,
    required this.lastProbedAt,
    required this.probeFailed,
  });

  final WatchedSession session;
  final AgentStatusReport report;

  /// When this status was last *computed*. Every cycle, for every session.
  final DateTime sampledAt;

  /// When this session's transcript was last read, or `null` for one that has
  /// never needed a disk read (a hook answered) or has not had its turn yet.
  ///
  /// The distinction that makes "not sampled this cycle" different from "no
  /// longer watched": an entry with an old [lastProbedAt] still has a status,
  /// and a session that leaves the registry has no entry at all.
  final DateTime? lastProbedAt;

  /// Whether the last probe could not read the file. Buys priority next cycle.
  final bool probeFailed;

  AgentSessionKey get key => session.key;
}

/// How much of the watch set one cycle actually reached.
///
/// The registry guarantees coverage by construction — membership is uncapped,
/// and the probe rotation reserves a share that priority traffic cannot take.
/// But the 60-session cap reached production and survived there because
/// **nobody could tell**, and a guarantee no one can observe fails the same way
/// the next time somebody adds a limit for a good reason. This is the
/// observation: what is watched, what the primary path answered for free, and
/// how far behind the rationed half is.
class SessionStatusCoverage {
  const SessionStatusCoverage({
    required this.tracked,
    required this.hookAnswered,
    required this.probeCandidates,
    required this.probed,
    required this.neverProbed,
    required this.probeFailures,
    required this.rotationPeriod,
  });

  /// Every session the registry holds a status for — the number that used to be
  /// silently sixty.
  final int tracked;

  /// How many a hook answered, which is the primary path's real share of this
  /// workspace and the part that owes the rotation nothing.
  final int hookAnswered;

  /// How many still need the disk before they can say anything.
  final int probeCandidates;

  /// How many candidates this cycle read.
  final int probed;

  /// Candidates whose transcript has never been read. Queued, not lost: they
  /// have an entry, a status and a place in the rotation. Still above zero
  /// after a full [rotationPeriod] means something is stuck rather than merely
  /// waiting its turn.
  final int neverProbed;

  /// Candidates whose last read failed. These buy priority next cycle, so a
  /// number that stays high is a permission or a path problem, not a queue.
  final int probeFailures;

  /// The guaranteed worst case for coming back round to any one candidate, or
  /// `null` when the budget is too small to rotate at all.
  ///
  /// Computed from the *reserved* share rather than the whole budget, because
  /// that is the part no amount of priority traffic can take — so it is a
  /// promise that holds however busy the workspace is, not a best case.
  final Duration? rotationPeriod;

  /// Whether the fallback has stopped being one. See [kProbeRotationCeiling].
  bool get isBehind {
    final period = rotationPeriod;
    return period == null || period > kProbeRotationCeiling;
  }

  @override
  bool operator ==(Object other) =>
      other is SessionStatusCoverage &&
      other.tracked == tracked &&
      other.hookAnswered == hookAnswered &&
      other.probeCandidates == probeCandidates &&
      other.probed == probed &&
      other.neverProbed == neverProbed &&
      other.probeFailures == probeFailures &&
      other.rotationPeriod == rotationPeriod;

  @override
  int get hashCode => Object.hash(
    tracked,
    hookAnswered,
    probeCandidates,
    probed,
    neverProbed,
    probeFailures,
    rotationPeriod,
  );

  /// The one-line form the log uses, so a bug report carries the same words a
  /// test asserts.
  @override
  String toString() {
    final period = rotationPeriod;
    return '$tracked watched · $hookAnswered by hook · $probed of '
        '$probeCandidates probed · $neverProbed never · $probeFailures failed '
        '· rotation ${period == null ? 'never' : '${period.inSeconds}s'}';
  }
}

/// What one cycle did, for the watcher that consumes it and for diagnostics.
class SessionStatusCycle {
  const SessionStatusCycle({
    required this.entries,
    required this.probed,
    required this.scans,
    this.coverage = const SessionStatusCoverage(
      tracked: 0,
      hookAnswered: 0,
      probeCandidates: 0,
      probed: 0,
      neverProbed: 0,
      probeFailures: 0,
      rotationPeriod: null,
    ),
  });

  /// How much of the watch set this cycle reached.
  final SessionStatusCoverage coverage;

  /// Every watched session, in the order the loader offered them.
  final List<SessionStatusEntry> entries;

  /// How many sessions were given a fallback probe.
  final int probed;

  /// How many full CLI-store scans this cycle ran (0 or 1).
  final int scans;
}

/// The one place a session's status lives.
///
/// Before Loop 87 there were three status pipelines: a per-card 1.2-second
/// `StreamProvider` loop (one *per rendered row*, each capable of starting its
/// own full CLI-store scan), an always-on 5-second notification watcher, and
/// the checkpoint recorder riding on the first. Rendering a row created work;
/// scrolling the Explorer changed how much polling the app did; and the watcher
/// truncated its own watch set at 60 sessions, so session 61 was never observed
/// at all.
///
/// This owns all of it for every known session:
///
/// * **hook reports** and **terminal grids** — already in memory, so they are
///   read for *every* session on *every* cycle. Nothing is capped by list
///   position, because nothing about these costs anything to include. A hook
///   does not even wait for a cycle: [hookReported] folds it in as it lands and
///   publishes it on [hookChanges], which is what makes hooks the primary path
///   and the cycle below the fallback.
/// * **transcript paths** — resolved once, centrally, by one store scan shared
///   by every session that still needs one.
/// * **fallback probes** — the disk half, and the only rationed part: a fair
///   rotation with a per-cycle budget, so the cost is O(budget) rather than
///   O(sessions).
/// * **last known state** — kept for a session the rotation did not reach, so a
///   session returning to the sampled set is not mistaken for a first
///   observation and its transition is not suppressed.
///
/// Deliberately not a `Notifier` and free of Flutter: everything it needs from
/// the app arrives as a function, so the whole loop can be driven at 500
/// sessions in a plain test.
class SessionStatusRegistry {
  SessionStatusRegistry({
    required this.statusService,
    required this.agents,
    required this.loadSessions,
    required this.clock,
    this.readTail,
    this.resolveTranscripts,
    this.visibleSessionIds,
    this.onCycle,
    this.stateFileSource = const AgentStateFileStatusSource(),
    this.probeBudget = kStatusProbeBudget,
    this.probeConcurrency = kStatusProbeConcurrency,
    this.interval = kStatusCycleInterval,
    this.transcriptSearchInterval = kTranscriptSearchInterval,
    this.recentlyActiveWindow = kStatusRecentlyActiveWindow,
    this.hookCycleFloor = kHookCycleFloor,
  });

  final AgentStatusService statusService;
  final AgentRegistry agents;

  /// Every session worth holding a status for. Uncapped on purpose — see the
  /// class comment; the budget lives on probes, not on membership.
  final List<WatchedSession> Function() loadSessions;

  final Clock clock;

  /// The bottom rows of the pane a session runs in, when it runs in one.
  final List<String> Function(WatchedSession session)? readTail;

  /// One scan of every CLI store, as `'<agentId>/<sessionId>' → file path`.
  final Future<Map<String, String>> Function()? resolveTranscripts;

  /// The CLI session ids and workspace row ids currently on screen.
  final Set<String> Function()? visibleSessionIds;

  /// Work that wants this registry's cycle rather than a ticker of its own.
  ///
  /// Called once per cycle, after the statuses are published, with
  /// `mayScanStores` true at most once per [transcriptSearchInterval] — the
  /// same rationing the transcript search gets, because it is the same cost:
  /// one pass over every CLI store on disk.
  ///
  /// Session adoption is the caller (`SessionAdoptionService`). It rides here
  /// so that noticing a pane has become an agent session cannot become a second
  /// polling loop beside the one this class exists to have removed.
  final Future<void> Function(bool mayScanStores)? onCycle;

  final AgentStateFileStatusSource stateFileSource;
  final int probeBudget;
  final int probeConcurrency;

  /// How often [start] cycles. Faster than the notification pass on purpose:
  /// a status badge is what the user is looking at, and a toast is not.
  final Duration interval;

  final Duration transcriptSearchInterval;
  final Duration recentlyActiveWindow;

  /// See [kHookCycleFloor].
  final Duration hookCycleFloor;

  final Map<AgentSessionKey, _Tracked> _tracked = {};
  final Map<String, _Tracked> _byOpenId = {};
  final StreamController<void> _changes = StreamController<void>.broadcast();
  final StreamController<SessionStatusEntry> _hookChanges =
      StreamController<SessionStatusEntry>.broadcast();

  DateTime? _nextTranscriptSearch;
  DateTime? _nextStoreSlot;
  DateTime? _nextHookCycle;
  Timer? _timer;
  bool _disposed = false;
  Future<SessionStatusCycle>? _inFlight;
  SessionStatusCycle _last = const SessionStatusCycle(
    entries: [],
    probed: 0,
    scans: 0,
  );

  /// Cycles run. Diagnostics, and the number the fairness tests count.
  int cycles = 0;

  /// Fallback probes attempted (a `stat`, and a tail read only if it moved).
  int probes = 0;

  /// Tail reads actually performed — probes whose file had changed.
  int tailReads = 0;

  /// Full CLI-store scans run to resolve transcript paths.
  int transcriptScans = 0;

  /// Cycles on which [onCycle] was allowed to touch the CLI stores. The number
  /// the adoption cost claim is asserted against.
  int storeSlots = 0;

  /// How much of the watch set the last cycle reached, or `null` before the
  /// first one. See [SessionStatusCoverage].
  SessionStatusCoverage? coverage;

  final AppLogger _log = AppLogger.named('notifications.status');

  /// Hook callbacks handed to [hookReported].
  int hookReports = 0;

  /// Hook callbacks that changed a status without waiting for a cycle.
  int hookFastUpdates = 0;

  /// Cycles a hook for an untracked session forced, rationed by
  /// [hookCycleFloor].
  int hookCycles = 0;

  /// The most recent *cycle's* entries.
  ///
  /// A snapshot of that pass, so a status a hook changed since is visible
  /// through [reportForKey] and [hookChanges] rather than here.
  List<SessionStatusEntry> get entries => _last.entries;

  int get trackedCount => _tracked.length;

  /// The status held for one agent session, or `null` if it is not watched.
  AgentStatusReport? reportForKey(AgentSessionKey key) => _tracked[key]?.report;

  /// The status held for a workspace row (native session or imported session
  /// id) — the key the UI has.
  AgentStatusReport? reportForOpenId(String openId) =>
      _byOpenId[openId]?.report;

  /// The status of one workspace row, and every later change to it.
  ///
  /// Starts nothing: no timer, no scan, no disk read. A hundred badges are a
  /// hundred subscriptions to one broadcast stream that the app's single status
  /// cycle already feeds.
  ///
  /// Always yields immediately — [fallback] when the registry has never seen
  /// the session — so a consumer awaiting the first value cannot hang on a row
  /// the loader does not (yet) consider watchable.
  Stream<AgentStatusReport> reportsFor(
    String openId, {
    AgentStatusReport? fallback,
  }) {
    AgentStatusReport current() =>
        reportForOpenId(openId) ??
        fallback ??
        AgentStatusReport(
          agentId: '',
          sessionId: openId,
          status: AgentActivityStatus.unknown,
          source: AgentStatusSource.none,
          observedAt: clock.nowUtc(),
        );

    // A `Stream.multi` rather than an `async*` generator, because a generator
    // suspended in `await for` only notices a cancellation at its next yield —
    // and this one can legitimately sit silent for hours. A hundred badges
    // being torn down must not each wait for a status to change first.
    return Stream<AgentStatusReport>.multi((controller) {
      var last = current();
      controller.add(last);
      final subscription = _changes.stream.listen(
        (_) {
          final next = current();
          // Only when the *evidence* moved. A cycle that reconfirms a status is
          // not a rebuild: at a hundred rows that is the difference between a
          // silent app and eighty widget rebuilds a second.
          if (_sameEvidence(last, next)) return;
          last = next;
          controller.add(next);
        },
        onDone: controller.close,
      );
      controller.onCancel = subscription.cancel;
    });
  }

  /// Sessions a hook just changed the status of, as the callback lands.
  ///
  /// The event path. `AgentStatusWatcher` listens here so an approval request
  /// reaches the tray, the inbox and the toast pipeline immediately instead of
  /// at its next pass, which demotes polling to what it should always have
  /// been: the fallback for agents whose hooks are not installed.
  Stream<SessionStatusEntry> get hookChanges => _hookChanges.stream;

  /// A hook callback just landed for [key]. Fold it in now.
  ///
  /// This is the cheap half of a cycle, for one session, run out of turn. A
  /// hook outranks every other source (`AgentStatusService`'s precedence), so
  /// answering it needs no disk, no store scan and not even the session's
  /// terminal — a map lookup and the precedence, and nothing else.
  ///
  /// Publishes only when the evidence actually moved, so a chatty agent's
  /// stream of tool-use callbacks costs a lookup each and wakes nobody.
  ///
  /// A [key] the registry does not track yet is the one case that needs the
  /// loader: it asks for a cycle instead, rationed by [hookCycleFloor]. The
  /// latency that costs is only ever a session's *first* hook, which the
  /// notification policy suppresses as a first observation anyway.
  void hookReported(AgentSessionKey key) {
    if (_disposed) return;
    hookReports++;
    final tracked = _tracked[key];
    if (tracked == null || agents.byId(key.agentId) == null) {
      _requestEarlyCycle();
      return;
    }
    final now = clock.nowUtc();
    final query =
        tracked.query ??
        AgentStatusQuery(
          agentId: key.agentId,
          sessionId: key.sessionId,
          stateFilePath: tracked.statePath,
        );
    final hook = statusService.hookReport(query, now);
    // Recorded but already stale, or an event that means nothing to us. The
    // next cycle re-ranks it against the sources that are still worth reading.
    if (hook == null) return;
    final before = tracked.report;
    tracked.query = query;
    tracked.hook = hook;
    tracked.grid = null;
    tracked.wantsProbe = false;
    tracked.publish(
      statusService.compose(query: query, now: now, hook: hook),
      now,
    );
    if (_sameEvidence(before, tracked.report)) return;
    hookFastUpdates++;
    if (!_changes.isClosed) _changes.add(null);
    if (!_hookChanges.isClosed) _hookChanges.add(tracked.entry());
  }

  void _requestEarlyCycle() {
    final now = clock.nowUtc();
    final next = _nextHookCycle;
    if (next != null && now.isBefore(next)) return;
    _nextHookCycle = now.add(hookCycleFloor);
    hookCycles++;
    // Fire and forget, and quietly: this runs inside an agent's hook callback,
    // and a cycle that cannot enumerate sessions must not come back as an
    // unhandled error in the HTTP handler that fired it. The periodic cycle
    // meets the same failure with somewhere to report it.
    unawaited(cycle().catchError((Object _) => _last));
  }

  /// Recomputes every watched session's status, spends this cycle's probe
  /// budget, and publishes.
  ///
  /// Re-entrant callers join the pass already running rather than starting a
  /// second one against a half-updated snapshot.
  Future<SessionStatusCycle> cycle() {
    final running = _inFlight;
    if (running != null) return running;
    final started = _cycle();
    _inFlight = started;
    return started.whenComplete(() => _inFlight = null);
  }

  Future<SessionStatusCycle> _cycle() async {
    cycles++;
    final now = clock.nowUtc();
    final sessions = loadSessions();

    // 1. Every session, from the sources that are already in memory. No cap:
    //    a hook report is a map lookup and a grid read is a live buffer.
    final seen = <AgentSessionKey>{};
    for (final session in sessions) {
      seen.add(session.key);
      final tracked = _tracked.putIfAbsent(
        session.key,
        () => _Tracked(session, now),
      );
      tracked.session = session;
      tracked.statePath = session.stateFilePath ?? tracked.statePath;
      _observe(tracked, now);
    }
    // Only membership prunes. A session the rotation skipped keeps everything.
    _tracked.removeWhere((key, _) => !seen.contains(key));
    _byOpenId
      ..clear()
      ..addEntries(
        _tracked.values.map((t) => MapEntry(t.session.openId, t)),
      );

    // 2. One store scan for everyone still missing a transcript path.
    final scans = await _resolvePaths(now);
    // A shutdown can land inside that scan; nothing below may touch the app.
    if (_disposed) return _last;

    // 3. The rationed half.
    final candidates = [
      for (final tracked in _tracked.values)
        if (tracked.wantsProbe && tracked.statePath != null) tracked,
    ];
    final picks = _select(candidates, now);
    await _probeAll(picks, now);
    for (final tracked in picks) {
      _recompose(tracked, now);
    }

    _last = SessionStatusCycle(
      entries: [
        for (final session in sessions)
          if (_tracked[session.key] case final tracked?) tracked.entry(),
      ],
      probed: picks.length,
      scans: scans,
      coverage: _measure(picks.length),
    );
    if (!_changes.isClosed) _changes.add(null);
    await _runCycleWork(now);
    return _last;
  }

  /// Counts what this cycle reached and says so when the answer changed shape.
  ///
  /// Everything here is edge-triggered. This runs every 1.2 seconds, so a line
  /// per cycle would bury the log it exists to make readable; what is worth a
  /// line is the watch set changing size and the rotation crossing
  /// [kProbeRotationCeiling] in either direction — a log that once warned must
  /// not read as though it still is.
  SessionStatusCoverage _measure(int probed) {
    var hookAnswered = 0;
    var candidates = 0;
    var neverProbed = 0;
    var failures = 0;
    for (final tracked in _tracked.values) {
      if (tracked.report.source == AgentStatusSource.hook) hookAnswered++;
      if (!tracked.wantsProbe || tracked.statePath == null) continue;
      candidates++;
      if (tracked.lastProbedAt == null) neverProbed++;
      if (tracked.probeFailed) failures++;
    }
    final next = SessionStatusCoverage(
      tracked: _tracked.length,
      hookAnswered: hookAnswered,
      probeCandidates: candidates,
      probed: probed,
      neverProbed: neverProbed,
      probeFailures: failures,
      rotationPeriod: _rotationPeriod(candidates),
    );

    final previous = coverage;
    coverage = next;
    if (previous == null || previous.tracked != next.tracked) {
      _log.info('watching ${next.tracked} sessions — $next');
    }
    if (next.isBehind != (previous?.isBehind ?? false)) {
      if (next.isBehind) {
        _log.warning(
          'the status fallback is behind: ${next.probeCandidates} sessions '
          'need a transcript read and the rotation takes '
          '${next.rotationPeriod?.inSeconds ?? -1}s to come back round. '
          'Statuses for unhooked sessions will be stale. — $next',
        );
      } else {
        _log.info('the status fallback is keeping up again — $next');
      }
    }
    return next;
  }

  /// The guaranteed worst case for coming back round to one of [candidates].
  ///
  /// Measured against the reserved share, not the whole budget: the reserve is
  /// the part priority traffic can never take, so this is a bound that holds
  /// however busy the workspace is. `null` when the budget is too small to
  /// reserve anything, which is a registry that cannot promise to rotate at
  /// all.
  Duration? _rotationPeriod(int candidates) {
    if (candidates <= probeBudget) return interval;
    final reserve = probeBudget >= 2 ? math.max(1, probeBudget ~/ 3) : 0;
    if (reserve <= 0) return null;
    return interval * ((candidates + reserve - 1) ~/ reserve);
  }

  /// Runs [onCycle], deciding whether this is the cycle that may pay for a
  /// store scan.
  ///
  /// Wrapped, because the work here is a *passenger* on a status cycle: a
  /// caller that throws must not stop badges updating.
  Future<void> _runCycleWork(DateTime now) async {
    final work = onCycle;
    if (work == null || _disposed) return;
    final next = _nextStoreSlot;
    final mayScanStores = next == null || !now.isBefore(next);
    if (mayScanStores) {
      _nextStoreSlot = now.add(transcriptSearchInterval);
      storeSlots++;
    }
    try {
      await work(mayScanStores);
    } on Object {
      // Deliberately swallowed; see above.
    }
  }

  /// Begins cycling. One timer for the whole app — the point of the exercise.
  ///
  /// Started by `AgentStatusWatcher`, which is started by the app's system
  /// integration. A rendered badge never calls this: subscribing to a status
  /// must not be what makes the app do work.
  void start() {
    if (_timer != null) return;
    _timer = Timer.periodic(interval, (_) => unawaited(cycle()));
    unawaited(cycle());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void dispose() {
    _disposed = true;
    stop();
    _tracked.clear();
    _byOpenId.clear();
    unawaited(_changes.close());
    unawaited(_hookChanges.close());
  }

  /// Forgets resolved transcript paths, so the next cycle looks again.
  ///
  /// For a caller that knows the stores changed underneath us — a re-import, a
  /// new execution environment. Nothing polls for this.
  void invalidateTranscriptPaths() {
    _nextTranscriptSearch = null;
    for (final tracked in _tracked.values) {
      if (tracked.session.stateFilePath == null) tracked.statePath = null;
    }
  }

  /// Recomputes one session from the sources already in memory, and records
  /// whether its transcript still has to be consulted.
  void _observe(_Tracked tracked, DateTime now) {
    final query = AgentStatusQuery(
      agentId: tracked.session.key.agentId,
      sessionId: tracked.session.key.sessionId,
      stateFilePath: tracked.statePath,
      terminalTailLines: readTail?.call(tracked.session) ?? const [],
    );
    tracked.query = query;
    final descriptor = agents.byId(query.agentId);
    if (descriptor == null) {
      tracked.hook = null;
      tracked.grid = null;
      tracked.wantsProbe = false;
      tracked.publish(statusService.unknownFor(query, now), now);
      return;
    }
    final hook = statusService.hookReport(query, now);
    final grid = hook == null ? statusService.gridReport(query, now) : null;
    tracked.hook = hook;
    tracked.grid = grid;
    tracked.wantsProbe =
        statusService.needsStateFile(hook, grid) &&
        descriptor.stateFile != null;
    _recompose(tracked, now);
  }

  /// Re-ranks one session's sources without touching disk or the terminal.
  void _recompose(_Tracked tracked, DateTime now) {
    final query = tracked.query;
    if (query == null) return;
    final descriptor = agents.byId(query.agentId);
    final snapshot = tracked.snapshot;
    final state = (descriptor == null || snapshot == null)
        ? null
        : stateFileSource.classify(
            descriptor,
            snapshot,
            now,
            sessionId: query.sessionId,
          );
    tracked.publish(
      statusService.compose(
        query: query,
        now: now,
        hook: tracked.hook,
        grid: tracked.grid,
        state: state,
      ),
      now,
    );
  }

  /// Resolves transcript paths for everything still missing one, with a single
  /// scan shared by all of them. Returns how many scans ran (0 or 1).
  Future<int> _resolvePaths(DateTime now) async {
    final resolve = resolveTranscripts;
    if (resolve == null || _disposed) return 0;
    final pending = [
      for (final tracked in _tracked.values)
        if (tracked.wantsProbe &&
            tracked.statePath == null &&
            tracked.isNamedByItsCli)
          tracked,
    ];
    if (pending.isEmpty) return 0;
    final next = _nextTranscriptSearch;
    if (next != null && now.isBefore(next)) return 0;
    _nextTranscriptSearch = now.add(transcriptSearchInterval);
    transcriptScans++;
    final Map<String, String> index;
    try {
      index = await resolve();
    } on Object {
      // A store we cannot read is the same answer as one with nothing in it.
      return 1;
    }
    if (_disposed) return 1;
    for (final tracked in pending) {
      final path = index[tracked.session.key.toString()];
      if (path == null) continue;
      tracked.statePath = path;
      // The path is new evidence: re-rank now, so a session that gained one
      // this cycle is eligible for this cycle's probes rather than the next.
      _observe(tracked, now);
    }
    return 1;
  }

  /// Chooses this cycle's probes: priority first, then a fair rotation, with a
  /// reserved share the priority tier can never take.
  ///
  /// The reservation is the whole fairness argument. Priority alone starves —
  /// thirty visible sessions and a budget of twenty-four means session
  /// thirty-one is never read, which is the 60-cap bug wearing a different hat.
  /// With a third of the budget reserved for "whoever was probed longest ago",
  /// every eligible session is reached within `ceil(M / reserve)` cycles no
  /// matter how much priority traffic there is.
  List<_Tracked> _select(List<_Tracked> candidates, DateTime now) {
    if (candidates.length <= probeBudget) return candidates;

    final visible = visibleSessionIds?.call() ?? const <String>{};
    final priority = <_Tracked>[];
    final rest = <_Tracked>[];
    for (final tracked in candidates) {
      if (_isPriority(tracked, visible, now)) {
        priority.add(tracked);
      } else {
        rest.add(tracked);
      }
    }

    final reserve = probeBudget >= 2 ? math.max(1, probeBudget ~/ 3) : 0;
    final priorityCap = probeBudget - reserve;
    priority.sort(_byOldestProbe);
    rest.sort(_byOldestProbe);

    final picks = <_Tracked>[];
    for (final tracked in priority.take(priorityCap)) {
      picks.add(tracked);
    }
    for (final tracked in rest) {
      if (picks.length >= probeBudget) break;
      picks.add(tracked);
    }
    for (final tracked in priority.skip(priorityCap)) {
      if (picks.length >= probeBudget) break;
      picks.add(tracked);
    }
    return picks;
  }

  bool _isPriority(_Tracked tracked, Set<String> visible, DateTime now) =>
      visible.contains(tracked.session.key.sessionId) ||
      visible.contains(tracked.session.openId) ||
      tracked.report.status == AgentActivityStatus.awaitingApproval ||
      tracked.report.status == AgentActivityStatus.failed ||
      tracked.probeFailed ||
      now.difference(tracked.changedAt) <= recentlyActiveWindow;

  static int _byOldestProbe(_Tracked a, _Tracked b) {
    final left = a.lastProbedAt;
    final right = b.lastProbedAt;
    if (left == null && right == null) return a.sortKey.compareTo(b.sortKey);
    if (left == null) return -1;
    if (right == null) return 1;
    final byTime = left.compareTo(right);
    return byTime != 0 ? byTime : a.sortKey.compareTo(b.sortKey);
  }

  Future<void> _probeAll(List<_Tracked> picks, DateTime now) async {
    if (picks.isEmpty) return;
    final queue = Queue<_Tracked>.of(picks);
    final workers = math.min(math.max(probeConcurrency, 1), picks.length);
    await Future.wait([
      for (var i = 0; i < workers; i++) _drain(queue, now),
    ]);
  }

  Future<void> _drain(Queue<_Tracked> queue, DateTime now) async {
    while (queue.isNotEmpty) {
      await _probe(queue.removeFirst(), now);
    }
  }

  Future<void> _probe(_Tracked tracked, DateTime now) async {
    final path = tracked.statePath;
    if (path == null) return;
    tracked.lastProbedAt = now;
    probes++;
    final known = tracked.snapshot;
    final snapshot = await stateFileSource.probe(path, known: known);
    if (snapshot == null) {
      // A file that has gone or cannot be read. Keep the last snapshot: losing
      // sight of a session is not evidence that anything about it changed.
      tracked.probeFailed = true;
      return;
    }
    tracked.probeFailed = false;
    if (!identical(snapshot, known)) tailReads++;
    tracked.snapshot = snapshot;
  }
}

/// Whether two reports say the same thing about the same evidence.
///
/// `observedAt` is deliberately excluded: it moves every cycle and means only
/// "we looked again", which is not news to anybody.
bool _sameEvidence(AgentStatusReport a, AgentStatusReport b) =>
    a.status == b.status &&
    a.source == b.source &&
    a.detail == b.detail &&
    a.sourceModifiedAt == b.sourceModifiedAt &&
    a.agentId == b.agentId &&
    a.sessionId == b.sessionId &&
    _sameLines(a.evidence, b.evidence);

bool _sameLines(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Everything the registry keeps about one session between cycles.
class _Tracked {
  _Tracked(this.session, DateTime now)
    : report = AgentStatusReport(
        agentId: session.key.agentId,
        sessionId: session.key.sessionId,
        status: AgentActivityStatus.unknown,
        source: AgentStatusSource.none,
        observedAt: now,
      ),
      sampledAt = now,
      changedAt = now,
      statePath = session.stateFilePath;

  WatchedSession session;
  AgentStatusReport report;
  DateTime sampledAt;

  /// When the status last actually changed — the input to "recently active".
  DateTime changedAt;

  String? statePath;
  StateFileSnapshot? snapshot;
  DateTime? lastProbedAt;
  bool probeFailed = false;
  bool wantsProbe = false;

  /// This cycle's already-gathered cheap evidence, so a post-probe recompose
  /// does not re-read the terminal.
  AgentStatusQuery? query;
  AgentStatusReport? hook;
  AgentStatusReport? grid;

  String get sortKey => session.key.toString();

  /// Whether the CLI has announced this session's own id. A native session the
  /// agent has not named yet is keyed by its workspace row id, which no
  /// transcript will ever match — so it must not keep asking for store scans.
  bool get isNamedByItsCli =>
      session.imported || session.key.sessionId != session.openId;

  void publish(AgentStatusReport next, DateTime now) {
    if (!_sameEvidence(report, next)) changedAt = now;
    report = next;
    sampledAt = now;
  }

  SessionStatusEntry entry() => SessionStatusEntry(
    session: session,
    report: report,
    sampledAt: sampledAt,
    lastProbedAt: lastProbedAt,
    probeFailed: probeFailed,
  );
}
