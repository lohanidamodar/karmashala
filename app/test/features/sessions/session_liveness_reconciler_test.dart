import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/agents/application/agent_providers.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala/src/features/sessions/application/session_launcher.dart';
import 'package:karmashala/src/features/sessions/application/session_liveness_reconciler.dart';
import 'package:karmashala/src/features/sessions/application/session_signals.dart';
import 'package:karmashala_session/launch.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/settings/domain/settings.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/pane_lifecycle.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';
import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';
import '../../support/workspace_mirror.dart';
import '../../support/permission_fixtures.dart';
import '../terminal/fake_instance.dart';
import 'package:karmashala/src/features/sessions/data/sessions_data.dart';
import 'package:karmashala/src/features/sessions/application/session_providers.dart';

/// The owner: *"I've only 3 sessions running here, but in the sessions explorer
/// other sessions are also showing as running — for example the
/// github-validator session."*
///
/// Nothing in the app ever moved a row **out** of `running`. `SessionLauncher`
/// and `SessionAdoptionService` write it, `SessionEngine` writes the terminal
/// statuses and no in-app session uses it, and `SessionEngine.dispose`
/// deliberately leaves a run `running` on the way out. So the transition was
/// one-way and a conversation that ended three days ago went on claiming to be
/// live for ever.
const _agent = AgentDescriptor(
  id: 'demo',
  displayName: 'Demo Agent',
  binaries: AgentBinaries(windows: ['demo'], posix: ['demo']),
  launch: AgentLaunchSpec(permission: testPermissionSupport),
);

class _StaticSettings extends SettingsController {
  @override
  Settings build() => const Settings();
}

Future<({ProviderContainer container, AppDatabase db, FakeDataServer server})>
harness() async {
  final db = AppDatabase.memory();
  final server = FakeDataServer()..mirrorInto(db);
  server.environmentRows.upsert(windowsEnv());
  server.projectRows.insert(project());
  server.repositoryRows.insert(repository());
  server.installationRows.insert(agentInstallation(agentId: 'demo'));

  final container = ProviderContainer(
    overrides: [
      await server.override(),
      ...fakeTerminalOverrides(database: db),
      clockProvider.overrideWithValue(FixedClock(testTime)),
      idGeneratorProvider.overrideWithValue(SequentialIdGenerator('s-')),
      agentRegistryProvider.overrideWithValue(
        const AgentRegistry([DataOnlyAgentAdapter(_agent)]),
      ),
      settingsControllerProvider.overrideWith(_StaticSettings.new),
    ],
  );
  return (container: container, db: db, server: server);
}

