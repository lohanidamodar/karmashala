import 'package:karmashala/src/core/data/data_client.dart';
import 'package:karmashala/src/core/data/data_providers.dart';
import 'package:karmashala_store/database.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala_core/util.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/notifications/application/notification_providers.dart';
import 'package:karmashala/src/features/sessions/application/delivery_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_handoff_service.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session/launch.dart';
import 'package:karmashala/src/features/sessions/presentation/delivery_strip.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_data_server.dart';
import '../../support/workspace_mirror.dart';
import '../../support/fake_command_runner.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';

/// What losing and regaining window focus costs.
///
/// Reported as *"karmashala terminal flickers when i'm switching workspace in
/// glazewm"*, then narrowed by the owner to focus itself: alt-tab away and
/// back and the strip under the terminal blinks. A tiling window manager
/// crosses that boundary dozens of times a minute.
///
/// Two separate faults met here, and the tests below keep them apart.
///
/// **The blink** is `AsyncValue.asData`, which is null for an `AsyncLoading` —
/// *including* the loading state of a refresh that is still carrying its
/// previous value. So a refresh of `sessionDeliveryProvider` made the strip
/// draw as though it had never known anything: the state line vanished, the
/// column got shorter, and everything laid out above it moved.
///
/// **The storm** is `DeliveryPollController`, which bumps its revision on every
/// focus regain. The intent is right — coming back to the app should show
/// current state rather than what it knew before lunch — but unrated it turns
/// one alt-tab into a git-and-`gh` pass, and twenty alt-tabs into twenty.
/// A clock the test moves, so the focus rate limit can be crossed deliberately
/// rather than by waiting.
class _MovableClock implements Clock {
  _MovableClock(this.now);
  DateTime now;
  @override
  DateTime nowUtc() => now.toUtc();
}

class _SlowRunner extends FakeCommandRunner {
  _SlowRunner({required super.responder});

  /// Long enough that a refresh is observable between two pumps. The point is
  /// to see the frame the user sees, not to simulate a slow disk.
  static const delay = Duration(milliseconds: 50);

  @override
  Future<CommandResult> run(CommandRequest request) async {
    // Recorded first, delayed second, so a test can see that a refresh has
    // *started* before it has answered — which is the frame the user sees.
    final result = await super.run(request);
    await Future<void>.delayed(delay);
    return result;
  }
}

void main() {
  late AppDatabase db;
  late FakeDataServer server;
  late DataClient data;
  late List<List<String>> ghCalls;
  late List<List<String>> gitCalls;
  late _MovableClock clock;

  const worktree = EnvironmentPath(
    environmentId: 'windows',
    path: r'C:\src\.karmashala-worktrees\app-s1',
  );

  setUp(() async {
    ghCalls = [];
    gitCalls = [];
    clock = _MovableClock(testTime);
    db = AppDatabase.memory();
    server = FakeDataServer()..mirrorInto(db);
    data = await server.connect();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    AgentInstallationDao(db).insert(agentInstallation());
    mirroredServer(db).sessionRows.insert(
      Session(
        id: 's1',
        repositoryId: 'r1',
        agentInstallationId: 'a1',
        title: 'Fix the login',
        useWorktree: true,
        worktree: worktree,
        status: SessionStatus.running,
        createdAt: testTime,
      ),
    );
  });
  tearDown(() => db.close());

  CommandResult respond(CommandRequest request) {
    if (request.executable == 'gh') {
      ghCalls.add(request.arguments);
      return const CommandResult(
        exitCode: 1,
        stdout: '',
        stderr: 'no pull requests found for branch "work"',
      );
    }
    gitCalls.add(request.arguments);
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

  final noContinuation = SessionContinuation(
    targets: const [],
    plan: SessionForkPlan.decide(descriptor: null, agentName: 'Test CLI'),
  );

  /// Lets the faked git and `gh` answer.
  ///
  /// `pumpAndSettle` alone is not enough: nothing here schedules frames, so it
  /// returns without advancing the clock past the runner's delay.
  Future<void> drain(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
  }

  /// The real delivery providers behind a real strip, with git and `gh` faked
  /// and slow. Returns the container, so a test can move focus the way
  /// `SystemIntegrationService` does.
  Future<ProviderContainer> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          dataClientProvider.overrideWithValue(data),
          ...fakeTerminalOverrides(database: db),
          clockProvider.overrideWithValue(clock),
          commandRunnerFactoryProvider.overrideWithValue(
            FakeCommandRunnerFactory(fallback: _SlowRunner(responder: respond)),
          ),
          sessionContinuationProvider.overrideWith((ref, _) => noContinuation),
        ],
        child: const MaterialApp(
          home: Scaffold(body: DeliveryStrip(sessionId: 's1')),
        ),
      ),
    );
    await drain(tester);
    return ProviderScope.containerOf(
      tester.element(find.byType(DeliveryStrip)),
    );
  }

  void setFocus(ProviderContainer container, {required bool focused}) =>
      container.read(windowFocusedProvider.notifier).set(focused);

  testWidgets('regaining focus does not blank the strip', (tester) async {
    final container = await pump(tester);
    final settled = tester.getSize(find.byType(DeliveryStrip));
    final before = ghCalls.length;
    expect(
      find.text('work'),
      findsOneWidget,
      reason: 'the state line is drawn',
    );

    // Past the rate limit, so this is a real refresh and not a suppressed one:
    // the blink has to be gone even when the re-read genuinely happens.
    setFocus(container, focused: false);
    clock.now = clock.now.add(kDeliveryFocusRefreshInterval);
    setFocus(container, focused: true);

    // The frame the user sees: the refresh has started and has not answered.
    await tester.pump();
    // The local half is not re-read by a poll — only the pull request is — so
    // it is `gh` that grows here, and git that does not.
    expect(ghCalls.length, greaterThan(before), reason: 'it really refreshed');

    expect(
      tester.getSize(find.byType(DeliveryStrip)).height,
      settled.height,
      reason:
          'the strip must not change height while it refreshes — '
          'everything laid out around it moves when it does',
    );
    expect(
      find.text('work'),
      findsOneWidget,
      reason: 'a refresh knows the previous answer; it must keep showing it',
    );

    await drain(tester);
    expect(tester.getSize(find.byType(DeliveryStrip)).height, settled.height);
  });

  testWidgets('a flurry of focus changes costs one refresh', (tester) async {
    final container = await pump(tester);
    final before = ghCalls.length;
    expect(before, 1, reason: 'the first read asked gh once');

    // A workspace switch away and back, ten times, faster than any of it can
    // answer — which is what a tiling window manager produces.
    for (var i = 0; i < 10; i++) {
      setFocus(container, focused: false);
      setFocus(container, focused: true);
      await tester.pump(const Duration(milliseconds: 5));
    }
    await drain(tester);

    expect(
      ghCalls.length - before,
      lessThanOrEqualTo(1),
      reason: 'ten alt-tabs inside one window must coalesce into one refresh',
    );
  });

  testWidgets('a focus regain long after the last read does refresh', (
    tester,
  ) async {
    // The behaviour the rate limit must not lose: come back to the app after a
    // while and it shows current state rather than what it knew before lunch.
    final container = await pump(tester);
    final before = ghCalls.length;

    setFocus(container, focused: false);
    clock.now = clock.now.add(kDeliveryFocusRefreshInterval);
    setFocus(container, focused: true);
    await drain(tester);

    expect(ghCalls.length - before, 1);
  });
}
