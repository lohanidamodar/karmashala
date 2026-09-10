import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/explorer/application/session_diff_stat.dart';
import 'package:karmashala/src/features/git/application/changes_providers.dart';
import 'package:karmashala/src/features/git/application/checkout_probe_queue.dart';
import 'package:karmashala/src/features/follow_ups/application/follow_up_inbox.dart';
import 'package:karmashala/src/features/notifications/application/attention_inbox.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/session_resume_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala/src/features/terminal/application/scrollback_autosave.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import 'scale_harness.dart';

/// **The 100-session quiet soak.** One of the four benchmark gates
/// `docs/BACKLOG.md` carried as unbuilt, and the reason "not proven for
/// hundreds" was still literally true.
///
/// "Quiet" means *idle*. A hundred sessions and their panes exist, every pane
/// holds output, everything that was owed has been written — and then nothing
/// happens. Nobody types, nothing arrives from a process, no row changes. The
/// claim this pins is the one that decides whether the app can hold a hundred
/// sessions at all: **idle cost does not scale with the number of sessions.**
/// No per-session timer, no per-session poll, no rebuild fan-out.
///
/// **The soak is an hour long in app time and instant in wall time.** A gate
/// that sleeps for an hour is a gate nobody runs, and a gate that sleeps for
/// two seconds and calls itself a soak is worse than none. So the clock is
/// replaced rather than waited on: the autosave is the terminal's only periodic
/// timer, its idle cadence is [kScrollbackAutosaveInterval] (20 s), and the
/// schedule seam it already exposes for tests lets this file fire exactly
/// **180 ticks** — one hour — and count what they cost. Nothing here waits, so
/// nothing here flakes at `--concurrency=4`.
///
/// Units, all counted rather than timed, in the shape
/// `layout_save_cost_test` and `session_signal_cost_test` established:
///
/// * **database statements** — every SELECT, INSERT, UPDATE and DELETE the app
///   issues. Synchronous `package:sqlite3` on the UI isolate, so a statement is
///   main-isolate time.
/// * **buffer reads** — `Terminal.mainBuffer`, the scrollback codec's single
///   entry point, so this is the encode count.
/// * **republications** — whether the controller pushed a new state at all,
///   read by object identity. A publish is a rebuild of the tab strip and every
///   pane header.
/// * **outstanding timers** — how many callbacks the app has armed at once.
///
/// **What this gate does not cover, and why.** The panes are process-free, so
/// no PTY, no `PtyOutputCoalescer` timer and no real ingest — a pane with a
/// process arms a coalescer tick only when bytes arrive, and "quiet" means none
/// do. On the sessions side `agentSessionStatusProvider` is stubbed, because
/// the live one fans into `SessionStatusRegistry`, which stats transcript files
/// on a 1.2 s cycle; that cycle is a **disk** cost measured against a real
/// store by `tool/benchmark/periodic_tick_bench.dart`, and it is one timer for
/// the whole app rather than one per session. What is pinned here is the
/// provider graph and the database underneath it.
void main() {
  /// The three points the curve is read at. One is the "did we make the small
  /// case worse" control; a hundred is the scale target.
  const scale = [1, 10, 100];

  /// An hour of quiet, at the autosave's idle cadence.
  const soakTicks = 180;

  group('an idle terminal layout', () {
    /// Filled by the cases below so the *shape* can be asserted across them
    /// rather than inside any one of them.
    final statements = <int, int>{};
    final timers = <int, int>{};

    for (final panes in scale) {
      test('of $panes panes costs nothing over an hour', () {
        final layout = ScaleLayout();
        addTearDown(layout.dispose);
        layout.openPanes(panes);
        layout.settle();
        expect(
          layout.controller.hasDirtyScrollback,
          isFalse,
          reason: 'a layout nobody is typing into owes no writes',
        );

        final published = layout.state;
        layout.counting.reset();
        layout.schedule.delays.clear();
        for (final terminal in layout.terminalsByPane.values) {
          terminal.bufferReads = 0;
        }
        final armed = layout.schedule.pending;

        final ticks = layout.schedule.fireTimes(soakTicks);

        final reads = layout.terminalsByPane.values.fold(
          0,
          (sum, terminal) => sum + terminal.bufferReads,
        );
        statements[panes] = layout.counting.count;
        timers[panes] = armed;
        // ignore: avoid_print
        print(
          'QUIET-SOAK panes=$panes ticks=$ticks '
          'statements=${layout.counting.count} bufferReads=$reads '
          'timers=$armed republished=${!identical(layout.state, published)}',
        );

        expect(
          ticks,
          soakTicks,
          reason: 'the autosave stopped re-arming, so this was not an hour',
        );
        expect(
          layout.schedule.delays,
          everyElement(kScrollbackAutosaveInterval),
          reason: 'an idle tick must never ask for the catch-up cadence',
        );
        expect(
          layout.counting.statements,
          isEmpty,
          reason:
              'an hour of quiet must not touch the disk: '
              '${layout.counting.statements}',
        );
        expect(reads, 0, reason: 'nothing changed, so nothing may be encoded');
        expect(
          identical(layout.state, published),
          isTrue,
          reason: 'a quiet hour must not rebuild the tab strip once',
        );
        expect(
          layout.schedule.pending,
          armed,
          reason: 'the app must end the hour holding the timers it started it '
              'with',
        );
      });
    }

    test('and one timer covers a hundred panes as it covers one', () {
      expect(timers.keys, containsAll(scale));
      expect(
        timers.values.toSet(),
        orderedEquals([1]),
        reason:
            'the autosave is the terminal\'s only periodic timer, and there is '
            'one of it however many panes are open: $timers',
      );
    });

    test('so idle cost does not grow with the layout', () {
      expect(statements.keys, containsAll(scale));
      expect(
        statements.values.toSet(),
        orderedEquals([0]),
        reason: 'statements per idle hour: $statements',
      );
    });
  });

  group('an idle frame', () {
    /// Sixty frames — one second of a screen nobody is touching.
    const frames = 60;

    final statements = <int, int>{};

    for (final panes in scale) {
      test('over $panes panes reads no database', () {
        final layout = ScaleLayout();
        addTearDown(layout.dispose);
        layout.openPanes(panes);
        layout.settle();

        final published = layout.state;
        layout.counting.reset();

        // What the tab strip and every region header actually ask for, once
        // per frame. `_titles` is cleared on every publish, so this is only
        // free while nothing republishes — which is the claim.
        for (var frame = 0; frame < frames; frame++) {
          for (final tab in layout.state.tabs) {
            layout.controller.titleForTab(tab.id);
            for (final paneId in tab.layout.panes) {
              layout.controller.titleForPane(paneId);
            }
          }
        }

        statements[panes] = layout.counting.count;
        // ignore: avoid_print
        print(
          'QUIET-FRAMES panes=$panes frames=$frames '
          'statements=${layout.counting.count}',
        );
        expect(
          layout.counting.statements,
          isEmpty,
          reason:
              'naming a tab must not cost a query on a screen that has not '
              'changed: ${layout.counting.statements}',
        );
        expect(identical(layout.state, published), isTrue);
      });
    }

    test('costs the same at a hundred panes as at one', () {
      expect(statements.keys, containsAll(scale));
      expect(statements.values.toSet(), orderedEquals([0]), reason: '$statements');
    });
  });

  group('an idle session list', () {
    /// The layout `session_signal_cost_test` seeds, at the sizes this file
    /// reads the curve at. `s0` ended badly, so exactly one follow-up exists
    /// and the inbox has something to keep up to date.
    CountingDatabase seed(int count) {
      final db = CountingDatabase();
      ExecutionEnvironmentDao(db).upsert(windowsEnv());
      ProjectDao(db).insert(project());
      RepositoryDao(db).insert(repository());
      AgentInstallationDao(db).insert(agentInstallation());
      for (var i = 0; i < count; i++) {
        SessionDao(db).insert(
          session(
            id: 's$i',
            title: 'Session $i',
            status: i == 0 ? SessionStatus.failed : SessionStatus.running,
          ),
        );
      }
      return db;
    }

    ProviderContainer mount(CountingDatabase db, FakeCommandRunner git) {
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          clockProvider.overrideWithValue(FixedClock(testTime)),
          // Stubbed for the reason the file header gives: the live one fans
          // into the transcript-stat cycle, which is a disk measurement and
          // belongs to `periodic_tick_bench.dart`.
          agentSessionStatusProvider.overrideWith(
            (ref, id) => const Stream<AgentStatusReport>.empty(),
          ),
          commandRunnerFactoryProvider.overrideWithValue(
            FakeCommandRunnerFactory(fallback: git),
          ),
          probeGateProvider.overrideWithValue(headlessProbeGate),
          gitFilesProvider.overrideWithValue(noGitFiles),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    /// Everything an ordinary screen has watching the session list, subscribed
    /// the way the widgets that own them subscribe.
    void listenToEverything(ProviderContainer container, int count) {
      container.read(selectedRepositoryIdProvider.notifier).select('r1');
      container.listen(attentionInboxProvider, (_, _) {});
      container.listen(sessionProjectIdsProvider, (_, _) {});
      container.listen(projectSummaryProvider('p1'), (_, _) {});
      container.listen(openFollowUpsProvider, (_, _) {});
      container.listen(sessionsForSelectedRepositoryProvider, (_, _) {});
      container.listen(importedSessionsForSelectedRepositoryProvider, (_, _) {});
      // One per drawn row: the Explorer builds a card per session.
      for (var i = 0; i < count; i++) {
        container.listen(sessionWhereaboutsProvider('s$i'), (_, _) {});
      }
    }

    final statements = <int, int>{};
    final spawns = <int, int>{};

    for (final count in scale) {
      test('of $count sessions reads nothing while nothing changes', () async {
        final db = seed(count);
        addTearDown(db.close);
        final git = FakeCommandRunner();
        final container = mount(db, git);
        listenToEverything(container, count);
        await container.pump();

        db.reset();
        git.requests.clear();

        // A second of frames over a screen where no row moved. Everything is
        // re-read the way a rebuilding widget re-reads it.
        for (var frame = 0; frame < 60; frame++) {
          container.read(attentionInboxProvider);
          container.read(sessionProjectIdsProvider);
          container.read(projectSummaryProvider('p1'));
          container.read(openFollowUpsProvider);
          container.read(sessionsForSelectedRepositoryProvider);
          container.read(importedSessionsForSelectedRepositoryProvider);
          for (var i = 0; i < count; i++) {
            container.read(sessionWhereaboutsProvider('s$i'));
          }
        }
        // And a turn of the event loop, in case anything armed itself behind
        // the reads.
        await container.pump();

        statements[count] = db.count;
        spawns[count] = git.requests.length;
        // ignore: avoid_print
        print(
          'QUIET-SESSIONS sessions=$count statements=${db.count} '
          'processes=${git.requests.length}',
        );
        expect(
          db.statements,
          isEmpty,
          reason:
              'a session list nobody touched must not re-query: '
              '${db.statements}',
        );
        expect(
          git.requests,
          isEmpty,
          reason: 'an idle session must not start a process',
        );
      });
    }

    test('so a hundred idle sessions cost what one does', () {
      expect(statements.keys, containsAll(scale));
      expect(statements.values.toSet(), orderedEquals([0]), reason: '$statements');
      expect(spawns.values.toSet(), orderedEquals([0]), reason: '$spawns');
    });
  });
}
