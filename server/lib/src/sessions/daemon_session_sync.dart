import 'dart:async';
import 'dart:math' as math;

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/process.dart';
import 'package:agent_cli/read.dart';
import 'package:karmashala_core/util.dart';
import 'package:karmashala_environments/store.dart'
    show ExecutionEnvironmentDao;
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart'
    show hostSessionIdOf;
import 'package:karmashala_store/database.dart';

import '../data/data_service.dart';
import '../domain/host_session.dart';
import '../domain/session_registry.dart';
import '../domain/uuid.dart';
import '../protocol/messages.dart';
import 'client_panes.dart';
import 'directory_attribution.dart';
import 'launched_attribution.dart';
import 'session_adoption.dart';
import 'session_sync_rows.dart';
import 'store_session_scan.dart';
import 'title_sync.dart';

/// How often the server looks at its agents' stores for what its session
/// rows are missing — the app's store slot's pace.
const Duration kSessionSyncInterval = Duration(seconds: 10);

/// **The session rows' agent-side facts, kept by the server** (slice 2b):
/// the title an agent gave its conversation ([TitleSync]), the conversation
/// a launched session is on when its agent takes no id ([LaunchedAttribution],
/// [DirectoryAttribution]), and a session a person started by hand in a
/// client's pane ([SessionAdoption]). Every write goes through the data
/// service, so every client is told the row.
///
/// Runs on its own timer: cheap `wantsStoreSweep` checks first, then at most
/// one store scan per pass, on a worker isolate. Takes every agent hook the
/// server receives ([hook]) and every client's terminal panes as facts
/// ([report]/[detach] — the host server's [PaneFactsReceiver]).
class DaemonSessionSync implements PaneFactsReceiver {
  DaemonSessionSync({
    required AppDatabase database,
    required DataService data,
    required this.registry,
    Future<List<CliStore>> Function()? locateStores,
    StoreScan? scan,
    this.agents = AgentRegistry.builtIn,
    Clock clock = const SystemClock(),
    String Function()? newId,
    this.interval = kSessionSyncInterval,
    void Function(String message)? log,
  }) : rows = SessionSyncRows(database, data, log: log),
       _log = log {
    final locate = locateStores ?? _machineStores(database);
    _scanner = scan == null
        ? StoreSessionScanner(locate: locate, log: log)
        : null;
    _scan = scan ?? _scanner!.scan;
    adoption = SessionAdoption(
      rows: rows,
      newId: newId ?? newUuid,
      clock: clock,
      agents: agents,
    );
    titles = TitleSync(rows: rows, agents: agents, isRunning: _runsNow);
    launched = LaunchedAttribution(rows: rows, agents: agents);
    directories = DirectoryAttribution(
      rows: rows,
      agents: agents,
      locateStores: locate,
      readTail: _tailOf,
    );
    panes.onChanged = adoption.observePanes;
  }

  final SessionRegistry registry;
  final AgentRegistry agents;
  final Duration interval;
  final SessionSyncRows rows;
  final ClientPanes panes = ClientPanes();
  late final SessionAdoption adoption;
  late final TitleSync titles;
  late final LaunchedAttribution launched;
  late final DirectoryAttribution directories;
  final void Function(String message)? _log;

  StoreSessionScanner? _scanner;
  late final StoreScan _scan;
  Timer? _timer;
  Future<int>? _passing;
  var _closed = false;

  /// The tails the current pass took, by pane.
  Map<String, List<String>> _tails = const {};

  /// Passes run, and store scans they bought — the cost claims.
  int passes = 0;
  int scans = 0;

  /// This machine's stores and those of the environments it records, each
  /// reached the way the conversation index reaches them.
  static Future<List<CliStore>> Function() _machineStores(
    AppDatabase database,
  ) {
    final environments = ExecutionEnvironmentDao(database);
    final locator = CliStoreLocator(
      runnerFor: (id) => const CommandRunnerFactory().forEnvironment(
        environments.getById(id) ??
            localHostEnvironment(DateTime.now().toUtc()),
      ),
    );
    return () => locator.locate(environments.getAll());
  }

  void start() {
    if (_closed) return;
    _timer ??= Timer.periodic(interval, (_) => unawaited(pass()));
  }

  Future<void> close() async {
    _closed = true;
    _timer?.cancel();
    _timer = null;
    try {
      await _passing;
    } on Object {
      // Closing: a pass that failed has nothing left to say.
    }
    _scanner?.close();
    rows.close();
  }

  @override
  void report(
    Object client,
    List<PaneFacts> panes,
    void Function(HostMessage message) send,
  ) {
    if (_closed) return;
    this.panes.report(client, panes, send);
  }

  @override
  void detach(Object client) => panes.detach(client);

