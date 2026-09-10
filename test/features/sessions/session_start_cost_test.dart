import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/explorer/application/session_diff_stat.dart';
import 'package:karmashala/src/features/follow_ups/application/follow_up_inbox.dart';
import 'package:karmashala/src/features/git/application/changes_providers.dart';
import 'package:karmashala/src/features/notifications/application/attention_inbox.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/session_launcher.dart';
import 'package:karmashala/src/features/sessions/application/session_resume_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_working_directory.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala/src/features/sessions/domain/session_launch.dart';
import 'package:karmashala/src/features/sessions/domain/session_status.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/settings/domain/settings.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm2/xterm.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../scale/scale_harness.dart';
import '../terminal/fake_instance.dart';

/// **What starting one session costs.**
///
/// The owner's words: *"starting new session is heavy and laggy too."*
///
/// A start is one row, one pane and one process — none of which grows with the
/// workspace. What *did* grow is the signal it published on the way out:
/// `SessionLauncher.launch` ended with a bare `bump()`, which is
/// [SessionChange.everything] — the coarse word that says "we cannot name what
/// moved". That word raises `SessionSignals.broadcasts`, the floor under
/// **every** per-row watcher, and the Explorer builds one
/// [sessionWhereaboutsProvider] per drawn card. Each of those answers with a
/// `getById`, and for a card whose pane has *exited* it also scans that pane's
/// screen looking for the agent's refusal to resume. So one click re-read every
/// session's row and re-scanned every dead pane, synchronously, on the UI
/// isolate, inside the frame.
///
/// Measured here, per start, over a workspace where every third session has
/// stopped:
///
/// ```txt
/// sessions   statements   row reads   screen scans   rebuilds   rows decoded
///        1    26 ->  24     2 ->  1       2 ->  1     6 ->  5     11 ->  10
///       10    38 ->  24    11 ->  1       5 ->  1     9 ->  5     56 ->  46
///      100   158 ->  24   101 ->  1      35 ->  1    39 ->  5    506 -> 406
/// ```
///
/// The fix is one word. A launch *does* know what it moved: one row appeared,
/// started, and claimed a pane. Naming the row leaves `broadcasts` alone, so
/// the ninety-nine cards that did not change stay asleep — and a start now
/// costs the same at a hundred sessions as at one.
///
/// **What is left, and why it stays.** The last column does still rise, and
/// that is the honest floor: three providers legitimately re-read the session
/// list when the list changes shape — the placement map, the Explorer's own
/// list, and `SessionEndingObserver`'s sweep — and each is one statement and N
/// decoded rows. That is pinned below as a slope rather than removed, so a
/// *fourth* scanning watcher cannot be added without a number moving.
///
/// **It was four.** The project header was the fourth, and it was the one that
/// had no business reading a row at all: it built a whole `Session` out of
/// twenty-one columns, and a whole `ImportedSession` out of twelve, for every
/// row under every checkout in the project — to add one to an integer and drop
/// the rest. A header never *names* a session, so it now asks SQLite for two
/// integers instead, in one statement for the whole project rather than two per
/// repository. The slope fell from 4 to 3 and the numbers below moved with it:
///
/// ```txt
/// sessions    rows decoded per start
///        1     12 ->  12
///       10     48 ->  39
///      100    408 -> 309
/// ```
///
/// **And rows are not the whole cost of a row.** Of the three readers left,
/// one — the placement map — wants a session's *repository* and nothing else,
/// and was building the whole twenty-one-column object (with the ISO parse
/// `dateFromIso`'s comment measured at 8% of the app's CPU under load) to read
/// two fields off it. `SessionDao.repositoryIdsById` asks for the two columns,
/// the way `paneSessionIds` next door already does. Columns decoded per start:
///
/// ```txt
/// sessions    column values decoded
///        1    213 ->  175
///       10    780 ->  571
///      100   6450 -> 4531
/// ```
///
/// The slope is 63 -> 44: three readers at 21 columns each becomes 21 + 21 + 2.
/// A row count cannot see that difference, so this file counts cells as well.
///
/// The observer also re-arms one `ref.listen` per running row on every
/// rebuild, which looks alarming and costs nothing: `statusStreams` is 1 at
/// every scale, before the fix and after, because re-listening a live provider
/// builds no stream.
///
/// Counted, not timed, for the reason `session_signal_cost_test.dart` and
/// `quiet_soak_cost_test.dart` both give: the suite runs at `--concurrency=4`,
/// so a wall-clock assertion over a few milliseconds is a coin toss, and every
/// unit that matters here — statements, spawns, encodes, republications — is
/// countable directly.
///
/// The second half is the guard against a false green: a start that got cheap
/// by not updating anything would be worse than the cost it removed, so every
/// list a new session has to appear in is asserted to still show it.
void main() {
  /// The three points the curve is read at. One session is the "did we make the
  /// small case worse" control; a hundred is the scale the owner's workspace
  /// reaches.
  const scale = [1, 10, 100];

  group('starting one session', () {
    /// Filled by the cases below so the *shape* can be asserted across them
    /// rather than inside any one of them.
    final statements = <int, int>{};
    final rowReads = <int, int>{};
    final rowsScanned = <int, int>{};
    final cellsScanned = <int, int>{};
    final statusSubscriptions = <int, int>{};
    final notifications = <int, int>{};
    final encodes = <int, int>{};
    final screenScans = <int, int>{};
    final spawns = <int, int>{};

    for (final count in scale) {
      test('with $count already open costs the same', () async {
        final workspace = _StartWorkspace(sessions: count);
        addTearDown(workspace.dispose);
        await workspace.settle();

        final measured = await workspace.start();

        statements[count] = measured.statements;
        rowReads[count] = measured.rowReads;
        rowsScanned[count] = measured.rowsScanned;
        cellsScanned[count] = measured.cellsScanned;
        statusSubscriptions[count] = measured.statusSubscriptions;
        notifications[count] = measured.notifications;
        encodes[count] = measured.encodes;
        screenScans[count] = measured.screenScans;
        spawns[count] = measured.spawns;
        // ignore: avoid_print
        print(
          'SESSION-START sessions=$count statements=${measured.statements} '
          'reads=${measured.reads} writes=${measured.writes} '
          'rowReads=${measured.rowReads} scans=${measured.tableScans} '
          'rowsScanned=${measured.rowsScanned} '
          'cellsScanned=${measured.cellsScanned} '
          'statusStreams=${measured.statusSubscriptions} '
          'notified=${measured.notifications} encodes=${measured.encodes} '
          'screenScans=${measured.screenScans} spawns=${measured.spawns}',
        );
      });
    }

    test('so a start costs the same at a hundred sessions as at one', () {
      expect(statements.keys, containsAll(scale));
      expect(
        statements.values.toSet(),
        hasLength(1),
        reason: 'database statements per start: $statements',
      );
      expect(
        rowReads.values.toSet(),
        hasLength(1),
        reason:
            'a start re-reads only the rows it moved, and it moved one: '
            '$rowReads',
      );
      expect(
        notifications.values.toSet(),
        hasLength(1),
        reason: 'providers republished per start: $notifications',
      );
      expect(
        statusSubscriptions.values.toSet(),
        orderedEquals([1]),
        reason:
            'the session that started needs a status stream; the ones already '
            'running keep the streams they have. `SessionEndingObserver` '
            're-arms a `ref.listen` per running row on every rebuild, and this '
            'is what says that costs nothing: $statusSubscriptions',
      );
      // Rows, not statements. Three providers legitimately re-read the list
      // when the list changes shape — the placement map, the Explorer's own
      // list and the follow-up sweep — and each is one statement and N decoded
      // rows. A fourth would be invisible in every other number on this page.
      //
      // It was four until the project header stopped reading rows to count
      // them: `SessionDao.countsByRepositories` answers with two integers, so
      // the header's contribution to this slope is now zero however many
      // sessions the project holds. Tightened rather than left at 4, because a
      // bound with slack in it is a bound that lets the next regression
      // through.
      expect(
        [
          (rowsScanned[10]! - rowsScanned[1]!) / 9,
          (rowsScanned[100]! - rowsScanned[10]!) / 90,
        ],
        everyElement(3),
        reason:
            'a start may re-read the session list a fixed number of times, '
            'and that number is three: $rowsScanned',
      );
      // **Columns, which the row count cannot see.** Three reads of the same
      // rows are not three equal costs: two of them want the whole session and
      // one wants its placement, which is two columns. 21 + 21 + 2 is the
      // slope, and it was 21 x 3 while the placement map decoded a `Session`
      // it then read `id` and `repositoryId` off.
      expect(
        [
          (cellsScanned[10]! - cellsScanned[1]!) / 9,
          (cellsScanned[100]! - cellsScanned[10]!) / 90,
        ],
        everyElement(44),
        reason:
            'an extra session costs a start 21 columns for the Explorer list, '
            '21 for the ending sweep and 2 for the placement map — never 21 '
            'for a reader that wants 2: $cellsScanned',
      );
      expect(
        encodes.values.toSet(),
        orderedEquals([1]),
        reason:
            'only the new pane\'s own empty buffer is encoded — a start must '
            'never re-encode a layout: $encodes',
      );
      expect(
        screenScans.values.toSet(),
        orderedEquals([1]),
        reason:
            'only the pane being opened touches a screen — a session starting '
            'says nothing about what any *other* pane is showing, so no dead '
            'pane\'s buffer may be scanned for a refusal: $screenScans',
      );
      expect(
        spawns.values.toSet(),
        orderedEquals([1]),
        reason:
            'a start is exactly one process, whatever else is open: $spawns',
      );
    });
  });

  group('what a start must still do', () {
    late _StartWorkspace workspace;

    setUp(() async {
      workspace = _StartWorkspace(sessions: 10);
      await workspace.settle();
    });
    tearDown(() => workspace.dispose());

    test('the new row joins every list', () async {
      final result = await workspace.launch();
      await workspace.container.pump();

      final id = result.session.id;
      expect(
        workspace.container
            .read(sessionsForSelectedRepositoryProvider)
            .map((s) => s.id),
        contains(id),
        reason: 'the Explorer must draw the session that was just started',
      );
      expect(
        workspace.container.read(sessionProjectIdsProvider).containsKey(id),
        isTrue,
        reason: 'the placement map decides which project the card hangs under',
      );
      expect(
        workspace.container.read(projectSummaryProvider('p1')).sessions,
        11,
        reason: 'the project header counts rows, and there is one more',
      );
    });

    test('its own card knows where it is', () async {
      final result = await workspace.launch();
      await workspace.container.pump();

      expect(
        workspace.container
            .read(sessionWhereaboutsProvider(result.session.id))
            .hostedLive,
        isTrue,
        reason: 'the row that was just started is running in a live pane',
      );
    });

    test('and a pane and a process exist for it', () async {
      final result = await workspace.launch();

      final instance = workspace.controller.instanceFor(result.paneId!);
      expect(instance, isNotNull);
      expect(
        instance!.agentLaunch,
        isA<AgentPaneLaunch>().having(
          (l) => l.sessionId,
          'sessionId',
          result.session.id,
        ),
      );
      expect(
        workspace.db.query(
          'SELECT pane_id FROM sessions WHERE id = ?;',
          [result.session.id],
        ).single['pane_id'],
        result.paneId,
        reason: 'the row must record the pane it claimed',
      );
    });

    test('a failed start still tells the tree the row moved', () async {
      final before = workspace.container.read(sessionsRevisionProvider);
      await expectLater(
        workspace.launcher.launch(
          SessionLaunchRequest(
            repository: repository(),
            installation: agentInstallation(),
            title: 'New session',
            purpose: SessionPurpose.newSession,
            // An environment that is not in the table, so `_startInPane`
            // cannot resolve one and throws after the row is written.
            existingWorktree: const EnvironmentPath(
              environmentId: 'gone',
              path: r'C:\src\demo\app',
            ),
          ),
        ),
        throwsA(isA<StateError>()),
      );
      await workspace.container.pump();

      expect(
        workspace.container.read(sessionsRevisionProvider),
        greaterThan(before),
        reason: 'a row left `failed` must still reach the list that draws it',
      );
      expect(
        workspace.container
            .read(sessionsForSelectedRepositoryProvider)
            .where((s) => s.title == 'New session'),
        hasLength(1),
        reason: 'the failed row is in the Explorer, not lost',
      );
    });
  });

  group('what a start does not wake', () {
    test('another session\'s card', () async {
      final workspace = _StartWorkspace(sessions: 10);
      addTearDown(workspace.dispose);
      await workspace.settle();

      var otherCardRebuilds = 0;
      workspace.container.listen(
        sessionWhereaboutsProvider('s5'),
        (_, _) => otherCardRebuilds++,
      );
      await workspace.container.pump();
      workspace.db.reset();

      await workspace.launch();
      await workspace.container.pump();

      expect(
        otherCardRebuilds,
        0,
        reason:
            'a session that was already open did not move because another one '
            'started',
      );
    });

    test('the permission chip of a session nobody reconfigured', () async {
      final workspace = _StartWorkspace(sessions: 10);
      addTearDown(workspace.dispose);
      await workspace.settle();

      var settingsRebuilds = 0;
      workspace.container.listen(
        _settingsSignal,
        (_, _) => settingsRebuilds++,
      );
      await workspace.container.pump();

      await workspace.launch();
      await workspace.container.pump();

      expect(
        settingsRebuilds,
        0,
        reason: 'a launch chooses no per-session policy, so none changed',
      );
    });
  });
}

