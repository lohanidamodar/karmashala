import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart' show BackgroundRun, waitsOnBackground;
import 'package:karmashala_agent_reporting/status.dart';
import 'package:karmashala_agent_status/karmashala_agent_status.dart';
import 'package:karmashala_core/util.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show SessionStatusEntry, WatchCoverage;
import 'package:karmashala_notifications/watched.dart';

/// How often the server recomputes every watched session's status: the pace
/// the app's registry kept, since a badge is what somebody is looking at.
const Duration kStatusCycleInterval = Duration(milliseconds: 1200);

/// How many sessions get a *fallback probe* — a transcript read — per cycle.
/// The only cost that grows with the session count, so the only one rationed.
const int kStatusProbeBudget = 24;

/// How many probes may be in flight at once.
const int kStatusProbeConcurrency = 4;

/// How long between store walks looking for transcripts not yet located.
const Duration kTranscriptSearchInterval = Duration(seconds: 10);

/// How recently a status must have changed to count as "recently active"
/// when the probe budget is shared out.
const Duration kStatusRecentlyActiveWindow = Duration(seconds: 60);

/// The most often a hook naming an unwatched session may force a cycle, so a
/// hook for a session that never becomes watched cannot become a poll.
const Duration kHookCycleFloor = Duration(seconds: 1);

