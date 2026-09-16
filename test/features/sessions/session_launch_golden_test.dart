/// What a launch produces, frozen byte for byte.
///
/// `SessionLauncher` is the one object every session comes into existence
/// through, and its whole contract is what a launch *produces*: a command line
/// (executable, the durable arguments, the volatile MCP ones), a working
/// directory, the environment wrapper the process is started under, the row
/// that is written, and — where a launch is refused — the exact words the user
/// is told. Splitting the launcher into per-concern files is meant to change
/// none of it, and every ordinary test in this folder checks one decision at a
/// time, so nothing would have noticed a family arriving with a flag dropped,
/// an argument reordered, a row field stopped being written, or a refusal
/// reworded.
///
/// So the whole answer is committed. Every launch below is driven through the
/// **public** entry points — [SessionLauncher.launch],
/// [SessionLauncher.restartSession] and the reads the composer chips make —
/// against the **production** registry over a seeded in-memory database, with
/// fakes only where a real process, a real disk or a real network would be:
/// the PTY layer (`fakeTerminalOverrides`), the external terminal's process
/// runner, the MCP endpoint, the packet directory, and the two probes that
/// touch the filesystem (`sessionDirectoryPresentProvider`,
/// `conversationPresenceProvider`). Everything between the request and those
/// seams is the shipped code.
///
/// The matrix is every agent × every environment kind × every permission mode
/// this app can put a session in × fresh/resume, plus the other launch shapes
/// (an opening message, a fork, a restart, a joined worktree, a handoff packet,
/// a parented session, a model override, a directory that went away), plus the
/// external-terminal surface, plus every refusal, plus the reads a chip makes.
///
/// Regenerate only when the change is intended, and never as a side effect of
/// `--update-goldens` (which is why this is its own variable):
///
/// ```
/// KARMASHALA_WRITE_LAUNCH_GOLDEN=1 flutter test \
///   test/features/sessions/session_launch_golden_test.dart
/// ```
///
/// Windows only: the matrix is a Windows host's (cmd.exe, `C:\` paths, WSL
/// environments reached through `/mnt/c`), and the packet directory is a real
/// temp folder, so its separator and its WSL spelling are the machine's.
@TestOn('windows')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/agents/application/agent_providers.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:agent_cli/read.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/mcp/session_mcp.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/projects/domain/project.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala/src/features/sessions/application/handoff_packet_files.dart';
import 'package:karmashala/src/features/sessions/application/session_launcher.dart';
import 'package:karmashala/src/features/sessions/application/session_working_directory.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session/launch.dart';
import 'package:karmashala_session/lineage.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/settings/domain/settings.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala/src/features/terminal/data/system_terminal_service.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';

const _goldenPath = 'test/features/sessions/session_launches.golden.json';

/// The external terminal every external launch here is handed, so nothing
/// asks the host what it has installed.
const _terminal = SystemTerminal(
  kind: SystemTerminalKind.windowsTerminal,
  label: 'Windows Terminal',
  executable: 'wt.exe',
);

/// An agent whose CLI takes no opening message — the one shape none of the
/// three shipped agents has, and the only way to reach
/// [SessionLaunchRefused] through the public entry point.
const _mute = AgentDescriptor(
  id: 'muteCli',
  displayName: 'Mute CLI',
  binaries: AgentBinaries(windows: ['mute'], posix: ['mute']),
  launch: AgentLaunchSpec(),
);

/// The MCP endpoint, answered from constants rather than from a bound socket.
///
/// It echoes the request back the way `LauncherControlServer` does — a URL
/// carrying the session's own credential, and a config file only when the
/// agent's convention opens one — so what the golden records is the launcher's
/// own routing of those two values and never a port this machine happened to
/// get.
class _FixedMcp implements SessionMcp {
  @override
  SessionMcpAccess? accessFor({
    required String sessionId,
    required ExecutionEnvironment environment,
    required bool withConfigFile,
  }) => SessionMcpAccess(
    url: 'http://127.0.0.1:7777/mcp/$sessionId',
    configPath: withConfigFile ? r'C:\mcp\session-' '$sessionId.json' : null,
  );
}

class _StaticSessionMcp extends SessionMcpController {
  _StaticSessionMcp(this._mcp);
  final SessionMcp _mcp;

  @override
  SessionMcp? build() => _mcp;
}

class _StaticSettings extends SettingsController {
  _StaticSettings(this._settings);
  final Settings _settings;

