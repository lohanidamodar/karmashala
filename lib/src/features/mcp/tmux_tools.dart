import 'dart:io';
import 'dart:math';

import 'package:riverpod/riverpod.dart';

import '../../core/process/command_runner_providers.dart';
import '../agents/application/agent_providers.dart';
import '../cli_detection/application/cli_detection_providers.dart';
import '../environments/application/environment_providers.dart';
import 'package:agent_cli/process.dart';
import '../repositories/application/repository_providers.dart';
import '../terminal/application/system_terminal_providers.dart';
import '../terminal/data/system_terminal_service.dart';
import 'agent_lookup.dart';
import 'package:karmashala_mcp/launch.dart';

/// Opening several imported sessions as tmux windows in one terminal tab.
/// `tmux_orchestration.dart` builds the script and knows nothing about this app.
class TmuxControlTools {
  TmuxControlTools(this._container);

  final ProviderContainer _container;

  static const Set<String> _names = <String>{'open_sessions_in_tmux'};

  static bool handles(String name) => _names.contains(name);

  Future<Object?> call(String name, Map<String, dynamic> args) async =>
      switch (name) {
        'open_sessions_in_tmux' => _openSessionsInTmux(
          (args['ids'] as List?)?.whereType<String>().toList() ??
              const <String>[],
          name: args['name'] as String?,
        ),
        _ => throw ArgumentError('Unknown tool: $name'),
      };

  Future<Object?> _openSessionsInTmux(List<String> ids, {String? name}) async {
    if (ids.isEmpty) throw ArgumentError('No session ids given.');
    final importedDao = _container.read(importedSessionDaoProvider);
    final repositoryDao = _container.read(repositoryDaoProvider);
    final envDao = _container.read(executionEnvironmentDaoProvider);

    final windows = <TmuxWindow>[];
    ExecutionEnvironment? distroEnv;
    for (final id in ids) {
      final session = importedDao.getById(id);
      if (session == null) throw StateError('Session not found: $id');
      final env = envDao.getById(session.environmentId);
      if (env == null || env.wslDistribution == null) {
        throw StateError(
          'Session "${session.displayTitle}" is not in a WSL environment; '
          'tmux grouping requires WSL sessions.',
        );
      }
      distroEnv ??= env;
      if (env.id != distroEnv.id) {
        throw StateError(
          'All sessions must be in the same WSL distribution '
          '(${distroEnv.wslDistribution}).',
        );
      }
      final repo = repositoryDao.getById(session.repositoryId);
      final install = installFor(
        _container,
        session.cli,
        session.environmentId,
      );
      if (repo == null || install == null) {
        throw StateError('Repository or agent missing for "$id".');
      }
      // The same registry read as every other resume surface: this switch used
      // to hand `--resume <id>` to any agent, and the window died on it.
      final registry = _container.read(agentRegistryProvider);
      final refusal = resumeRefusalFor(
        registry,
        session.cli,
        session.externalId,
      );
      if (refusal != null) {
        throw StateError('Session "${session.displayTitle}": $refusal');
      }
      final parts = [
        install.executable.path,
        ...permissionArgsFor(
          session.cli,
          resumePermissionFor(_container, session.cli),
          registry: registry,
        ),
        ...resumeArgsFor(session.cli, session.externalId, registry: registry),
      ];
      windows.add(
        TmuxWindow(
          label: tmuxSafeName(session.displayTitle, fallback: 'session'),
          cwd: repo.path.path,
          command: parts.join(' '),
        ),
      );
    }

    final env = distroEnv!;
    final sessionName = tmuxSafeName(name ?? 'karmashala', fallback: 'cg');
    final script = buildTmuxScript(sessionName, windows);

    // Write the script into the distro's /tmp via its UNC path, so nothing has
    // to survive quoting through the terminal → wsl → bash chain.
    final scriptWslPath =
        '/tmp/karmashala-tmux-${Random().nextInt(1 << 32)}.sh';
    final windowsEnv = _windowsEnv();
    if (windowsEnv == null) throw StateError('No Windows host environment.');
    final uncPath = _container
        .read(pathTranslatorProvider)
        .translate(
          EnvironmentPath(environmentId: env.id, path: scriptWslPath),
          from: env,
          to: windowsEnv,
        )
        .path;
    await File(uncPath).writeAsString(script, flush: true);

    final terminal = await _container.read(
      defaultSystemTerminalProvider.future,
    );
    if (terminal == null) {
      throw StateError('No external terminal is configured.');
    }
    await _container
        .read(systemTerminalServiceProvider)
        .launch(
          terminal,
          command: [
            'wsl.exe',
            '-d',
            env.wslDistribution!,
            '--',
            'bash',
            scriptWslPath,
          ],
        );
    return {'opened': windows.length, 'tmuxSession': sessionName};
  }

  ExecutionEnvironment? _windowsEnv() {
    for (final env
        in _container.read(executionEnvironmentDaoProvider).getAll()) {
      if (env.kind == EnvironmentKind.windowsNative) return env;
    }
    return null;
  }
}

/// The schema for [TmuxControlTools].
const List<Map<String, dynamic>> tmuxToolSchemas = [
  {
    'name': 'open_sessions_in_tmux',
    'description':
        'Open several sessions together as windows in a single tmux session '
        '(WSL), in one new terminal tab. All sessions must live in the same '
        'WSL distribution. Pass the session ids from list_sessions. '
        'Non-destructive: if a tmux session with the given name already '
        'exists it is NOT killed — the sessions are appended as new windows '
        'without switching the focused window of any running tab.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'ids': {
          'type': 'array',
          'items': {'type': 'string'},
          'description': 'Session ids to open together.',
        },
        'name': {
          'type': 'string',
          'description': 'Optional tmux session name.',
        },
      },
      'required': ['ids'],
    },
  },
];