/// **Every watched session's status, kept by the server** (slice 5c) — the
/// app's `SessionStatusRegistry`, moved. For a session the server runs
/// ([heldByHost]) it is the server's own reading ([hostStatusFor]: the hooks
/// it takes and the screen it holds, `DaemonAgentStatus`); for every other
/// session (imported history, an agent in a terminal no server runs) hooks
/// every cycle and transcript probes rationed behind them. No screen of those
/// is read: the server has none.
///
/// What moves is told on [statusChanges] (every move, synchronous) and
/// [hookChanges] (a move an event caused, out of turn), and the cycle's reach
/// on [coverage].
class ServerSessionStatus {
  ServerSessionStatus({
    required this.statusService,
    required this.agents,
    required this.loadSessions,
    required this.clock,
    this.resolveTranscripts,
    this.visibleSessionIds,
    this.heldByHost,
    this.hostStatusFor,
    this.log,
    this.toolAsks,
    this.backgroundRunsOf,
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

  /// Every session worth holding a status for. Uncapped: the budget is on
  /// probes.
  final List<WatchedSession> Function() loadSessions;

  final Clock clock;

  /// One walk of every agent store: `'<agentId>/<conversationId>' → path`.
  final Future<Map<String, String>> Function()? resolveTranscripts;

  /// The conversation and row ids some window is looking at — they buy probe
  /// priority.
  final Set<String> Function()? visibleSessionIds;

  /// Whether the server runs [WatchedSession]'s agent itself. Its status is
  /// then the server's own reading, never computed here.
  final bool Function(WatchedSession session)? heldByHost;

  /// What the server's own reading says the agent in a session it runs is
  /// doing, or null while it has said nothing (read as `unknown`).
  final HostedAgentStatus? Function(WatchedSession session)? hostStatusFor;

  /// Edges only — a line a cycle would repeat every 1.2 s is never written.
  final void Function(String message)? log;

  /// The tool call each conversation last announced, fed by whoever takes the
  /// hooks: what an open prompt asks about, carried on its status for the ask
  /// dock. Null carries none.
  final ToolAskTracker? toolAsks;

  /// Every background run a live session's transcript records, read when
  /// its agent goes idle: an idle with one still running reads `working`.
  /// Set late, once the transcripts are; null reads none.
  Future<List<BackgroundRun>> Function(WatchedSession session)?
  backgroundRunsOf;

  final AgentStateFileStatusSource stateFileSource;
  final int probeBudget;
  final int probeConcurrency;
  final Duration interval;
  final Duration transcriptSearchInterval;
  final Duration recentlyActiveWindow;
  final Duration hookCycleFloor;

  final Map<AgentSessionKey, _Tracked> _tracked = {};
  final Map<String, _Tracked> _byOpenId = {};
  final StreamController<SessionStatusEntry> _hookChanges =
      StreamController<SessionStatusEntry>.broadcast(sync: true);
  final StreamController<SessionStatusEntry> _statusChanges =
      StreamController<SessionStatusEntry>.broadcast(sync: true);
  final StreamController<String> _removed = StreamController<String>.broadcast(
    sync: true,
  );
  final StreamController<WatchCoverage> _coverageChanges =
      StreamController<WatchCoverage>.broadcast(sync: true);

  DateTime? _nextTranscriptSearch;
  DateTime? _nextHookCycle;
  Timer? _timer;
  bool _disposed = false;
  Future<List<SessionStatusEntry>>? _inFlight;
  List<SessionStatusEntry> _last = const [];

  /// Cycles run.
  int cycles = 0;

  /// Fallback probes attempted.
  int probes = 0;

  /// Tail reads actually performed — probes whose file had changed.
  int tailReads = 0;

  /// Store walks run to resolve transcript paths.
  int transcriptScans = 0;

  /// Hooks handed to [hookReported].
  int hookReports = 0;

  /// How much of the watch set the last cycle reached, or null before the
  /// first one.
  WatchCoverage? coverage;

  /// The last cycle's entries, in the loader's order.
  List<SessionStatusEntry> get entries => _last;

  /// Every session held now, with its current status — what a subscriber is
  /// greeted with.
  List<SessionStatusEntry> get current => [
    for (final tracked in _tracked.values) tracked.entry(),
  ];

  int get trackedCount => _tracked.length;

  /// The status held for a workspace row (native row or imported id).
  AgentStatusReport? reportForOpenId(String openId) =>
      _byOpenId[openId]?.report;

  AgentStatusReport? reportForKey(AgentSessionKey key) => _tracked[key]?.report;

  /// The transcript read for [openId], when one was located.
  String? transcriptPathForOpenId(String openId) =>
      _byOpenId[openId]?.statePath;

  /// A move an event caused — a hook, the server's own reading — out of turn.
  Stream<SessionStatusEntry> get hookChanges => _hookChanges.stream;

  /// Every session whose status evidence moved, one entry per move, from any
  /// source. Synchronous, so two moves in one turn stay two.
  Stream<SessionStatusEntry> get statusChanges => _statusChanges.stream;

  /// A session that left the watch set, by its row.
  Stream<String> get removals => _removed.stream;

  /// The cycle's reach, when it measures something different.
  Stream<WatchCoverage> get coverageChanges => _coverageChanges.stream;

  void _statusMoved(_Tracked tracked) {
    if (_disposed || _statusChanges.isClosed) return;
    _statusChanges.add(tracked.entry());
  }

  /// Folds a hook the server took in now, out of turn: no disk, no scan. An
  /// unwatched [key] asks for a cycle instead, rationed by [hookCycleFloor].
  void hookReported(AgentSessionKey key) {
    if (_disposed) return;
    hookReports++;
    final tracked = _tracked[key];
    if (tracked == null || agents.byId(key.agentId) == null) {
      _requestEarlyCycle();
      return;
    }
    // The server's own reading of a session it runs took this hook too.
    if (_isHosted(tracked.session)) return;
    final now = clock.nowUtc();
    final query =
        tracked.query ??
        AgentStatusQuery(
          agentId: key.agentId,
          sessionId: key.sessionId,
          stateFilePath: tracked.statePath,
        );
    final hook = statusService.hookReport(query, now);
    if (hook == null) return;
    final before = tracked.report;
    tracked.query = query;
    tracked.hook = hook;
    tracked.wantsProbe = false;
    _publish(
      tracked,
      _asked(
        tracked,
        statusService.compose(query: query, now: now, hook: hook),
        now,
      ),
      now,
    );
    if (sameStatusEvidence(before, tracked.report)) return;
    if (!_hookChanges.isClosed) _hookChanges.add(tracked.entry());
  }

  /// The server's own reading of the agent in row [openId] moved: folded in
  /// now. A row not watched yet joins the watch set at once, from memory.
  void hostStatusMoved(String openId) {
    if (_disposed) return;
    var tracked = _byOpenId[openId];
    if (tracked == null) {
      _observeWatched(clock.nowUtc());
      tracked = _byOpenId[openId];
      if (tracked == null) return;
      if (!_hookChanges.isClosed) _hookChanges.add(tracked.entry());
      return;
    }
    final before = tracked.report;
    _observe(tracked, clock.nowUtc());
    if (sameStatusEvidence(before, tracked.report)) return;
    if (!_hookChanges.isClosed) _hookChanges.add(tracked.entry());
  }

  bool _isHosted(WatchedSession session) =>
      !session.imported && (heldByHost?.call(session) ?? false);

  void _requestEarlyCycle() {
    final now = clock.nowUtc();
    final next = _nextHookCycle;
    if (next != null && now.isBefore(next)) return;
    _nextHookCycle = now.add(hookCycleFloor);
    unawaited(cycle().catchError((Object _) => _last));
  }

  /// Recomputes every watched session's status. A caller that joins a cycle
  /// in flight has what is in memory re-read now; only the disk work is
  /// shared.
  Future<List<SessionStatusEntry>> cycle() {
    final running = _inFlight;
    if (running != null) {
      _observeWatched(clock.nowUtc());
      return running;
    }
    final started = _cycle();
    _inFlight = started;
    return started.whenComplete(() => _inFlight = null);
  }

  Future<List<SessionStatusEntry>> _cycle() async {
    cycles++;
    final now = clock.nowUtc();
    final sessions = _observeWatched(now);

    await _resolvePaths(now);
    if (_disposed) return _last;

    final candidates = [
      for (final tracked in _tracked.values)
        if (tracked.wantsProbe && tracked.statePath != null) tracked,
    ];
    final picks = _select(candidates, now);
    await _probeAll(picks, now);
    if (_disposed) return _last;
    for (final tracked in picks) {
      _recompose(tracked, now);
    }

    _last = [
      for (final session in sessions)
        if (_tracked[session.key] case final tracked?) tracked.entry(),
    ];
    _measure(picks.length);
    return _last;
  }

  /// Loads the watch set and folds in every source already in memory — no
  /// disk. Returns the sessions loaded, in the loader's order.
  List<WatchedSession> _observeWatched(DateTime now) {
    final sessions = loadSessions();
    final seen = <AgentSessionKey>{};
    for (final session in sessions) {
      seen.add(session.key);
      final tracked = _tracked.putIfAbsent(
        session.key,
        () => _Tracked(session, now, _statusMoved),
      );
      tracked.session = session;
      tracked.statePath = session.stateFilePath ?? tracked.statePath;
      _observe(tracked, now);
    }
    // Only membership prunes. A session the rotation skipped keeps everything.
    final gone = [
      for (final entry in _tracked.entries)
        if (!seen.contains(entry.key)) entry.value.session.openId,
    ];
    _tracked.removeWhere((key, _) => !seen.contains(key));
    _byOpenId
      ..clear()
      ..addEntries(_tracked.values.map((t) => MapEntry(t.session.openId, t)));
    for (final openId in gone) {
      if (_byOpenId.containsKey(openId) || _removed.isClosed) continue;
      _removed.add(openId);
    }
    return sessions;
  }

  void _measure(int probed) {
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
    final next = WatchCoverage(
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
      log?.call('status: watching ${next.tracked} sessions — $next');
    }
    if (next.isBehind != (previous?.isBehind ?? false)) {
      log?.call(
        next.isBehind
            ? 'status: the transcript fallback is behind — $next'
            : 'status: the transcript fallback is keeping up again — $next',
      );
    }
    if (next != previous && !_coverageChanges.isClosed) {
      _coverageChanges.add(next);
    }
  }

  Duration? _rotationPeriod(int candidates) {
    if (candidates <= probeBudget) return interval;
    final reserve = probeBudget >= 2 ? math.max(1, probeBudget ~/ 3) : 0;
    if (reserve <= 0) return null;
    return interval * ((candidates + reserve - 1) ~/ reserve);
  }

  /// Begins cycling — one timer for the server.
  void start() {
    if (_timer != null || _disposed) return;
    _timer = Timer.periodic(interval, (_) => unawaited(cycle()));
    unawaited(cycle());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> close() async {
    _disposed = true;
    stop();
    _tracked.clear();
    _byOpenId.clear();
    await Future.wait([
      _hookChanges.close(),
      _statusChanges.close(),
      _removed.close(),
      _coverageChanges.close(),
    ]);
  }

  /// Recomputes one session from the sources in memory, and records whether
  /// its transcript still has to be consulted.
  void _observe(_Tracked tracked, DateTime now) {
    if (_isHosted(tracked.session)) {
      _observeHosted(tracked, now);
      return;
    }
    final query = AgentStatusQuery(
      agentId: tracked.session.key.agentId,
      sessionId: tracked.session.key.sessionId,
      stateFilePath: tracked.statePath,
    );
    tracked.query = query;
    final descriptor = agents.byId(query.agentId);
    if (descriptor == null) {
      tracked.hook = null;
      tracked.wantsProbe = false;
      _publish(tracked, statusService.unknownFor(query, now), now);
      return;
    }
    final hook = statusService.hookReport(query, now);
    tracked.hook = hook;
    tracked.wantsProbe =
        statusService.needsStateFile(hook, null) &&
        descriptor.stateFile != null;
    _recompose(tracked, now);
  }

  /// A session the server runs: its own reading, keyed as this registry keys
  /// the session.
  void _observeHosted(_Tracked tracked, DateTime now) {
    final key = tracked.session.key;
    tracked
      ..query = null
      ..hook = null
      ..snapshot = null
      ..wantsProbe = false;
    final said = hostStatusFor?.call(tracked.session)?.report;
    _publish(
      tracked,
      AgentStatusReport(
        agentId: key.agentId,
        sessionId: key.sessionId,
        status: said?.status ?? AgentActivityStatus.unknown,
        source: said?.source ?? AgentStatusSource.none,
        observedAt: said?.observedAt ?? now,
        sourceModifiedAt: said?.sourceModifiedAt,
        detail: said?.detail,
        evidence: said?.evidence ?? const [],
        waiting: said?.waiting ?? AgentWaitKind.unrecorded,
        ending: said?.ending,
        failureReason: said?.failureReason,
        toolAsk: said?.toolAsk,
        waitingSince: said?.waitingSince,
        inFlight: said?.inFlight ?? const [],
      ),
      now,
    );
  }

  /// Re-ranks one session's sources without touching disk.
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
    _publish(
      tracked,
      _asked(
        tracked,
        statusService.compose(
          query: query,
          now: now,
          hook: tracked.hook,
          state: state,
        ),
        now,
      ),
      now,
    );
  }

  /// Publishes [raw] for [tracked] — or, while a live session's agent is idle
  /// but its transcript has background work it has not finished with,
  /// `working` with that work in flight. An idle not yet checked waits for
  /// the read, so no finish is told that the read would take back.
  void _publish(_Tracked tracked, AgentStatusReport raw, DateTime now) {
    // When it went idle, not when a source last said so: a screen re-read
    // restamps the same idle every tick.
    tracked.idleSince = raw.status == AgentActivityStatus.idle
        ? tracked.idleSince ?? raw.observedAt
        : null;
    tracked.raw = raw;
    final session = tracked.session;
    final checks =
        backgroundRunsOf != null &&
        raw.status == AgentActivityStatus.idle &&
        !session.imported &&
        (_isHosted(session) || raw.source == AgentStatusSource.hook);
    if (!checks) {
      tracked
        ..background = null
        ..backgroundGeneration += 1;
      tracked.publish(raw, now);
      return;
    }
    final reading = tracked.background;
    if (reading == null) {
      _readBackground(tracked);
      return;
    }
    final held = _held(raw, reading.runs, now, tracked.idleSince);
    tracked.publish(held, now);
    if (!identical(held, raw) && now.difference(reading.at) >= interval) {
      _readBackground(tracked);
    }
  }

  /// [raw], or `working` with the runs still going named in flight.
  static AgentStatusReport _held(
    AgentStatusReport raw,
    List<BackgroundRun> runs,
    DateTime now,
    DateTime? idleSince,
  ) {
    final idleAt = idleSince ?? raw.observedAt;
    if (!waitsOnBackground(runs, idleAt: idleAt, now: now)) return raw;
    return AgentStatusReport(
      agentId: raw.agentId,
      sessionId: raw.sessionId,
      status: AgentActivityStatus.working,
      observedAt: raw.observedAt,
      source: raw.source,
      detail: raw.detail,
      sourceModifiedAt: raw.sourceModifiedAt,
      evidence: raw.evidence,
      inFlight: [
        for (final run in runs)
          if (run.state.isRunning) run.description ?? 'background work',
      ],
    );
  }

  void _readBackground(_Tracked tracked) {
    final read = backgroundRunsOf;
    if (read == null || tracked.readingBackground) return;
    tracked.readingBackground = true;
    final generation = tracked.backgroundGeneration;
    unawaited(() async {
      List<BackgroundRun> runs;
      try {
        runs = await read(tracked.session);
      } on Object {
        // A transcript that cannot be read holds nothing back.
        runs = const [];
      } finally {
        tracked.readingBackground = false;
      }
      if (_disposed || !identical(_tracked[tracked.session.key], tracked)) {
        return;
      }
      final raw = tracked.raw;
      if (raw == null || raw.status != AgentActivityStatus.idle) return;
      // A turn ran while this was read: what it launched may be missing.
      if (generation != tracked.backgroundGeneration) {
        _readBackground(tracked);
        return;
      }
      final now = clock.nowUtc();
      tracked.background = (runs: runs, at: now);
      final before = tracked.report;
      tracked.publish(_held(raw, runs, now, tracked.idleSince), now);
      if (sameStatusEvidence(before, tracked.report)) return;
      if (!_hookChanges.isClosed) _hookChanges.add(tracked.entry());
    }());
  }

  /// [next] with the call an open prompt asks about and when its wait began,
  /// carried over from what [tracked] said before while the wait goes on.
  AgentStatusReport _asked(
    _Tracked tracked,
    AgentStatusReport next,
    DateTime now,
  ) => toolAsks?.decorate(before: tracked.report, next: next, now: now) ?? next;

  /// Resolves transcript paths for everything still missing one, with one
  /// walk shared by all of them.
  Future<void> _resolvePaths(DateTime now) async {
    final resolve = resolveTranscripts;
    if (resolve == null || _disposed) return;
    final pending = [
      for (final tracked in _tracked.values)
        if (tracked.wantsProbe &&
            tracked.statePath == null &&
            tracked.isNamedByItsCli)
          tracked,
    ];
    if (pending.isEmpty) return;
    final next = _nextTranscriptSearch;
    if (next != null && now.isBefore(next)) return;
    _nextTranscriptSearch = now.add(transcriptSearchInterval);
    transcriptScans++;
    final Map<String, String> index;
    try {
      index = await resolve();
    } on Object {
      // A store that cannot be read is the same answer as one that is empty.
      return;
    }
    if (_disposed) return;
    for (final tracked in pending) {
      final path = index[tracked.session.key.toString()];
      if (path == null) continue;
      tracked.statePath = path;
      _observe(tracked, now);
    }
  }

  /// This cycle's probes: priority first, then a rotation on a reserved third
  /// of the budget, so every candidate is reached within `ceil(M / reserve)`
  /// cycles.
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
    final picks = <_Tracked>[...priority.take(priorityCap)];
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
    await Future.wait([for (var i = 0; i < workers; i++) _drain(queue, now)]);
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
      // Losing sight of a session is not evidence that anything changed.
      tracked.probeFailed = true;
      return;
    }
    tracked.probeFailed = false;
    if (!identical(snapshot, known)) tailReads++;
    tracked.snapshot = snapshot;
  }
}