/// A read with no `WHERE` against the sessions table.
///
/// Either spelling: the Explorer's list orders its rows, and the placement map
/// asks for two columns of every row and does not. Both are scans, and a
/// pattern that only recognised the ordered one stopped counting the placement
/// map the moment it was narrowed.
final _unfilteredSessionScan = RegExp(r'FROM\s+sessions\s*(;|ORDER\s+BY)');

/// One session row by id — what `sessionWhereaboutsProvider` asks per card.
final _oneRowRead = RegExp(r'FROM\s+sessions\s+WHERE\s+id\s+=');

/// The number the permission chip reads: it watches only
/// [SessionChangeKind.settings].
final _settingsSignal = Provider<int>(
  (ref) => ref.watch(
    sessionSignalsProvider.select(
      (s) => s.forKinds(const {SessionChangeKind.settings}),
    ),
  ),
);

/// What one start cost, in the units this file counts.
class _StartCost {
  const _StartCost({
    required this.statements,
    required this.reads,
    required this.writes,
    required this.rowReads,
    required this.tableScans,
    required this.rowsScanned,
    required this.cellsScanned,
    required this.statusSubscriptions,
    required this.notifications,
    required this.encodes,
    required this.screenScans,
    required this.spawns,
  });

  final int statements;
  final int reads;
  final int writes;

