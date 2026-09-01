import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/agents/application/agent_providers.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/agents/domain/agent_descriptor.dart';
import 'package:karmashala/src/features/agents/domain/agent_registry.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/session_launcher.dart';
import 'package:karmashala/src/features/sessions/application/session_working_directory.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala/src/features/sessions/domain/session_launch.dart';
import 'package:karmashala/src/features/sessions/domain/session_status.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/settings/domain/permission_mode.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';

/// An agent that expresses all three modes exactly, so a flag on the command
/// line names the winning mode with nothing else in the way.
const _rover = AgentDescriptor(
  id: 'roverCli',
  displayName: 'Rover CLI',
  binaries: AgentBinaries(windows: ['rover'], posix: ['rover']),
  launch: AgentLaunchSpec(
    permissionModes: {
      PermissionMode.ask: PermissionModeMapping.exact(['--careful']),
      PermissionMode.acceptEdits: PermissionModeMapping.exact(['--edits']),
      PermissionMode.bypass: PermissionModeMapping.exact(['--trust-me']),
    },
    interactiveResume: AgentResume.flag('--continue'),
  ),
);

/// The real [SettingsController] over the in-memory database, deliberately: the
/// question these tests ask is what happens **when the global default changes**
/// and **after a restart**, and a frozen fake can answer neither.
({ProviderContainer container, AppDatabase db}) harness({AppDatabase? reopen}) {
  final db = reopen ?? AppDatabase.memory();
  if (reopen == null) {
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());
    AgentInstallationDao(db).insert(agentInstallation(agentId: 'roverCli'));
  }
  final container = ProviderContainer(
    overrides: [
      ...fakeTerminalOverrides(database: db),
      clockProvider.overrideWithValue(FixedClock(testTime)),
      idGeneratorProvider.overrideWithValue(SequentialIdGenerator('s-')),
      agentRegistryProvider.overrideWithValue(const AgentRegistry([_rover])),
      // Nothing under `C:\src\demo` exists on a test machine, so the default
      // probe would call every recorded directory gone.
      sessionDirectoryPresentProvider.overrideWithValue((_) => true),
    ],
  );
  return (container: container, db: db);
}

extension on ProviderContainer {
  SessionLauncher get launcher => read(sessionLauncherProvider);

  void setDefaults({PermissionMode? forNew, PermissionMode? forExisting}) {
    final settings = read(settingsControllerProvider.notifier);
    if (forNew != null) settings.setNewSessionPermission('roverCli', forNew);
    if (forExisting != null) {
      settings.setExistingSessionPermission('roverCli', forExisting);
    }
  }

  /// The arguments the pane was actually started with — the only place a
  /// permission mode is ever real.
  List<String> argumentsOf(String paneId) => read(
    terminalSessionsControllerProvider.notifier,
  ).instanceFor(paneId)!.agentLaunch!.arguments;
}

/// A stopped session with a CLI id, which is exactly what the resume path
/// reuses rather than duplicating.
void seedStopped(AppDatabase db, {PermissionMode? mode}) {
  SessionDao(db).insert(
    session(id: 'src', status: SessionStatus.completed).copyWith(
      externalSessionId: 'cli-1',
      permissionMode: mode,
    ),
  );
}

Future<SessionLaunchResult> resume(ProviderContainer container) =>
    container.launcher.launch(
      SessionLaunchRequest(
        repository: repository(),
        installation: agentInstallation(agentId: 'roverCli'),
        title: 'Continue',
        purpose: SessionPurpose.existingSession,
        resumeExternalSessionId: 'cli-1',
      ),
    );

Future<SessionLaunchResult> startNew(ProviderContainer container) =>
    container.launcher.launch(
      SessionLaunchRequest(
        repository: repository(),
        installation: agentInstallation(agentId: 'roverCli'),
        title: 'Fresh',
        purpose: SessionPurpose.newSession,
      ),
    );