  /// One hook the server received: a conversation of an agent in a pane it
  /// may not know about — a session a person started by hand. Synchronous
  /// and cheap. Never throws.
  void hook(AgentHookEvent hook) {
    if (_closed) return;
    try {
      final descriptor = agents.adapterFor(hook.agent)?.descriptor;
      final spec = descriptor?.hooks;
      if (descriptor == null || spec == null) return;
      // A hook from a pane that runs a row of ours is that row's.
      final pane = hook.sessionHeader;
      if (pane != null && rows.sessions.getById(pane) != null) return;
      adoption.hook(
        agentId: descriptor.id,
        conversationId: hookStringAt(spec.sessionIdPath, hook.body),
        cwd: spec.cwdPath.isEmpty ? '' : hookStringAt(spec.cwdPath, hook.body),
      );
    } on Object catch (error) {
      _log?.call('session sync: adoption from a hook failed ($error)');
    }
  }

  /// One pass: the screens the clients sent, directory attribution, then —
  /// only when a row or pane waits for one — one store scan shared by
  /// adoption, launched attribution and the title sync, in that order
  /// (attribution learns an id; the title sync can only match one). Ends by
  /// asking the clients for the tails the next pass reads. One at a time.
  Future<int> pass() {
    if (_closed) return Future.value(0);
    return _passing ??= _pass().whenComplete(() => _passing = null);
  }

  Future<int> _pass() async {
    passes++;
    var wrote = 0;
    try {
      _tails = panes.takeTails();
      adoption.armFromScreens(_tails);
      if (directories.wantsStoreSweep) wrote += await directories.attribute();
      if (_closed) return wrote;
      if (adoption.wantsStoreSweep ||
          launched.wantsStoreSweep ||
          titles.wantsStoreSweep) {
        final pass = StoreScanPass(_scan);
        List<DetectedSession>? detected;
        try {
          scans++;
          detected = await pass.read();
        } on Object catch (error) {
          // A store we cannot read is the same answer as one with nothing in
          // it — never a reason to change a row.
          _log?.call('session sync: the store scan failed ($error)');
        }
        if (detected != null && !_closed) {
          wrote += adoption.sweep(detected);
          wrote += launched.attribute(detected);
          wrote += titles.sync(detected);
        }
      }
    } on Object catch (error) {
      _log?.call('session sync: a pass failed ($error)');
    } finally {
      _tails = const {};
      if (!_closed) _askForTails();
    }
    return wrote;
  }

  /// The panes whose bottom rows the next pass reads: those a screen could
  /// arm, and those of rows waiting for directory attribution that this
  /// server does not hold the screen of.
  void _askForTails() {
    final ids = <String>{...adoption.screenCandidates};
    var lines = ids.isEmpty ? 0 : adoption.screenLines;
    for (final row in directories.waitingRows()) {
      final paneId = row.paneId;
      if (paneId == null || _hosted(row) != null) continue;
      ids.add(paneId);
      lines = math.max(lines, directories.tailLines);
    }
    panes.want(ids, lines);
  }

  /// The screen [row] runs on: the server's own for a row it hosts, else the
  /// tail a client sent for the row's pane this pass.
  List<String> _tailOf(Session row, int lines) {
    final hosted = _hosted(row);
    if (hosted != null) return hosted.tailText(lines);
    final paneId = row.paneId;
    final tail = paneId == null ? null : _tails[paneId];
    if (tail == null) return const [];
    return tail.length <= lines ? tail : tail.sublist(tail.length - lines);
  }

  HostSession? _hosted(Session row) => registry.find(hostSessionIdOf(row.id));

  /// Whether [row]'s agent runs now: a host session of it runs here, or a
  /// client reports its pane live and running what it launched.
  bool _runsNow(Session row) {
    final hosted = _hosted(row);
    if (hosted != null && !hosted.lifecycle.hasEnded) return true;
    final paneId = row.paneId;
    if (paneId == null) return false;
    final pane = adoption.pane(paneId);
    return pane != null && pane.live && pane.hostsLaunchedSession;
  }
}

/// The string at [path] in a hook's JSON [body], or `''` for anything else.
/// A list's first string is its value: some agents report the directories
/// they work in as a list, the first being the one.
String hookStringAt(List<String> path, Object? body) {
  Object? value = body;
  for (final segment in path) {
    if (value is Map) {
      value = value[segment];
    } else if (value is List) {
      final index = int.tryParse(segment);
      if (index == null || index < 0 || index >= value.length) return '';
      value = value[index];
    } else {
      return '';
    }
  }
  if (value is String) return value;
  if (value is List && value.isNotEmpty && value.first is String) {
    return value.first as String;
  }
  return '';
}
