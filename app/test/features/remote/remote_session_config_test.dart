import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/agents/application/agent_providers.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:karmashala/src/features/remote/application/remote_bindings.dart';
import 'package:karmashala/src/features/sessions/application/pending_live_switches.dart';
import 'package:karmashala/src/features/sessions/application/session_launcher.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_working_directory.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/settings/domain/settings.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_session/launch.dart';
import 'package:karmashala_store/database.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/fake_data_server.dart';
import '../../support/workspace_mirror.dart';
import '../terminal/fake_instance.dart';

/// What the phone is offered for a session, and what its pick does: the same
/// launcher the desktop's chips use, never a mode that removes every prompt.
class _StaticSettings extends SettingsController {
  @override
  Settings build() => const Settings();
}

void main() {
  late AppDatabase db;
  late ProviderContainer container;

  setUp(() async {
    db = AppDatabase.memory();
    final server = FakeDataServer()..mirrorInto(db);
    server.environmentRows.upsert(windowsEnv());
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    server.installationRows.insert(agentInstallation(agentId: AgentIds.claudeCode));
    container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db),
        await server.override(),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        idGeneratorProvider.overrideWithValue(SequentialIdGenerator('s-')),
        agentRegistryProvider.overrideWithValue(AgentRegistry.builtIn),
        settingsControllerProvider.overrideWith(_StaticSettings.new),
        sessionActivityLookupProvider.overrideWithValue(
          (_) => AgentActivityStatus.idle,
        ),
        sessionDirectoryPresentProvider.overrideWithValue((_) => true),
        pendingLiveSwitchesProvider.overrideWith(
          (ref) => PendingLiveSwitches(ref, const Stream.empty()),
        ),
        conversationPresenceProvider.overrideWithValue(
          ({
            required descriptor,
            required environmentId,
            required conversationId,
          }) async => ConversationPresence.present,
        ),
      ],
    );
  });

  tearDown(() {
    container.dispose();
    db.close();
  });

  Future<({String id, List<String> keys})> launched() async {
    final result = await container
        .read(sessionLauncherProvider)
        .launch(
          SessionLaunchRequest(
            repository: repository(),
            installation: agentInstallation(agentId: AgentIds.claudeCode),
            title: 'Session',
            purpose: SessionPurpose.newSession,
          ),
        );
    final terminal = container
        .read(terminalSessionsControllerProvider.notifier)
        .instanceFor(result.paneId!)!
        .terminal;
    // Claude Code's status line, one step of its cycle per Shift+Tab.
    const cycle = ['', 'accept edits on', 'plan mode on'];
    var at = 0;
    void draw() => terminal.write('\x1b[2J\x1b[H> \r\n${cycle[at]}\r\n');
    draw();
    final keys = <String>[];
    terminal.onOutput = (data) {
      keys.add(data);
      if (data == '\x1b[Z') {
        at = (at + 1) % cycle.length;
        draw();
      }
    };
    return (id: result.session.id, keys: keys);
  }

  test('the phone is offered models and safe modes, never bypass', () async {
    final session = await launched();
    final options = await container
        .read(remoteHostBindingsProvider)
        .sessionOptions(session.id);

    expect(options.models.map((m) => m.id), contains('sonnet'));
    final modes = options.permissions.map((p) => p.id);
    expect(modes, contains('mode=plan'));
    expect(modes.where((id) => id.contains('bypass')), isEmpty);
  });

  test('a pick from the phone moves the running session in place', () async {
    final session = await launched();
    final outcome = await container
        .read(remoteHostBindingsProvider)
        .configureSession(session.id, permission: (id: 'mode=plan'));

    expect(outcome, RemoteConfigureOutcome.now);
    expect(session.keys, ['\x1b[Z', '\x1b[Z']);
    expect(mirroredServer(db).sessionRows.getById(session.id)!.permissionMode, 'mode=plan');
  });

  test('bypass from the phone is refused and nothing is recorded', () async {
    final session = await launched();
    await expectLater(
      container
          .read(remoteHostBindingsProvider)
          .configureSession(
            session.id,
            permission: (id: 'mode=bypassPermissions'),
          ),
      throwsA(anything),
    );
    expect(session.keys, isEmpty);
    expect(
      mirroredServer(db).sessionRows.getById(session.id)!.permissionMode,
      isNot('mode=bypassPermissions'),
    );
  });
}