void main() {
  group('the launch sweep', () {
    // Rows seeded at the server; the reconciler reads and writes the app's
    // copy, and a write lands in the copy at once.
    late FakeDataServer server;
    late SessionsData dao;

    setUp(() async {
      server = FakeDataServer();
      server.projectRows.insert(project());
      server.repositoryRows.insert(repository());
      dao = await sessionsOf(server);
    });

    test('a row left running by a previous run is no longer running', () {
      server.sessionRows.insert(
        session(id: 'old', status: SessionStatus.running),
      );

      expect(markSessionsLostOnLaunch(dao), 1);

      // Not `completed`, not `failed`, not `cancelled`: we did not see it end,
      // and each of those words asserts an ending nobody witnessed.
      expect(dao.getById('old')!.status, SessionStatus.unknown);
    });

    test('so is one left mid-turn as idle', () {
      server.sessionRows.insert(session(id: 'old', status: SessionStatus.idle));
      expect(markSessionsLostOnLaunch(dao), 1);
      expect(dao.getById('old')!.status, SessionStatus.unknown);
    });

    test('a row that already reached an ending keeps the word it earned', () {
      // The direction that matters: a user who stopped a session gets
      // `cancelled`, and a vaguer word written over it would lose the one fact
      // the app actually observed.
      for (final status in [
        SessionStatus.created,
        SessionStatus.completed,
        SessionStatus.failed,
        SessionStatus.cancelled,
      ]) {
        server.sessionRows.insert(session(id: status.name, status: status));
      }

      expect(markSessionsLostOnLaunch(dao), 0);

      for (final status in [
        SessionStatus.created,
        SessionStatus.completed,
        SessionStatus.failed,
        SessionStatus.cancelled,
      ]) {
        expect(dao.getById(status.name)!.status, status);
      }
    });

    // A tmux session over SSH: the launch pass had to call it `unknown` before
    // any pane existed; its pane reattaching is the observation that undoes
    // that. Without it a rename in the CLI never reached the row, because the
    // title sync only follows a session that is running.
    test('a row whose pane runs its agent again is running again', () {
      server.sessionRows.insert(
        session(
          id: 'hosted',
          status: SessionStatus.running,
        ).copyWith(paneId: 'pane-1'),
      );
      markSessionsLostOnLaunch(dao);
      expect(dao.getById('hosted')!.status, SessionStatus.unknown);

      final moved = SessionLivenessReconciler(sessionDao: dao).panesStarted({
        'pane-1',
      }, sessionOfPane: (paneId) => paneId == 'pane-1' ? 'hosted' : null);

      expect(moved, 1);
      expect(dao.getById('hosted')!.status, SessionStatus.running);
    });

    // A pane with no host facts that starts the same conversation again after
    // the row was settled `completed`: the agent is running again.
    test('a completed row whose pane runs its agent again is running', () {
      server.sessionRows.insert(
        session(
          id: 'resumed',
          status: SessionStatus.completed,
        ).copyWith(paneId: 'pane-1'),
      );

      final moved = SessionLivenessReconciler(
        sessionDao: dao,
      ).panesStarted({'pane-1'}, sessionOfPane: (_) => 'resumed');

      expect(moved, 1);
      expect(dao.getById('resumed')!.status, SessionStatus.running);
    });

    test('a pane running somebody else, or an archived row, is left alone', () {
      server.sessionRows.insert(
        session(
          id: 'old',
          status: SessionStatus.unknown,
        ).copyWith(paneId: 'pane-1'),
      );
      server.sessionRows.insert(
        session(
          id: 'shelved',
          status: SessionStatus.completed,
        ).copyWith(paneId: 'pane-2', archivedAt: testTime),
      );

      final moved = SessionLivenessReconciler(sessionDao: dao).panesStarted(
        {'pane-1', 'pane-2'},
        // pane-1 now runs a different session; pane-2's row was archived.
        sessionOfPane: (paneId) => paneId == 'pane-1' ? 'newer' : 'shelved',
      );

      expect(moved, 0);
      expect(dao.getById('old')!.status, SessionStatus.unknown);
      expect(dao.getById('shelved')!.status, SessionStatus.completed);
    });

    // A hosted row's status is its host's facts (host_lifecycle_test.dart):
    // neither pane edge may guess over them.
    test('a row that follows its host is moved by neither pane edge', () {
      server.sessionRows
        ..insert(
          session(
            id: 'hosted',
            status: SessionStatus.running,
          ).copyWith(paneId: 'pane-1'),
        )
        ..insert(
          session(
            id: 'ended',
            status: SessionStatus.completed,
          ).copyWith(paneId: 'pane-2'),
        );
      final reconciler = SessionLivenessReconciler(
        sessionDao: dao,
        followsHost: (_) => true,
      );

      expect(reconciler.panesStopped(const ['pane-1']), 0);
      expect(
        reconciler.panesStarted({'pane-2'}, sessionOfPane: (_) => 'ended'),
        0,
      );
      expect(dao.getById('hosted')!.status, SessionStatus.running);
      expect(dao.getById('ended')!.status, SessionStatus.completed);
    });

    test('the launch pass can be narrowed to rows no host speaks for', () {
      server.sessionRows
        ..insert(session(id: 'here', status: SessionStatus.running))
        ..insert(session(id: 'there', status: SessionStatus.running));

      expect(markSessionsLostOnLaunch(dao, where: (s) => s.id == 'there'), 1);
      expect(dao.getById('here')!.status, SessionStatus.running);
      expect(dao.getById('there')!.status, SessionStatus.unknown);
    });

    test('which panes started running, from one reading to the next', () {
      expect(
        panesThatStartedRunning(
          {'a': PaneLiveness.restored, 'b': PaneLiveness.live},
          {'a': PaneLiveness.live, 'b': PaneLiveness.live},
        ),
        {'a'},
      );
      expect(panesThatStartedRunning(null, {'a': PaneLiveness.live}), {'a'});
    });

    test('a live pane of ours is the one thing that keeps a claim', () {
      server.sessionRows.insert(
        session(
          id: 'here',
          status: SessionStatus.running,
        ).copyWith(paneId: 'pane-1'),
      );
      server.sessionRows.insert(
        session(
          id: 'gone',
          status: SessionStatus.running,
        ).copyWith(paneId: 'pane-2'),
      );

      final reconciler = SessionLivenessReconciler(sessionDao: dao);
      expect(reconciler.sweep({'pane-1'}), 1);

      expect(dao.getById('here')!.status, SessionStatus.running);
      expect(dao.getById('gone')!.status, SessionStatus.unknown);
    });

    test(
      'a session in somebody else\'s terminal is not assumed to be live',
      () {
        // `SessionSurface.external` is only a record of where it was *started*.
        // The app cannot see that window at all, so after a restart the honest
        // answer is that we do not know — never "still running".
        server.sessionRows.insert(
          session(
            id: 'out-there',
            status: SessionStatus.running,
          ).copyWith(surface: SessionSurface.external),
        );

        expect(markSessionsLostOnLaunch(dao), 1);
        expect(dao.getById('out-there')!.status, SessionStatus.unknown);
      },
    );
  });

  group('a pane that stops', () {
    test('only the rows it was hosting, and only live claims', () async {
      final server = FakeDataServer();
      server.sessionRows
        ..insert(
          session(
            id: 'in-pane',
            status: SessionStatus.running,
          ).copyWith(paneId: 'pane-1'),
        )
        ..insert(
          session(
            id: 'stopped',
            status: SessionStatus.cancelled,
          ).copyWith(paneId: 'pane-1'),
        )
        ..insert(
          session(
            id: 'elsewhere',
            status: SessionStatus.running,
          ).copyWith(paneId: 'pane-2'),
        );

      final dao = await sessionsOf(server);
      final moved = <String>[];
      final reconciler = SessionLivenessReconciler(
        sessionDao: dao,
        onChanged: moved.add,
      );
      expect(reconciler.panesStopped(const ['pane-1']), 1);

      expect(moved, ['in-pane']);
      expect(dao.getById('in-pane')!.status, SessionStatus.unknown);
      expect(dao.getById('stopped')!.status, SessionStatus.cancelled);
      expect(dao.getById('elsewhere')!.status, SessionStatus.running);
    });
  });

  group('the liveness diff', () {
    test('a first publish has nothing to compare against', () {
      expect(
        panesThatStoppedRunning(null, const {'a': PaneLiveness.live}),
        isEmpty,
      );
    });

    test('a process exiting counts, and so does the pane going away', () {
      expect(
        panesThatStoppedRunning(
          const {'a': PaneLiveness.live, 'b': PaneLiveness.live},
          const {'a': PaneLiveness.exited},
        ),
        {'a', 'b'},
      );
    });

    test('a pane that was never live has not stopped', () {
      // Restored history holds no process, so it cannot lose one — and a row
      // pointing at it was already moved by the launch sweep.
      expect(
        panesThatStoppedRunning(
          const {'a': PaneLiveness.restored},
          const {'a': PaneLiveness.exited},
        ),
        isEmpty,
      );
      expect(
        panesThatStoppedRunning(
          const {'a': PaneLiveness.live},
          const {'a': PaneLiveness.live},
        ),
        isEmpty,
      );
    });
  });

  group('wired to the terminal', () {
    test('a pane whose process dies stops claiming to run a session', () async {
      final (:container, :db, server: _) = await harness();
      addTearDown(container.dispose);
      addTearDown(db.close);
      // Exactly what `AppShell` does: watched, not read. Riverpod 3 pauses a
      // provider's own subscriptions while nothing listens to it, so a
      // reconciler nobody watches would hear no pane ever stop.
      container.listen(sessionLivenessReconcilerProvider, (_, _) {});

      final launched = await container
          .read(sessionLauncherProvider)
          .launch(
            SessionLaunchRequest(
              repository: repository(),
              installation: agentInstallation(agentId: 'demo'),
              title: 'Work',
              purpose: SessionPurpose.newSession,
            ),
          );
      // The app's copy: the reconciler's write lands there at once, and at
      // the server after.
      final dao = container.read(sessionsDataProvider);
      expect(dao.getById(launched.session.id)!.status, SessionStatus.running);

      final before = container.read(sessionSignalsProvider).revision;
      final instance =
          container
                  .read(terminalSessionsControllerProvider.notifier)
                  .instanceFor(launched.paneId!)!
              as FakeTerminalInstance;
      instance.livenessNotifier.value = PaneLiveness.exited;

      expect(dao.getById(launched.session.id)!.status, SessionStatus.unknown);
      await dao.settled();
      expect(
        serverOf(container).sessionRows.getById(launched.session.id)!.status,
        SessionStatus.unknown,
      );
      // And it is announced, so the Explorer card redraws rather than keeping
      // the play glyph until something else happens to wake it.
      expect(
        container.read(sessionSignalsProvider).revision,
        greaterThan(before),
      );
    });
  });

  group('what the new word means elsewhere', () {
    test('losing sight of a session is not an ending', () {
      // A restart turns every row that was still `running` into this word at
      // once. Reading it as an ending would raise a follow-up on launch for
      // every session that was open when the app last closed.
      expect(endingOfStatus(SessionStatus.unknown), isNull);
    });

    // An unreadable status word reading as `unknown` is the store's rule and
    // the wire's: packages/karmashala_session_engine/test/store/
    // session_dao_test.dart and packages/karmashala_session/test/
    // session_patch_test.dart.
  });
}