void main() {
  // "existing session permission mode should be overridable in each session.
  // but settings is taking precedence, it should be highest priority to
  // sessions own permission by default right?" — the owner's request, and the
  // rule every test below states one half of.

  test('a session\'s own mode beats the global default at launch', () async {
    final h = harness();
    addTearDown(h.db.close);
    addTearDown(h.container.dispose);
    h.container.setDefaults(forNew: PermissionMode.bypass);

    final launched = await h.container.launcher.launch(
      SessionLaunchRequest(
        repository: repository(),
        installation: agentInstallation(agentId: 'roverCli'),
        title: 'Careful',
        purpose: SessionPurpose.newSession,
        permissionOverride: PermissionMode.ask,
      ),
    );

    expect(h.container.argumentsOf(launched.paneId!), contains('--careful'));
    expect(
      SessionDao(h.db).getById(launched.session.id)!.permissionMode,
      PermissionMode.ask,
    );
  });

  test('a session\'s own mode beats the global default at resume', () async {
    final h = harness();
    addTearDown(h.db.close);
    addTearDown(h.container.dispose);
    h.container.setDefaults(forExisting: PermissionMode.bypass);
    seedStopped(h.db, mode: PermissionMode.ask);

    final launched = await resume(h.container);

    // The row is continued, not duplicated, so this really is *the* session
    // whose mode was chosen.
    expect(launched.session.id, 'src');
    // The whole bug in one line: the resume used to re-read the setting and
    // start a deliberately careful session under full autonomy.
    expect(h.container.argumentsOf(launched.paneId!), [
      '--careful',
      '--continue',
      'cli-1',
    ]);
    // And it must not have overwritten the choice on its way past.
    expect(SessionDao(h.db).getById('src')!.permissionMode, PermissionMode.ask);
  });

  test('changing the global default does not move a session that chose', () {
    final h = harness();
    addTearDown(h.db.close);
    addTearDown(h.container.dispose);
    seedStopped(h.db, mode: PermissionMode.acceptEdits);

    h.container.setDefaults(forExisting: PermissionMode.bypass);

    final effective = h.container.launcher.effectivePermissionFor('src')!;
    expect(effective.mode, PermissionMode.acceptEdits);
    expect(effective.inherited, isFalse);
  });

  test('changing the global default moves a session that never chose', () {
    final h = harness();
    addTearDown(h.db.close);
    addTearDown(h.container.dispose);
    seedStopped(h.db);

    h.container.setDefaults(forExisting: PermissionMode.acceptEdits);
    expect(
      h.container.launcher.effectivePermissionFor('src')!.mode,
      PermissionMode.acceptEdits,
    );

    // Live, not sampled once: a session with no choice of its own follows the
    // setting wherever it goes.
    h.container.setDefaults(forExisting: PermissionMode.bypass);
    final effective = h.container.launcher.effectivePermissionFor('src')!;
    expect(effective.mode, PermissionMode.bypass);
    expect(effective.inherited, isTrue);
  });

  test('a launch stamps nothing on a session nobody chose for', () async {
    final h = harness();
    addTearDown(h.db.close);
    addTearDown(h.container.dispose);
    h.container.setDefaults(forNew: PermissionMode.acceptEdits);

    final launched = await startNew(h.container);

    // It ran under the default, and the flags say so.
    expect(h.container.argumentsOf(launched.paneId!), contains('--edits'));
    // But the row records **no choice**, because none was made. Stamping the
    // default here is what froze every session at whatever the setting said on
    // the day it started.
    expect(
      SessionDao(h.db).getById(launched.session.id)!.permissionMode,
      isNull,
    );

    h.container.setDefaults(forExisting: PermissionMode.bypass);
    expect(
      h.container.launcher.effectivePermissionFor(launched.session.id)!.mode,
      PermissionMode.bypass,
    );
  });

  test('a resumed session that never chose follows the current default', () async {
    final h = harness();
    addTearDown(h.db.close);
    addTearDown(h.container.dispose);
    seedStopped(h.db);
    h.container.setDefaults(forExisting: PermissionMode.acceptEdits);

    final launched = await resume(h.container);

    expect(h.container.argumentsOf(launched.paneId!), [
      '--edits',
      '--continue',
      'cli-1',
    ]);
    expect(SessionDao(h.db).getById('src')!.permissionMode, isNull);
  });

  test('the choice survives a restart', () async {
    final first = harness();
    addTearDown(first.db.close);
    first.container.setDefaults(forExisting: PermissionMode.bypass);
    seedStopped(first.db);
    first.container.launcher.setPermissionMode('src', PermissionMode.ask);
    first.container.dispose();

    // A new container over the same database is what a restart is: settings
    // and sessions are both re-read from disk.
    final second = harness(reopen: first.db);
    addTearDown(second.container.dispose);

    final effective = second.container.launcher.effectivePermissionFor('src')!;
    expect(effective.mode, PermissionMode.ask);
    expect(effective.inherited, isFalse);

    final launched = await resume(second.container);
    expect(second.container.argumentsOf(launched.paneId!), [
      '--careful',
      '--continue',
      'cli-1',
    ]);
  });

  test('a session can be handed back to the default', () {
    final h = harness();
    addTearDown(h.db.close);
    addTearDown(h.container.dispose);
    seedStopped(h.db, mode: PermissionMode.ask);
    h.container.setDefaults(forExisting: PermissionMode.acceptEdits);

    // Null is a value here, not a missing argument: "follow the setting" is a
    // state the user can go back to, and without this the first pick would be
    // irreversible.
    h.container.launcher.setPermissionMode('src', null);

    expect(SessionDao(h.db).getById('src')!.permissionMode, isNull);
    final effective = h.container.launcher.effectivePermissionFor('src')!;
    expect(effective.mode, PermissionMode.acceptEdits);
    expect(effective.inherited, isTrue);
  });
}