/// Everything kept about one session between cycles.
class _Tracked {
  _Tracked(this.session, DateTime now, this._onMoved)
    : report = AgentStatusReport(
        agentId: session.key.agentId,
        sessionId: session.key.sessionId,
        status: AgentActivityStatus.unknown,
        source: AgentStatusSource.none,
        observedAt: now,
      ),
      changedAt = now,
      statePath = session.stateFilePath;

  WatchedSession session;
  AgentStatusReport report;
  final void Function(_Tracked tracked) _onMoved;

  /// When the status last actually changed — the input to "recently active".
  DateTime changedAt;

  String? statePath;
  StateFileSnapshot? snapshot;
  DateTime? lastProbedAt;
  bool probeFailed = false;
  bool wantsProbe = false;

  AgentStatusQuery? query;
  AgentStatusReport? hook;

  /// The last report its sources gave, before any background hold.
  AgentStatusReport? raw;
  DateTime? idleSince;
  ({List<BackgroundRun> runs, DateTime at})? background;
  var backgroundGeneration = 0;
  var readingBackground = false;

  String get sortKey => session.key.toString();

  /// Whether the CLI has announced this session's own id. A session keyed by
  /// its row id matches no transcript, so it must not ask for store walks.
  bool get isNamedByItsCli =>
      session.imported || session.key.sessionId != session.openId;

  void publish(AgentStatusReport next, DateTime now) {
    final moved = !sameStatusEvidence(report, next);
    if (moved) changedAt = now;
    report = next;
    if (moved) _onMoved(this);
  }

  SessionStatusEntry entry() =>
      SessionStatusEntry(session: session, report: report);
}
