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
import 'package:karmashala/src/features/agents/domain/agent_permission_support.dart';
import 'package:karmashala/src/features/settings/domain/permission_risk.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';

/// An agent with one flag per mode, so a flag on the command line names the
/// winning mode with nothing else in the way.
const _rover = AgentDescriptor(
  id: 'roverCli',
  displayName: 'Rover CLI',
  binaries: AgentBinaries(windows: ['rover'], posix: ['rover']),
  launch: AgentLaunchSpec(
    permission: AgentPermissionSupport.axes(
      evidence: 'test fixture',
      axes: [
        AgentPermissionAxis(
          id: 'mode',
          label: 'Mode',
          description: 'test',
          defaultValueId: 'careful',
          values: [
            AgentPermissionValue(
              id: 'careful',
              label: 'Careful',
              shortLabel: 'Careful',
              description: 'Asks first.',
              arguments: ['--careful'],
              permits: PermissionRisk.ask,
              evidence: 'test fixture',
            ),
            AgentPermissionValue(
              id: 'edits',
              label: 'Edits',
              shortLabel: 'Edits',
              description: 'Writes without asking.',
              arguments: ['--edits'],
              permits: PermissionRisk.acceptEdits,
              evidence: 'test fixture',
            ),
            AgentPermissionValue(
              id: 'trust',
              label: 'Trust me',
              shortLabel: 'Trust',
              description: 'Everything, without asking.',
              arguments: ['--trust-me'],
              permits: PermissionRisk.bypass,
              isDangerous: true,
              evidence: 'test fixture',
            ),
          ],
        ),
      ],
    ),
    interactiveResume: AgentResume.flag('--continue'),
  ),
);

const _careful = PermissionSelection({'mode': 'careful'});
const _edits = PermissionSelection({'mode': 'edits'});
const _trust = PermissionSelection({'mode': 'trust'});

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

  void setDefaults({
    PermissionSelection? forNew,
    PermissionSelection? forExisting,
  }) {
    final settings = read(settingsControllerProvider.notifier);
    if (forNew != null) {
      settings.setNewSessionPermission('roverCli', forNew.canonical);
    }
    if (forExisting != null) {
      settings.setExistingSessionPermission('roverCli', forExisting.canonical);
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
void seedStopped(AppDatabase db, {PermissionSelection? mode}) {
  SessionDao(db).insert(
    session(id: 'src', status: SessionStatus.completed).copyWith(
      externalSessionId: 'cli-1',
      permissionMode: mode?.canonical,
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
    h.container.setDefaults(forNew: _trust);

    final launched = await h.container.launcher.launch(
      SessionLaunchRequest(
        repository: repository(),
        installation: agentInstallation(agentId: 'roverCli'),
        title: 'Careful',
        purpose: SessionPurpose.newSession,
        permissionOverride: _careful,
      ),
    );

    expect(h.container.argumentsOf(launched.paneId!), contains('--careful'));
    expect(
      SessionDao(h.db).getById(launched.session.id)!.permissionMode,
      _careful.canonical,
    );
  });

  test('a session\'s own mode beats the global default at resume', () async {
    final h = harness();
    addTearDown(h.db.close);
    addTearDown(h.container.dispose);
    h.container.setDefaults(forExisting: _trust);
    seedStopped(h.db, mode: _careful);

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
    expect(SessionDao(h.db).getById('src')!.permissionMode, _careful.canonical);
  });

  test('changing the global default does not move a session that chose', () {
    final h = harness();
    addTearDown(h.db.close);
    addTearDown(h.container.dispose);
    seedStopped(h.db, mode: _edits);

    h.container.setDefaults(forExisting: _trust);

    final effective = h.container.launcher.effectivePermissionFor('src')!;
    expect(effective.selection, _edits);
    expect(effective.inherited, isFalse);
  });

  test('changing the global default moves a session that never chose', () {
    final h = harness();
    addTearDown(h.db.close);
    addTearDown(h.container.dispose);
    seedStopped(h.db);

    h.container.setDefaults(forExisting: _edits);
    expect(
      h.container.launcher.effectivePermissionFor('src')!.selection,
      _edits,
    );

    // Live, not sampled once: a session with no choice of its own follows the
    // setting wherever it goes.
    h.container.setDefaults(forExisting: _trust);
    final effective = h.container.launcher.effectivePermissionFor('src')!;
    expect(effective.selection, _trust);
    expect(effective.inherited, isTrue);
  });

  test('a launch stamps nothing on a session nobody chose for', () async {
    final h = harness();
    addTearDown(h.db.close);
    addTearDown(h.container.dispose);
    h.container.setDefaults(forNew: _edits);

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

    h.container.setDefaults(forExisting: _trust);
    expect(
      h.container.launcher.effectivePermissionFor(launched.session.id)!.selection,
      _trust,
    );
  });

  test('a resumed session that never chose follows the current default', () async {
    final h = harness();
    addTearDown(h.db.close);
    addTearDown(h.container.dispose);
    seedStopped(h.db);
    h.container.setDefaults(forExisting: _edits);

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
    first.container.setDefaults(forExisting: _trust);
    seedStopped(first.db);
    first.container.launcher.setPermissionMode('src', _careful);
    first.container.dispose();

    // A new container over the same database is what a restart is: settings
    // and sessions are both re-read from disk.
    final second = harness(reopen: first.db);
    addTearDown(second.container.dispose);

    final effective = second.container.launcher.effectivePermissionFor('src')!;
    expect(effective.selection, _careful);
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
    seedStopped(h.db, mode: _careful);
    h.container.setDefaults(forExisting: _edits);

    // Null is a value here, not a missing argument: "follow the setting" is a
    // state the user can go back to, and without this the first pick would be
    // irreversible.
    h.container.launcher.setPermissionMode('src', null);

    expect(SessionDao(h.db).getById('src')!.permissionMode, isNull);
    final effective = h.container.launcher.effectivePermissionFor('src')!;
    expect(effective.selection, _edits);
    expect(effective.inherited, isTrue);
  });
}