  @override
  Settings build() => _settings;
}

/// One environment the app can run a session in, with the checkout, the
/// project and the paths that belong to it.
typedef _Env = ({
  String id,
  ExecutionEnvironment environment,
  String projectId,
  String repositoryId,
  String root,
  String binDirectory,
  String separator,
});

void main() {
  test('the launch contract matches the committed golden', () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);

    final packets = await Directory.systemTemp.createTemp(
      'karmashala-launch-golden-',
    );
    addTearDown(() => packets.delete(recursive: true));

    // Every environment kind a session can be started in, each with its own
    // project, checkout and installations — because the wrapper the process is
    // started under (a WSL distribution, an SSH host, neither) is decided by
    // the environment of the directory the launch resolves to.
    final environments = <_Env>[
      (
        id: 'windows',
        environment: windowsEnv(),
        projectId: 'p-windows',
        repositoryId: 'r-windows',
        root: r'C:\src\demo\app',
        binDirectory: r'C:\bin',
        separator: r'\',
      ),
      (
        id: 'wsl:Ubuntu',
        environment: wslEnv(),
        projectId: 'p-wsl',
        repositoryId: 'r-wsl',
        root: '/home/dev/app',
        binDirectory: '/usr/local/bin',
        separator: '/',
      ),
      (
        id: 'ssh:h1',
        environment: sshEnvFixture(),
        projectId: 'p-ssh',
        repositoryId: 'r-ssh',
        root: '/srv/app',
        binDirectory: '/usr/local/bin',
        separator: '/',
      ),
      (
        id: 'posix',
        environment: posixEnv(id: 'posix'),
        projectId: 'p-posix',
        repositoryId: 'r-posix',
        root: '/Users/me/app',
        binDirectory: '/opt/homebrew/bin',
        separator: '/',
      ),
    ];

    EnvironmentPath at(_Env env, String path) =>
        EnvironmentPath(environmentId: env.id, path: path);

    for (final env in environments) {
      ExecutionEnvironmentDao(db).upsert(env.environment);
      ProjectDao(db).insert(
        Project(
          id: env.projectId,
          name: env.id,
          root: at(env, env.root),
          createdAt: testTime,
        ),
      );
      RepositoryDao(db).insert(
        Repository(
          id: env.repositoryId,
          projectId: env.projectId,
          name: 'app',
          path: at(env, env.root),
          createdAt: testTime,
        ),
      );
      for (final agentId in AgentIds.builtIn) {
        AgentInstallationDao(db).insert(
          AgentInstallation(
            id: 'i-$agentId-${env.id}',
            agentId: agentId,
            executable: at(env, '${env.binDirectory}${env.separator}$agentId'),
            createdAt: testTime,
          ),
        );
      }
    }

    // The two probes that would touch a real disk. Both are mutable so the
    // refusal section can make one directory disappear and one conversation
    // unwritten without a second container whose id generator would start over.
    final missingDirectories = <String>{};
    final absentConversations = <String>{};

    final runner = FakeCommandRunner();
    final container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        idGeneratorProvider.overrideWithValue(SequentialIdGenerator('s-')),
        agentRegistryProvider.overrideWithValue(
          AgentRegistry([...builtInAgentDescriptors, _mute]),
        ),
        settingsControllerProvider.overrideWith(
          () => _StaticSettings(const Settings()),
        ),
        hostCommandRunnerProvider.overrideWithValue(runner),
        sessionMcpProvider.overrideWith(() => _StaticSessionMcp(_FixedMcp())),
        handoffPacketFilesProvider.overrideWith(
          (ref) async => HandoffPacketFiles(packets),
        ),
        sessionDirectoryPresentProvider.overrideWithValue(
          (directory) => !missingDirectories.contains(directory.path),
        ),
        conversationPresenceProvider.overrideWithValue(
          ({
            required AgentDescriptor descriptor,
            required String environmentId,
            required String conversationId,
          }) async => absentConversations.contains(conversationId)
              ? ConversationPresence.absent
              : ConversationPresence.unknown,
        ),
        // Nothing to open a session in, for the one refusal that is about
        // having no external terminal configured at all.
        defaultSystemTerminalProvider.overrideWith((ref) async => null),
      ],
    );
    addTearDown(container.dispose);

    final launcher = container.read(sessionLauncherProvider);
    final registry = container.read(agentRegistryProvider);
    final sessions = SessionDao(db);
    final terminals = container.read(
      terminalSessionsControllerProvider.notifier,
    );

    Repository repositoryIn(_Env env) =>
        RepositoryDao(db).getById(env.repositoryId)!;
    AgentInstallation installationOf(String agentId, _Env env) =>
        AgentInstallationDao(db).getById('i-$agentId-${env.id}')!;

    /// The row as it stands after a launch — every field a launch decides.
    Map<String, Object?> rowOf(String sessionId) {
      final row = sessions.getById(sessionId);
      if (row == null) return {'row': 'gone'};
      return {
        'title': row.title,
        'status': row.status.name,
        'surface': row.surface.name,
        'view': row.view.name,
        'externalSessionId': row.externalSessionId == sessionId
            ? '<ownId>'
            : row.externalSessionId,
        'workingDirectory': row.workingDirectory?.path,
        'worktree': row.worktree?.path,
        'useWorktree': row.useWorktree,
        'permissionMode': row.permissionMode,
        'modelId': row.modelId,
        'parentSessionId': row.parentSessionId,
        'parentLink': row.parentLink?.name,
        'hasPane': row.paneId != null,
      };
    }

    /// What a pane launch actually produced: the command line in its two
    /// halves — the durable arguments a restored pane replays, and the
    /// volatile MCP flags rebuilt at every launch — and the wrapper the
    /// process is started under.
    Map<String, Object?> paneRecord(SessionLaunchResult result) {
      final launch =
          (terminals.instanceFor(result.paneId!)! as FakeTerminalInstance)
              .agentLaunch!;
      return {
        'executable': launch.executable,
        'arguments': launch.arguments,
        'mcpArguments': launch.mcpArguments,
        'workingDirectory': launch.workingDirectory,
        'wslDistribution': launch.wslDistribution,
        'sshHostId': launch.sshHostId,
        'paneTitle': launch.title,
        'notice': result.workingDirectoryNotice,
        'row': rowOf(result.session.id),
      };
    }

    /// The same for an external launch, read off the process the system
    /// terminal service was asked to start.
    Map<String, Object?> externalRecord(SessionLaunchResult result) {
      final request = runner.startRequests.last;
      return {
        'terminal': request.executable,
        'arguments': request.arguments,
        'workingDirectory': request.workingDirectory?.path,
        'paneId': result.paneId,
        'notice': result.workingDirectoryNotice,
        'row': rowOf(result.session.id),
      };
    }

    var seeded = 0;

    /// A stopped row holding conversation [conversationId], as a previous run
    /// of this session would have left it. Each case gets its own, because a
    /// second launch on a conversation a pane of ours is still running is a
    /// different question — and one the refusal section asks on purpose.
    String seedResumable(
      String agentId,
      _Env env, {
      required String conversationId,
      SessionSurface surface = SessionSurface.pane,
      String? workingDirectory,
    }) {
      final id = 'seed-${seeded++}';
      sessions.insert(
        Session(
          id: id,
          repositoryId: env.repositoryId,
          agentInstallationId: 'i-$agentId-${env.id}',
          title: 'Earlier work',
          useWorktree: false,
          status: SessionStatus.created,
          createdAt: testTime,
          surface: surface,
          externalSessionId: conversationId,
          workingDirectory: workingDirectory == null
              ? null
              : at(env, workingDirectory),
        ),
      );
      return id;
    }

    // --- every agent × every environment × every mode × fresh/resume --------
    //
    // The permission mode is the one dimension crossed with everything: it is
    // resolved here and nowhere else, and the arguments it turns into are the
    // agent's own vocabulary, so a mode that stopped reaching the command line
    // for one agent in one environment is exactly the silent loss this whole
    // matrix exists to catch.
    final launches = <Map<String, Object?>>[];
    for (final agentId in AgentIds.builtIn) {
      final support = registry.byId(agentId)!.launch.permission;
      for (final env in environments) {
        for (final selection in support.selections()) {
          for (final resuming in [false, true]) {
            final conversation = 'conv-$agentId-${env.id}-'
                '${selection.canonical}';
            final resumed = resuming
                ? seedResumable(agentId, env, conversationId: conversation)
                : null;
            final result = await launcher.launch(
              SessionLaunchRequest(
                repository: repositoryIn(env),
                installation: installationOf(agentId, env),
                title: resuming ? 'Carry on' : 'New work',
                purpose: resuming
                    ? SessionPurpose.existingSession
                    : SessionPurpose.newSession,
                permissionOverride: selection,
                resumeExternalSessionId: resuming ? conversation : null,
              ),
            );
            launches.add({
              'agent': agentId,
              'environment': env.id,
              'mode': selection.canonical,
              'shape': resuming ? 'resume' : 'fresh',
              'reusedTheRow': result.session.id == resumed,
              ...paneRecord(result),
            });
          }
        }
      }
    }

    // --- the external-terminal surface --------------------------------------
    //
    // "Open this in Windows Terminal instead" has to produce the same agent, in
    // the same mode, on the same conversation — through a wrapper the
    // environment decides. Its own section rather than a fifth dimension above
    // because the arguments are the same builder's and only the wrapper is not.
    final external = <Map<String, Object?>>[];
    for (final agentId in AgentIds.builtIn) {
      for (final env in environments) {
        for (final resuming in [false, true]) {
          final conversation = 'ext-$agentId-${env.id}';
          if (resuming) {
            seedResumable(
              agentId,
              env,
              conversationId: conversation,
              surface: SessionSurface.external,
            );
          }
          final result = await launcher.launch(
            SessionLaunchRequest(
              repository: repositoryIn(env),
              installation: installationOf(agentId, env),
              title: 'Elsewhere',
              purpose: resuming
                  ? SessionPurpose.existingSession
                  : SessionPurpose.newSession,
              surface: SessionSurface.external,
              resumeExternalSessionId: resuming ? conversation : null,
            ),
            externalTerminal: _terminal,
          );
          external.add({
            'agent': agentId,
            'environment': env.id,
            'shape': resuming ? 'resume' : 'fresh',
            ...externalRecord(result),
          });
        }
      }
    }

    // --- the other shapes a launch comes in ---------------------------------
    //
    // Each is a decision the launcher makes on its own: what an opening message
    // becomes, what a fork emits instead of a resume, what a restart reuses,
    // where a joined worktree runs, whether a handoff packet reaches the agent
    // as a file, what a spawned session's prompt is prefixed with, and what the
    // user is told when the directory a session recorded has gone.
    const shapes = [
      'openingMessage',
      'fork',
      'restart',
      'joinedWorktree',
      'handoffPacket',
      'spawnedChild',
      'modelOverride',
      'directoryGone',
    ];
    final shaped = <Map<String, Object?>>[];
    for (final agentId in AgentIds.builtIn) {
      for (final env in environments) {
        for (final shape in shapes) {
          final descriptor = registry.byId(agentId)!;
          var request = SessionLaunchRequest(
            repository: repositoryIn(env),
            installation: installationOf(agentId, env),
            title: shape,
            purpose: SessionPurpose.newSession,
          );
          switch (shape) {
            case 'openingMessage':
              request = SessionLaunchRequest(
                repository: request.repository,
                installation: request.installation,
                title: shape,
                purpose: SessionPurpose.newSession,
                firstMessage: '  read the brief and start  ',
              );
            case 'fork':
              request = SessionLaunchRequest(
                repository: request.repository,
                installation: request.installation,
                title: shape,
                purpose: SessionPurpose.existingSession,
                forkExternalSessionId: 'fork-$agentId-${env.id}',
              );
            case 'restart':
              final row = seedResumable(
                agentId,
                env,
                conversationId: 'restart-$agentId-${env.id}',
              );
              request = SessionLaunchRequest(
                repository: request.repository,
                installation: request.installation,
                title: shape,
                purpose: SessionPurpose.newSession,
                restartSessionId: row,
              );
            case 'joinedWorktree':
              request = SessionLaunchRequest(
                repository: request.repository,
                installation: request.installation,
                title: shape,
                purpose: SessionPurpose.newSession,
                existingWorktree: at(env, '${env.root}/.worktrees/feature'),
              );
            case 'handoffPacket':
              request = SessionLaunchRequest(
                repository: request.repository,
                installation: request.installation,
                title: shape,
                purpose: SessionPurpose.newSession,
                systemPromptFile: 'The brief, in full.',
                firstMessage: 'the brief is attached',
              );
            case 'spawnedChild':
              final parent = seedResumable(
                agentId,
                env,
                conversationId: 'parent-$agentId-${env.id}',
              );
              request = SessionLaunchRequest(
                repository: request.repository,
                installation: request.installation,
                title: shape,
                purpose: SessionPurpose.newSession,
                parentSessionId: parent,
                firstMessage: 'do the sub-task',
              );
            case 'modelOverride':
              final model =
                  descriptor.launch.model.models.isEmpty
                  ? 'some-model'
                  : descriptor.launch.model.models.first.id;
              request = SessionLaunchRequest(
                repository: request.repository,
                installation: request.installation,
                title: shape,
                purpose: SessionPurpose.newSession,
                modelOverride: model,
              );
            case 'directoryGone':
              final gone = '${env.root}/gone';
              missingDirectories.add(gone);
              final row = seedResumable(
                agentId,
                env,
                conversationId: 'gone-$agentId-${env.id}',
                workingDirectory: gone,
              );
              request = SessionLaunchRequest(
                repository: request.repository,
                installation: request.installation,
                title: shape,
                purpose: SessionPurpose.existingSession,
                resumeExternalSessionId: sessions
                    .getById(row)!
                    .externalSessionId,
              );
          }
          final result = await launcher.launch(request);
          shaped.add({
            'agent': agentId,
            'environment': env.id,
            'shape': shape,
            ...paneRecord(result),
          });
        }
      }
    }

    // --- what a launch refuses, and in what words ---------------------------
    //
    // Every refusal reaches a user or a model as prose, so the wording is as
    // much of the contract as the arguments are. Recorded by type and by
    // message, which is what makes a reword show up here as a reword rather
    // than as a passing test.
    final refusals = <Map<String, Object?>>[];
    Future<void> refuses(String name, Future<Object?> Function() act) async {
      try {
        await act();
        refusals.add({'case': name, 'threw': null});
      } on Object catch (error) {
        refusals.add({
          'case': name,
          'threw': error.runtimeType.toString(),
          'says': error.toString(),
        });
      }
    }

    final windows = environments.first;
    await refuses('restart and resume at once', () async {
      final row = seedResumable(
        AgentIds.claudeCode,
        windows,
        conversationId: 'both-1',
      );
      return launcher.launch(
        SessionLaunchRequest(
          repository: repositoryIn(windows),
          installation: installationOf(AgentIds.claudeCode, windows),
          title: 'Both',
          purpose: SessionPurpose.existingSession,
          restartSessionId: row,
          resumeExternalSessionId: 'both-1',
        ),
      );
    });
    await refuses(
      'resume and fork at once',
      () => launcher.launch(
        SessionLaunchRequest(
          repository: repositoryIn(windows),
          installation: installationOf(AgentIds.claudeCode, windows),
          title: 'Both',
          purpose: SessionPurpose.existingSession,
          resumeExternalSessionId: 'both-2',
          forkExternalSessionId: 'both-3',
        ),
      ),
    );
    await refuses(
      'a new worktree and an existing one at once',
      () => launcher.launch(
        SessionLaunchRequest(
          repository: repositoryIn(windows),
          installation: installationOf(AgentIds.claudeCode, windows),
          title: 'Both',
          purpose: SessionPurpose.newSession,
          useWorktree: true,
          existingWorktree: at(windows, r'C:\src\demo\app\.worktrees\x'),
        ),
      ),
    );
    await refuses('an opening message the CLI cannot take', () {
      AgentInstallationDao(db).insert(
        AgentInstallation(
          id: 'i-mute-windows',
          agentId: 'muteCli',
          executable: at(windows, r'C:\bin\mute.exe'),
          createdAt: testTime,
        ),
      );
      return launcher.launch(
        SessionLaunchRequest(
          repository: repositoryIn(windows),
          installation: AgentInstallationDao(db).getById('i-mute-windows')!,
          title: 'Mute',
          purpose: SessionPurpose.newSession,
          firstMessage: 'this would be dropped',
        ),
      );
    });
    await refuses('a second process on a conversation the agent will not share', () async {
      // Antigravity forbids it, so a live pane of ours holding the
      // conversation is the blocking case rather than the supported one.
      const conversation = 'held-by-us';
      seedResumable(AgentIds.antigravity, windows, conversationId: conversation);
      await launcher.launch(
        SessionLaunchRequest(
          repository: repositoryIn(windows),
          installation: installationOf(AgentIds.antigravity, windows),
          title: 'Held',
          purpose: SessionPurpose.existingSession,
          resumeExternalSessionId: conversation,
        ),
      );
      return launcher.launch(
        SessionLaunchRequest(
          repository: repositoryIn(windows),
          installation: installationOf(AgentIds.antigravity, windows),
          title: 'Held again',
          purpose: SessionPurpose.existingSession,
          resumeExternalSessionId: conversation,
        ),
      );
    });
    await refuses('a conversation the store has never held', () async {
      // A row whose id *is* the conversation id: the promise Claude Code's
      // `--session-id` makes at launch, and the only shape the store is asked
      // about at all.
      final minted = await launcher.launch(
        SessionLaunchRequest(
          repository: repositoryIn(windows),
          installation: installationOf(AgentIds.claudeCode, windows),
          title: 'Promised',
          purpose: SessionPurpose.newSession,
        ),
      );
      terminals.endSession(minted.paneId!);
      absentConversations.add(minted.session.id);
      return launcher.launch(
        SessionLaunchRequest(
          repository: repositoryIn(windows),
          installation: installationOf(AgentIds.claudeCode, windows),
          title: 'Promised',
          purpose: SessionPurpose.existingSession,
          resumeExternalSessionId: minted.session.id,
        ),
      );
    });
    await refuses('a session spawned too deep', () async {
      var parent = 'deep-root';
      sessions.insert(
        Session(
          id: parent,
          repositoryId: windows.repositoryId,
          agentInstallationId: 'i-${AgentIds.claudeCode}-windows',
          title: 'Root',
          useWorktree: false,
          status: SessionStatus.created,
          createdAt: testTime,
        ),
      );
      for (var level = 1; level <= 3; level++) {
        final id = 'deep-$level';
        sessions.insert(
          Session(
            id: id,
            repositoryId: windows.repositoryId,
            agentInstallationId: 'i-${AgentIds.claudeCode}-windows',
            title: 'Level $level',
            useWorktree: false,
            status: SessionStatus.created,
            createdAt: testTime,
            parentSessionId: parent,
            parentLink: SessionLink.spawn,
          ),
        );
        parent = id;
      }
      return launcher.launch(
        SessionLaunchRequest(
          repository: repositoryIn(windows),
          installation: installationOf(AgentIds.claudeCode, windows),
          title: 'Too deep',
          purpose: SessionPurpose.newSession,
          parentSessionId: parent,
        ),
      );
    });
    await refuses(
      'an external launch with no terminal configured',
      () => launcher.launch(
        SessionLaunchRequest(
          repository: repositoryIn(windows),
          installation: installationOf(AgentIds.claudeCode, windows),
          title: 'Nowhere',
          purpose: SessionPurpose.newSession,
          surface: SessionSurface.external,
        ),
      ),
    );
    await refuses(
      'a restart of a session that is gone',
      () => launcher.restartSession('no-such-session'),
    );
    // `restartSession`'s other two refusals — an installation or a repository
    // the row names and the workspace no longer has — are not here because the
    // schema forbids the row: `agent_installation_id` is `ON DELETE RESTRICT`
    // and `repository_id` is `ON DELETE CASCADE`, so neither orphan can be
    // reached through the DAOs. They stay in the code as defences.
    await refuses('a restart of a session with no conversation yet', () {
      sessions.insert(
        Session(
          id: 'restart-no-conversation',
          repositoryId: windows.repositoryId,
          agentInstallationId: 'i-${AgentIds.claudeCode}-windows',
          title: 'Unnamed',
          useWorktree: false,
          status: SessionStatus.created,
          createdAt: testTime,
        ),
      );
      return launcher.restartSession('restart-no-conversation');
    });

    // --- a restart that succeeds, which is a launch of its own --------------
    final restarted = await launcher.launch(
      SessionLaunchRequest(
        repository: repositoryIn(windows),
        installation: installationOf(AgentIds.claudeCode, windows),
        title: 'To be restarted',
        purpose: SessionPurpose.newSession,
      ),
    );
    final restartResult = await launcher.restartSession(restarted.session.id);
    final restartRecord = {
      'sameRow': restartResult.session.id == restarted.session.id,
      ...paneRecord(restartResult),
    };

    // --- the reads every chip and every surface makes -----------------------
    //
    // The launcher is asked what a session *will* run under as often as it is
    // asked to run one, and the two answers come from the same place by
    // construction. A read that drifted from the launch above would be a
    // control whose promise and whose outcome disagree.
    final reads = <Map<String, Object?>>[];
    for (final agentId in [...AgentIds.builtIn, 'muteCli', 'noSuchAgent']) {
      reads.add({
        'agent': agentId,
        'displayName': launcher.agentDisplayName(agentId),
        'allowsConcurrentResume': launcher.allowsConcurrentResume(agentId),
        'defaultModel': launcher.defaultModelFor(agentId),
        'newSession': launcher
            .permissionFor(agentId, SessionPurpose.newSession)
            .canonical,
        'existingSession': launcher
            .permissionFor(agentId, SessionPurpose.existingSession)
            .canonical,
        'resolvedArguments': launcher
            .resolvedPermissionFor(agentId, SessionPurpose.newSession)
            .arguments,
        'resumeAction': launcher
            .resumeActionForConversation(agentId: agentId)
            .name,
        'resumeActionHeldElsewhere': launcher
            .resumeActionForConversation(
              agentId: agentId,
              heldByAnotherProcess: true,
            )
            .name,
        'resumeActionNoReattach': launcher
            .resumeActionForConversation(agentId: agentId, canReattach: false)
            .name,
      });
    }

    // The per-session reads, over one live session per agent, so the answers
    // are about a session that exists and is running rather than about a
    // lookup that failed.
    final perSession = <Map<String, Object?>>[];
    for (final agentId in AgentIds.builtIn) {
      final live = await launcher.launch(
        SessionLaunchRequest(
          repository: repositoryIn(windows),
          installation: installationOf(agentId, windows),
          title: 'Reads',
          purpose: SessionPurpose.newSession,
        ),
      );
      final id = live.session.id;
      final permission = launcher.effectivePermissionFor(id)!;
      final model = launcher.effectiveModelFor(id)!;
      final target = registry.byId(agentId)!.launch.model.models;
      final switched = launcher.setModel(
        id,
        target.isEmpty ? null : target.first.id,
      );
      perSession.add({
        'agent': agentId,
        'permission': {
          'selection': permission.selection.canonical,
          'inherited': permission.inherited,
          'unrecognised': permission.unrecognised,
        },
        'model': {
          'modelId': model.modelId,
          'defaultModelId': model.defaultModelId,
          'inherited': model.inherited,
        },
        'liveSwitchBlocker': launcher.liveModelSwitchBlockerFor(id)?.name,
        'setModel': {
          'switchedNow': switched.switchedNow,
          'command': switched.command,
          'deferral': switched.deferral?.name,
        },
        'hostedLive': launcher.hostedLive(sessionId: id),
        'revealed': launcher.reveal(id),
        'attribution': launcher.attributionFor(id)?.render('a message'),
        'sendTo': launcher.sendTo(id, 'carry on'),
        'answerPrompt': launcher.answerPrompt(id, 'y'),
        'rowAfterReads': rowOf(id),
      });
    }

    final catalogue = <String, Object?>{
      'note':
          'What every launch produces, driven through SessionLauncher against '
          'the production registry. Regenerate with '
          'KARMASHALA_WRITE_LAUNCH_GOLDEN=1; see '
          'test/features/sessions/session_launch_golden_test.dart.',
      'launches': launches,
      'externalTerminal': external,
      'shapes': shaped,
      'restart': restartRecord,
      'refusals': refusals,
      'agentReads': reads,
      'sessionReads': perSession,
    };

    // Everything the machine decides rather than the launcher: the directory
    // the packet temp folder happened to get, in both the spelling this
    // process uses and the one a WSL agent would be handed.
    var encoded = '${const JsonEncoder.withIndent('  ').convert(catalogue)}\n';
    String? wslPackets;
    try {
      wslPackets = const PathTranslator().windowsDriveToWslMount(packets.path);
    } on Object {
      wslPackets = null;
    }
    for (final (from, to) in <(String, String)>[
      if (wslPackets != null) (wslPackets, '<packets-wsl>'),
      (packets.path, '<packets>'),
    ]) {
      encoded = encoded.replaceAll(jsonEncode(from).replaceAll('"', ''), to);
    }

    final file = File(_goldenPath);
    if (Platform.environment['KARMASHALA_WRITE_LAUNCH_GOLDEN'] == '1') {
      file.writeAsStringSync(encoded);
      // ignore: avoid_print
      print('wrote $_goldenPath');
    }

    expect(
      file.existsSync(),
      isTrue,
      reason: '$_goldenPath is missing; see the header of this file',
    );
    expect(
      encoded,
      file.readAsStringSync(),
      reason:
          'What a launch produces changed. If that was intended, regenerate '
          'the golden; if it was a refactor, something moved that should not '
          'have.',
    );
  });
}
