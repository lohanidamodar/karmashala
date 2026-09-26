import 'package:karmashala/src/core/data/data_client.dart';
import 'package:karmashala/src/core/data/data_providers.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/agents/application/agent_providers.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:karmashala/src/features/mcp/session_launch_tools.dart';
import 'package:karmashala/src/features/mcp/session_tools.dart';
import 'package:karmashala/src/features/sessions/application/host_lifecycle/host_lifecycle_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_launcher.dart';
import 'package:karmashala/src/features/sessions/application/session_working_directory.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/settings/domain/settings.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_session/launch.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';
import 'package:karmashala_terminal_runtime/instances.dart'
    show hostSessionIdFor;

import '../../support/fake_data_server.dart';
import '../../support/test_machine.dart';
import '../../support/fake_host_lifecycle.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';
import 'package:karmashala/src/features/sessions/data/sessions_data.dart';
import 'package:karmashala/src/features/sessions/application/session_providers.dart';

class _StaticSettings extends SettingsController {
  @override
  Settings build() => const Settings();
}

Future<void> _settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// A session the daemon started while the app was closed: the host runs it
/// under `karmashala_<row id>`, and no pane of this app shows it. Opening it
/// attaches a pane to that session — never a second agent, never a resume of
/// a conversation the agent may not have written yet.
void main() {
  late TestMachine db;
  late FakeDataServer server;
  late DataClient data;
  late FakeSessionRows dao;
  late FakeHostLifecycle host;
  late ProviderContainer container;
  late List<String> presenceAsked;
  late ConversationPresence presence;
  late List<String> endedAtHost;

  setUp(() async {
    db = TestMachine();
    server = FakeDataServer()..runsOn(db);
    data = await server.connect();
    server.environmentRows.upsert(windowsEnv());
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    server.installationRows.insert(agentInstallation());
    dao = server.sessionRows;
    // Writes nothing: what the rows say is set by each test, so a write by
    // the app is the only thing that could change them.
    host = FakeHostLifecycle();
    presenceAsked = [];
    presence = ConversationPresence.absent;
    endedAtHost = [];
    container = ProviderContainer(
      overrides: [
        dataClientProvider.overrideWithValue(data),
        ...fakeTerminalOverrides(machine: db),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        idGeneratorProvider.overrideWithValue(SequentialIdGenerator('s-')),
        agentRegistryProvider.overrideWithValue(AgentRegistry.builtIn),
        settingsControllerProvider.overrideWith(_StaticSettings.new),
        sessionDirectoryPresentProvider.overrideWithValue((_) => true),
        hostLifecycleSourceProvider.overrideWithValue(host),
        hostedSessionEnderProvider.overrideWithValue((sessionId) async {
          endedAtHost.add(sessionId);
        }),
        conversationPresenceProvider.overrideWithValue(({
          required descriptor,
          required environmentId,
          required conversationId,
        }) async {
          presenceAsked.add(conversationId);
          return presence;
        }),
      ],
    );
    addTearDown(() {
      container.dispose();
    });
  });

  /// The rows as this app holds them — where its own writes land at once.
  SessionsData rows() => container.read(sessionsDataProvider);

  /// What the daemon's launcher writes: a running row naming its own id as
  /// its conversation, which Claude has not written a line of yet.
  void daemonRow(String id) {
    dao.insert(
      session(id: id, title: 'daemon e2e once', status: SessionStatus.running),
    );
    dao.updateExternalSessionId(id, id);
  }

  Future<void> hostHolds(List<SessionFacts> facts) async {
    host.snapshot = facts;
    container.listen(hostLifecycleSubscriberProvider, (_, _) {});
    await _settle();
  }

  TerminalSessionsController terminals() =>
      container.read(terminalSessionsControllerProvider.notifier);

  Future<Object?> openSession(String id) =>
      SessionLaunchTools(container).call('open_session', {'id': id});

  group('the host runs it and no pane shows it', () {
    test('open_session attaches a pane to the host session: no resume, no '
        'spawn, no status written', () async {
      daemonRow('d1');
      await hostHolds([hostFacts('d1', HostSessionState.running)]);

      final result = await openSession('d1') as Map<String, Object?>;

      expect(result['reattached'], isTrue);
      expect(result['sessionId'], 'd1');
      // Never asked whether the conversation exists: nothing was resumed.
      expect(presenceAsked, isEmpty);
      final row = rows().getById('d1')!;
      expect(row.status, SessionStatus.running);
      expect(row.paneId, isNotNull);
      // The pane is the row's own — its host session is `karmashala_d1`, the
      // one the daemon started — so the host attaches it rather than opening.
      final pane = terminals().instanceFor(row.paneId!)!;
      expect(pane.agentLaunch!.sessionId, 'd1');
      expect(
        hostSessionIdFor(paneId: row.paneId!, agentSessionId: 'd1'),
        hostSessionIdOf('d1'),
      );
      // Its command line is the row's resume, used only if the session ended
      // between the check and the attach — never a new conversation.
      expect(
        pane.agentLaunch!.arguments,
        containsAllInOrder(['--resume', 'd1']),
      );
      // One pane, and afterwards it is simply the session's live pane.
      final launcher = container.read(sessionLauncherProvider);
      expect(launcher.livePaneFor('d1'), row.paneId);
      expect(launcher.heldByHostOnly('d1'), isFalse);
      final again = await openSession('d1') as Map<String, Object?>;
      expect(again['reattached'], isTrue);
      expect(terminals().state.tabs, hasLength(1));
    });

    test('a resume launch from any surface attaches too', () async {
      daemonRow('d1');
      await hostHolds([hostFacts('d1', HostSessionState.running)]);

      final launched = await container
          .read(sessionLauncherProvider)
          .launch(
            SessionLaunchRequest(
              repository: repository(),
              installation: agentInstallation(),
              title: 'daemon e2e once',
              purpose: SessionPurpose.existingSession,
              resumeExternalSessionId: 'd1',
            ),
          );

      expect(launched.session.id, 'd1');
      expect(presenceAsked, isEmpty);
      expect(rows().getAll(), hasLength(1));
      expect(rows().getById('d1')!.status, SessionStatus.running);
    });

    test('session_end asks the host to end it, and writes no status', () async {
      daemonRow('d1');
      await hostHolds([hostFacts('d1', HostSessionState.running)]);

      final result =
          await SessionControlTools(
                container,
              ).call('session_end', {'sessionId': 'd1'})
              as Map<String, Object?>;

      expect(result['ended'], isTrue);
      expect(result.containsKey('paneId'), isFalse);
      expect(endedAtHost, ['d1']);
      expect(rows().getById('d1')!.status, SessionStatus.running);
      // Asked to end, so nothing attaches to it while the host finishes.
      expect(
        container.read(sessionLauncherProvider).heldByHostOnly('d1'),
        isFalse,
      );
    });
  });

  group('the host does not hold it', () {
    test('open_session falls through to the resume', () async {
      daemonRow('d1');
      presence = ConversationPresence.present;
      await hostHolds(const []);

      final result = await openSession('d1') as Map<String, Object?>;

      expect(result['reattached'], isFalse);
      expect(presenceAsked, ['d1']);
      final pane = terminals().instanceFor(rows().getById('d1')!.paneId!)!;
      expect(
        pane.agentLaunch!.arguments,
        containsAllInOrder(['--resume', 'd1']),
      );
    });

    test('an ended host session is not attached to', () async {
      daemonRow('d1');
      presence = ConversationPresence.present;
      await hostHolds([hostFacts('d1', HostSessionState.exited, exitCode: 0)]);

      expect(
        container.read(sessionLauncherProvider).heldByHostOnly('d1'),
        isFalse,
      );
      final result = await openSession('d1') as Map<String, Object?>;
      expect(result['reattached'], isFalse);
      expect(presenceAsked, ['d1']);
    });

    test(
      'session_end with nothing running says so, and ends nothing',
      () async {
        daemonRow('d1');
        await hostHolds(const []);

        await expectLater(
          SessionControlTools(
            container,
          ).call('session_end', {'sessionId': 'd1'}),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('nothing to end'),
            ),
          ),
        );
        expect(endedAtHost, isEmpty);
      },
    );
  });

  group('a failed attempt to open writes no status the host owns', () {
    test('a conversation not written yet, on a row the host knows', () async {
      daemonRow('d1');
      // The host knows the row (it recorded its ending); its status is the
      // daemon's to write, whatever the app's attempt to resume it finds.
      await hostHolds([hostFacts('d1', HostSessionState.exited)]);

      await expectLater(openSession('d1'), throwsA(anything));

      expect(rows().getById('d1')!.status, SessionStatus.running);
    });

    test('a row no host knows is still marked failed, as before', () async {
      daemonRow('d1');
      await hostHolds(const []);

      await expectLater(openSession('d1'), throwsA(anything));

      expect(rows().getById('d1')!.status, SessionStatus.failed);
    });
  });

  test('a session the app started and still shows is revealed, not attached '
      'a second time', () async {
    await hostHolds(const []);
    final launched = await container
        .read(sessionLauncherProvider)
        .launch(
          SessionLaunchRequest(
            repository: repository(),
            installation: agentInstallation(),
            title: 'Mine',
            purpose: SessionPurpose.newSession,
          ),
        );
    host.snapshot = [hostFacts(launched.session.id, HostSessionState.running)];

    final shown = await container
        .read(sessionLauncherProvider)
        .show(launched.session.id);

    expect(shown, isTrue);
    expect(terminals().state.tabs, hasLength(1));
    expect(rows().getById(launched.session.id)!.paneId, launched.paneId);
  });
}
