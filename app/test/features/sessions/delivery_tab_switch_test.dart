import 'package:karmashala/src/core/data/data_client.dart';
import 'package:karmashala/src/core/data/data_providers.dart';
import 'package:karmashala/src/app/shell/workbench.dart';
import 'package:karmashala_store/database.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/sessions/application/session_handoff_service.dart';
import 'package:karmashala/src/features/sessions/application/session_notice.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session/launch.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:karmashala/src/features/terminal/presentation/terminal_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm2/xterm.dart';

import '../../support/fake_data_server.dart';
import '../../support/workspace_mirror.dart';
import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';

/// What switching terminal tabs costs the terminal.
///
/// The owner's report is *"the terminal blinks when switching tabs — I thought
/// we fixed this"*, and they are half right. `a01cd1f7` fixed the blink a
/// **focus** change caused, where `AsyncValue.asData` threw away the value a
/// refresh was still carrying; `delivery_focus_test.dart` pins that. This is
/// the other half, and that fix cannot reach it: a tab switch switches
/// *session*, so every provider under the session bar is a different family key
/// with no previous value to carry, and `sessionDeliveryProvider` is
/// `autoDispose` besides. The bar genuinely knows nothing about the session it
/// has just been handed.
///
/// So the facts line takes itself away, the delivery actions fold to the "could
/// not tell" set and stop wrapping, and the bar drops to its floor. The
/// terminal above it is `Expanded`, so it takes those pixels, resizes its
/// character grid and reflows — and then git and `gh` answer and it all happens
/// again in reverse. **Two reflows per tab switch**, at every window size.
///
/// Measured here before the reservation, one switch between two sessions with
/// identical delivery:
///
/// | window | bar            | terminal rows | grid resizes |
/// |--------|----------------|---------------|--------------|
/// | 1400px | 51 → 31 → 51   | 50 → 51 → 50  | 2 |
/// | 900px  | 79 → 57 → 79   | 48 → 49 → 48  | 2 |
/// | 800px  | 99 → 57 → 99   | 47 → 49 → 47  | 2 |
/// | 720px  | 127 → 57 → 127 | 45 → 49 → 45  | 2 |
///
/// 720px is the narrowest window the app supports, and there the bar loses
/// **70px** — the same order as the 74px the focus blink cost. Both terms move
/// there: the facts line (42px, two runs) and the action strip (80px → 52px,
/// three runs down to two), which is why the fix reserves the *bar's* height
/// rather than teaching either child to hold its own.
///
/// The grid is the unit rather than the pixel height because it is what the
/// process is told and therefore what reflows: `window_resize_test.dart` pins
/// that the grid a pane is told is the grid it is drawn in, so a row that moves
/// here is a row that moves on screen.
void main() {
  late AppDatabase db;
  late FakeDataServer server;
  late DataClient data;
  late ProviderContainer container;

  EnvironmentPath worktreeFor(String id) => EnvironmentPath(
    environmentId: 'windows',
    path: r'C:\src\.karmashala-worktrees\app-' + id,
  );

  CommandResult respond(CommandRequest request) {
    if (request.executable == 'gh') {
      return const CommandResult(
        exitCode: 1,
        stdout: '',
        stderr: 'no pull requests found for branch "work"',
      );
    }
    final args = request.arguments;
    if (args.contains('status')) {
      return CommandResult(
        exitCode: 0,
        stdout: porcelainV2(
          branch: 'work',
          upstream: 'origin/work',
          ahead: 2,
          behind: 0,
          modified: ['lib/a.dart'],
        ),
        stderr: '',
      );
    }
    if (args.contains('get-url')) {
      return const CommandResult(
        exitCode: 0,
        stdout: 'git@github.com:popupbits/app.git\n',
        stderr: '',
      );
    }
    if (args.contains('origin/HEAD')) {
      return const CommandResult(
        exitCode: 0,
        stdout: 'origin/main\n',
        stderr: '',
      );
    }
    if (args.contains('rev-list')) {
      return const CommandResult(exitCode: 0, stdout: '0\t2\n', stderr: '');
    }
    if (args.contains('--numstat')) {
      return const CommandResult(
        exitCode: 0,
        stdout: '30\t4\tlib/a.dart\n',
        stderr: '',
      );
    }
    return const CommandResult(exitCode: 0, stdout: '', stderr: '');
  }

  /// Slow enough that the frames between "you switched" and "git answered" are
  /// observable. It is those frames the bar has to survive, so a runner that
  /// answered inside one pump would hide the whole subject.
  final runner = _SlowRunner(responder: respond);

  final noContinuation = SessionContinuation(
    targets: const [],
    plan: SessionForkPlan.decide(descriptor: null, agentName: 'Test CLI'),
  );

  setUp(() async {
    db = AppDatabase.memory();
    server = FakeDataServer()..mirrorInto(db);
    data = await server.connect();
    server.environmentRows.upsert(windowsEnv());
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    server.installationRows.insert(agentInstallation());
    for (final id in ['s1', 's2']) {
      mirroredServer(db).sessionRows.insert(
        Session(
          id: id,
          repositoryId: 'r1',
          agentInstallationId: 'a1',
          title: 'Session $id',
          useWorktree: true,
          worktree: worktreeFor(id),
          status: SessionStatus.running,
          createdAt: testTime,
          externalSessionId: 'ext-$id',
        ),
      );
    }
    container = ProviderContainer(
      overrides: [
        dataClientProvider.overrideWithValue(data),
        ...fakeTerminalOverrides(database: db),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(fallback: runner),
        ),
        // Real hosts and a real fork plan are not this file's subject, and the
        // service behind them reads the filesystem.
        sessionContinuationProvider.overrideWith((ref, _) => noContinuation),
      ],
    );
    addTearDown(container.dispose);
  });
  tearDown(() => db.close());

  /// Lets the faked git and `gh` answer. `pumpAndSettle` cannot be used against
  /// the workbench — something always has a frame scheduled — and the delays
  /// chain, so this is a fixed run of frames long enough to drain them.
  Future<void> drain(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 1));
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// Two terminal tabs, one session each, both already looked at once — so
  /// neither side of a measurement is the first-ever look at a session.
  Future<List<String>> mount(
    WidgetTester tester, {
    required double width,
  }) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));

    final controller = container.read(
      terminalSessionsControllerProvider.notifier,
    );
    final tabs = <String>[];
    for (final id in ['s1', 's2']) {
      controller.openTab(TerminalProfile.powerShell);
      final tab = container.read(terminalSessionsControllerProvider).activeTab!;
      tabs.add(tab.id);
      mirroredServer(db).sessionRows.updatePaneId(id, tab.layout.panes.single);
    }
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: WorkbenchView())),
      ),
    );
    // Mounting lands on the second tab; drain it, then land back on the first
    // and drain that, so both sessions have been read before anything is
    // measured. A first look is allowed to change the layout — it is the only
    // moment the app has honestly learned something.
    await drain(tester);
    controller.activateTab(tabs.first);
    await drain(tester);
    return tabs;
  }

  /// The session bar's height: what the workbench keeps below the terminal.
  double barHeight(WidgetTester tester) =>
      tester.getRect(find.byType(WorkbenchView)).bottom -
      tester.getRect(find.byType(TerminalPaneStack)).bottom;

  /// Every pane's terminal, with a counter on the grid it is told.
  ({Map<String, int> resizes, Map<String, List<int>> rows}) watchGrids() {
    final controller = container.read(
      terminalSessionsControllerProvider.notifier,
    );
    final resizes = <String, int>{};
    final rows = <String, List<int>>{};
    for (final tab in container.read(terminalSessionsControllerProvider).tabs) {
      final paneId = tab.layout.panes.single;
      final Terminal terminal = controller.instanceFor(paneId)!.terminal;
      resizes[paneId] = 0;
      rows[paneId] = [terminal.viewHeight];
      terminal.onResize = (_, height, _, _) {
        resizes[paneId] = resizes[paneId]! + 1;
        rows[paneId]!.add(height);
      };
    }
    return (resizes: resizes, rows: rows);
  }

  // 1400px is a comfortable window and the actions fit on one run; 720px is the
  // narrowest the app supports, where they wrap to three and the facts to two.
  // The bug is the same at both, and so must the fix be.
  for (final width in <double>[1400, 720]) {
    testWidgets('switching tabs resizes no terminal grid, at ${width}px', (
      tester,
    ) async {
      final tabs = await mount(tester, width: width);
      final controller = container.read(
        terminalSessionsControllerProvider.notifier,
      );
      final grids = watchGrids();
      final before = barHeight(tester);

      controller.activateTab(tabs[1]);
      await tester.pump();

      // The frame the user sees: the switch has happened and nothing has been
      // read yet, so the facts line and half the actions are not there to draw.
      expect(
        barHeight(tester),
        before,
        reason:
            'the bar must keep its height while it is being told what this '
            'session is — the terminal above it is Expanded, so every pixel it '
            'gives back resizes the character grid and reflows the screen',
      );

      await drain(tester);

      // Every *mounted* pane, not only the visible one: the tab stack lays out
      // the bounded set it keeps alive, so one switch used to cost a grid
      // resize per live tab.
      expect(
        grids.resizes.values,
        everyElement(0),
        reason:
            'a tab switch is not a resize: rows went ${grids.rows}, '
            'bar $before → ${barHeight(tester)}',
      );
    });
  }

  testWidgets('the reservation is given back once the session has answered', (
    tester,
  ) async {
    // The other half of the rule, and the guard against a false green: a bar
    // that simply never changed height would pass the tests above and would be
    // its own bug — dead chrome under every session, for ever.
    //
    // The asymmetry is a [SessionNotice], which is per-session, synchronous and
    // has nothing to do with delivery: it makes `s1`'s bar taller than `s2`'s
    // for a reason the reservation knows nothing about, which is also the point
    // — the *bar's* height is held, not the delivery strip's, so a neighbour in
    // the same row is covered by the same fix.
    final tabs = await mount(tester, width: 720);
    final controller = container.read(
      terminalSessionsControllerProvider.notifier,
    );
    container
        .read(sessionNoticesProvider.notifier)
        .post('s1', const SessionNotice(message: 'Applies on the next launch'));
    await tester.pump();
    final withNotice = barHeight(tester);
    // Counted from here, so the notice's own arrival is not one of them.
    final grids = watchGrids();

    controller.activateTab(tabs[1]);
    await tester.pump();
    expect(
      barHeight(tester),
      withNotice,
      reason: 'held while the new session is being read',
    );

    await drain(tester);

    expect(
      barHeight(tester),
      lessThan(withNotice),
      reason:
          'this session has no notice, and a reservation that was never given '
          'back would leave a band of empty bar under every session that says '
          'less than the one before it',
    );
    expect(
      grids.resizes.values,
      everyElement(1),
      reason:
          'one resize, at the moment the app actually learned something — not '
          'two, and not none: rows went ${grids.rows}',
    );
  });

  testWidgets('a window resize during a read gets no stale reservation', (
    tester,
  ) async {
    // The reservation is an answer to a layout question — how tall is this bar
    // *at this width* — so it may not outlive the width it was measured at. A
    // drag that reaches a new width while a session is still being read has to
    // lay the bar out for the width it is now.
    final tabs = await mount(tester, width: 720);
    final controller = container.read(
      terminalSessionsControllerProvider.notifier,
    );
    final narrow = barHeight(tester);

    controller.activateTab(tabs[1]);
    await tester.pump();
    expect(barHeight(tester), narrow);

    tester.view.physicalSize = const Size(1400, 900);
    await tester.pump();
    expect(
      barHeight(tester),
      lessThan(narrow),
      reason:
          'a 720px bar wraps to three runs of actions; carrying that height '
          'into a 1400px window would be a guess, and a wrong one',
    );

    await drain(tester);
    // ...and the wide window's own answer is what it settles on.
    final settled = barHeight(tester);
    await tester.pump();
    expect(barHeight(tester), settled);
  });
}

/// A runner slow enough that a read is observable between two pumps.
class _SlowRunner extends FakeCommandRunner {
  _SlowRunner({required super.responder});

  static const delay = Duration(milliseconds: 50);

  @override
  Future<CommandResult> run(CommandRequest request) async {
    final result = await super.run(request);
    await Future<void>.delayed(delay);
    return result;
  }
}