  /// `SELECT * FROM sessions WHERE id = ?` — one per per-row watcher that woke.
  /// The Explorer builds a card per session, so this is the number that used to
  /// track the size of the workspace.
  final int rowReads;

  /// Unfiltered reads of the sessions table. A create genuinely changes the
  /// shape of every list, so these are legitimate — but they must not multiply.
  final int tableScans;

  /// **Rows decoded** out of the sessions table, which is the unit a statement
  /// count hides: one `getAll()` is one statement and N `Session` objects, and
  /// `SessionEndingObserver` answers every membership-or-status signal with
  /// exactly that.
  final int rowsScanned;

  /// **Column values decoded** out of the sessions table — rows times their
  /// width. What tells a narrow read from a `SELECT *` over the same rows,
  /// which [rowsScanned] cannot: the placement map asks for two columns and the
  /// Explorer's own list asks for twenty-one, and only this number says so.
  final int cellsScanned;

  /// Streams `agentSessionStatusProvider` had to build. The observer re-arms
  /// one `ref.listen` per running row on every rebuild, so a start that made
  /// those churn would build a stream per session here.
  final int statusSubscriptions;

  /// Providers that actually republished, which is a widget rebuild each.
  final int notifications;
  final int encodes;

  /// Reads of a pane's *live screen*. `sessionWhereaboutsProvider` scans the
  /// tail of every **dead** pane it recomputes, looking for an agent's refusal
  /// to resume — so this is what a coarse signal costs in terminal text.
  final int screenScans;
  final int spawns;
}

