import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/automations/application/automation_scheduler.dart';
import 'package:karmashala/src/features/automations/application/automation_timer.dart';
import 'package:karmashala/src/features/git/application/worktree_cleanup_policy.dart';
import 'package:karmashala/src/features/git/application/worktree_cleanup_providers.dart';
import 'package:karmashala/src/features/git/application/worktree_cleanup_service.dart';
import 'package:karmashala_projects/karmashala_projects.dart';
import 'package:karmashala_git/git.dart';

import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';

/// Cleanup rides the automations' one timer: nothing is armed for it while it
/// is off, turning it on arms that timer (after a settle), and a fire sweeps
/// once and re-arms for the next interval.
void main() {
  late MovableClock clock;
  late ManualAutomationTimer timer;
  late ProviderContainer container;
  late int sweeps;

  setUp(() async {
    clock = MovableClock(DateTime.utc(2026, 9, 21, 9));
    timer = ManualAutomationTimer();
    sweeps = 0;
    container = ProviderContainer(
      overrides: [
        await FakeDataServer(clock: () => clock.nowUtc()).override(),
        clockProvider.overrideWithValue(clock),
        automationTimerProvider.overrideWithValue(timer),
        // A sweep that finds no projects: what is under test is *when* it
        // runs, and the count of times `projects` is asked is that.
        worktreeCleanupServiceProvider.overrideWithValue(
          WorktreeCleanupService(
            projects: () {
              sweeps++;
              return const <Project>[];
            },
            repositoriesOf: (_) => const [],
            presenceOf: (_) async => GitPresence.unknown,
            familyKeyOf: (_) async => null,
            environmentKind: (_) => null,
            gitFor: (_) => throw StateError('no git in this test'),
            removeIfClean: (_, _) => throw StateError('nothing to remove'),
            sessions: () => const [],
            isLive: (_) => false,
            liveTerminalDirectories: () => const [],
            lastEventAt: (_) async => null,
            createdAt: (_) => null,
            clock: clock,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
  });

  void watchScheduler() =>
      container.listen(automationSchedulerProvider, (_, _) {});

  WorktreeCleanupController controller() =>
      container.read(worktreeCleanupControllerProvider);

  test(
    'off: the timer is not armed for cleanup, and a tick sweeps nothing',
    () async {
      watchScheduler();
      await pumpEventQueue();

      expect(timer.isArmed, isFalse);
      clock.advance(const Duration(days: 3));
      await container.read(automationSchedulerProvider.notifier).reconcile();
      await pumpEventQueue();
      expect(sweeps, 0);
      expect(container.read(worktreeCleanupLastSweepProvider), isNull);
    },
  );

  test('turning it on arms the one timer for after the settle; the fire '
      'sweeps once and re-arms for the next interval', () async {
    watchScheduler();
    await pumpEventQueue();
    clock.advance(const Duration(hours: 1));

    controller().save(const WorktreeCleanupSettings(enabled: true));
    await pumpEventQueue();

    expect(timer.isArmed, isTrue);
    expect(timer.armedFor, kWorktreeCleanupSettleAfterChange);

    // Early: a reconcile before it is due starts nothing.
    await container.read(automationSchedulerProvider.notifier).reconcile();
    await pumpEventQueue();
    expect(sweeps, 0);

    clock.advance(kWorktreeCleanupSettleAfterChange);
    timer.fire();
    await pumpEventQueue();

    expect(sweeps, 1);
    final last = container.read(worktreeCleanupLastSweepProvider)!;
    expect(last.automatic, isTrue);
    expect(last.finishedAt, isNotNull);
    expect(timer.isArmed, isTrue);
    expect(timer.armedFor, kWorktreeCleanupInterval);
  });

  test('a launch waits before its first sweep, however overdue', () async {
    // Settings saved long ago, never swept: overdue by days.
    controller().save(const WorktreeCleanupSettings(enabled: true));
    clock.advance(const Duration(days: 5));
    watchScheduler();
    await pumpEventQueue();

    expect(sweeps, 0);
    expect(timer.armedFor, kWorktreeCleanupSettleAfterLaunch);
  });

  test('a sweep already running is joined, not doubled', () async {
    final first = controller().sweep(automatic: false);
    final second = controller().sweep(automatic: true);
    await Future.wait([first, second]);
    expect(sweeps, 1);
    expect(identical(await first, await second), isTrue);
  });
}