/// A workspace of [sessions] running sessions, each in its own agent pane, over
/// a real database and the production [SessionLauncher].
///
/// Everything an ordinary screen has watching the session list is subscribed
/// the way the widgets that own them subscribe, because the cost this file is
/// about is the fan-out rather than the row.
class _StartWorkspace {
  _StartWorkspace({required this.sessions}) {
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());
    AgentInstallationDao(db).insert(agentInstallation());

    container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(
          database: db,
          instanceFactory:
              ({
                required id,
                required profile,
                workingDirectory,
                restoredScrollback,
                shellIntegration = false,
                agentLaunch,
                adoptTerminal,
              }) {
                // The launch is a process: a pane the app opened for an agent
                // is one PTY, and that is the spawn this file counts.
                if (agentLaunch != null) processes++;
                final terminal = _CountingScreen()..resize(120, 40);
                terminals[id] = terminal;
                return FakeTerminalInstance(
                  id: id,
                  title: agentLaunch?.title ?? profile.label,
                  profileId: agentLaunch?.profileId ?? profile.id,
                  workingDirectory: workingDirectory,
                  agentLaunch: agentLaunch,
                  adoptTerminal: terminal,
                );
              },
        ),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        idGeneratorProvider.overrideWithValue(SequentialIdGenerator('new-')),
        settingsControllerProvider.overrideWith(_StaticSettings.new),
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(fallback: git),
        ),
        // The status pipeline is not the subject here; the row and the pane
        // are. The live one fans into `SessionStatusRegistry`, which stats
        // transcript files on its own cycle — a disk cost `periodic_tick_bench`
        // owns.
        agentSessionStatusProvider.overrideWith((ref, id) {
          statusSubscriptions++;
          return const Stream<AgentStatusReport>.empty();
        }),
        // Nothing under `C:\src\demo` exists on a test machine, so the default
        // would call every recorded directory gone.
        sessionDirectoryPresentProvider.overrideWithValue((_) => true),
      ],
    );
    controller = container.read(terminalSessionsControllerProvider.notifier);
    launcher = container.read(sessionLauncherProvider);

    // The workspace as the user left it: every session running in its own
    // agent pane, exactly as a start leaves one.
    for (var i = 0; i < sessions; i++) {
      final opened = controller.openAgentTab(
        AgentPaneLaunch(
          agentId: agentInstallation().agentId,
          executable: agentInstallation().executable.path,
          arguments: const [],
          workingDirectory: repository().path.path,
          sessionId: 's$i',
          title: 'Session $i',
        ),
      );
      // A real workspace is not all live. Every third session has stopped and
      // its pane has exited — which is the branch of
      // `sessionWhereaboutsProvider` that scans the pane's screen, so a coarse
      // signal costs terminal text as well as SQL.
      final stopped = i % 3 == 0;
      SessionDao(db).insert(
        session(
          id: 's$i',
          title: 'Session $i',
          status: stopped
              ? (i == 0 ? SessionStatus.failed : SessionStatus.completed)
              : SessionStatus.running,
        ),
      );
      SessionDao(db).updatePaneId('s$i', opened.paneId);
      if (stopped) {
        final instance =
            controller.instanceFor(opened.paneId)! as FakeTerminalInstance;
        instance.terminal.write('Session $i finished.\r\n');
        instance.exitCleanly();
      }
    }
  }

  final int sessions;
  final db = _RowCountingDatabase();
  final git = FakeCommandRunner();
  final Map<String, _CountingScreen> terminals = {};

  late final ProviderContainer container;
  late final TerminalSessionsController controller;
  late final SessionLauncher launcher;

  /// Agent panes built, which is one PTY each.
  int processes = 0;

  /// Status streams built during the measurement.
  int statusSubscriptions = 0;

  /// Every republication any of the subscribed providers has made — one
  /// widget rebuild each. Recomputations that produced an equal value do not
  /// show here; [_StartCost.rowReads] is what counts those.
  int notifications = 0;

  /// Subscribes everything an ordinary screen watches, then lets it all settle
  /// so the measurement starts from a quiet workspace.
  Future<void> settle() async {
    container.read(selectedRepositoryIdProvider.notifier).select('r1');
    container.listen(attentionInboxProvider, (_, _) => notifications++);
    container.listen(sessionProjectIdsProvider, (_, _) => notifications++);
    container.listen(projectSummaryProvider('p1'), (_, _) => notifications++);
    container.listen(openFollowUpsProvider, (_, _) => notifications++);
    container.listen(
      sessionsForSelectedRepositoryProvider,
      (_, _) => notifications++,
    );
    container.listen(
      importedSessionsForSelectedRepositoryProvider,
      (_, _) => notifications++,
    );
    // One per drawn row: the Explorer builds a card per session.
    for (var i = 0; i < sessions; i++) {
      container.listen(
        sessionWhereaboutsProvider('s$i'),
        (_, _) => notifications++,
      );
    }
    await container.pump();
    controller.persistLayout();
    await container.pump();
  }

  /// Starts a brand-new session, exactly as the Explorer's `+` does.
  Future<SessionLaunchResult> launch() => launcher.launch(
    SessionLaunchRequest(
      repository: repository(),
      installation: agentInstallation(),
      title: 'New session',
      purpose: SessionPurpose.newSession,
    ),
  );

  /// One start, priced.
  Future<_StartCost> start() async {
    db.reset();
    git.requests.clear();
    processes = 0;
    statusSubscriptions = 0;
    notifications = 0;
    for (final terminal in terminals.values) {
      terminal
        ..bufferReads = 0
        ..screenReads = 0;
    }

    await launch();
    await container.pump();

    return _StartCost(
      statements: db.count,
      reads: db.reads.length,
      writes: db.writes.length,
      rowReads: db.reads.where(_oneRowRead.hasMatch).length,
      tableScans: db.reads.where(_unfilteredSessionScan.hasMatch).length,
      rowsScanned: db.sessionRowsScanned,
      cellsScanned: db.sessionCellsScanned,
      statusSubscriptions: statusSubscriptions,
      notifications: notifications,
      // The new pane's own terminal is built during the measurement, so its
      // reads are counted too — a start that encoded a hundred scrollbacks and
      // its own would show up here.
      encodes: terminals.values.fold(0, (sum, t) => sum + t.bufferReads),
      screenScans: terminals.values.fold(0, (sum, t) => sum + t.screenReads),
      spawns: processes + git.requests.length,
    );
  }

  void dispose() {
    container.dispose();
    db.close();
  }
}

/// A [CountingDatabase] that also counts the *rows* and the *columns* the
/// sessions table gave back.
///
/// A statement count hides the whole of `SessionEndingObserver`: one `getAll()`
/// is one statement and N decoded rows, and the observer answers every
/// membership-or-status signal with one. Counting rows is what tells a scan
/// that is O(1) in statements from one that is O(sessions) in work.
///
/// **And counting cells is what tells `SELECT *` from a narrow read**, which
/// the row count is blind to: `SELECT id, repository_id` and
/// `SELECT *` return the same rows, and one of them builds a two-entry map per
/// row while the other builds twenty-one and parses an ISO timestamp out of
/// two of them. That difference is invisible in every other number on this
/// page and is most of the work a placement map actually does.
class _RowCountingDatabase extends CountingDatabase {
  int sessionRowsScanned = 0;

  /// Column values handed back from the sessions table — rows x their width.
  int sessionCellsScanned = 0;

  static final _sessionTable = RegExp(r'FROM\s+sessions\b');

  @override
  void reset() {
    super.reset();
    sessionRowsScanned = 0;
    sessionCellsScanned = 0;
  }

  @override
  List<Map<String, Object?>> query(
    String sql, [
    List<Object?> params = const [],
  ]) {
    final rows = super.query(sql, params);
    if (_sessionTable.hasMatch(sql)) {
      sessionRowsScanned += rows.length;
      for (final row in rows) {
        sessionCellsScanned += row.length;
      }
    }
    return rows;
  }
}

/// A [CountingTerminal] that also counts reads of the **active screen**.
///
/// `terminalTailLines` — the only thing that reads a pane's screen outside the
/// renderer — goes through `Terminal.buffer`, which is a different getter from
/// the `mainBuffer` the scrollback codec uses. Counting both apart is what lets
/// this file tell "a start re-encoded a layout" from "a start re-read one".
class _CountingScreen extends CountingTerminal {
  int screenReads = 0;

  @override
  Buffer get buffer {
    screenReads++;
    return super.buffer;
  }
}

class _StaticSettings extends SettingsController {
  @override
  Settings build() => const Settings();
}
