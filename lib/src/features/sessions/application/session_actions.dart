import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/util/clock_provider.dart';
import '../../agents/application/agent_providers.dart';
import '../../agents/domain/agent_installation.dart';
import '../../cli_detection/application/cli_detection_providers.dart';
import '../../cli_detection/data/cli_transcript_reader.dart';
import '../../cli_detection/domain/detected_session.dart';
import '../../cli_detection/domain/imported_session.dart';
import '../../environments/application/environment_providers.dart';
import '../../environments/domain/environment_path.dart';
import '../../repositories/application/repository_providers.dart';
import '../../repositories/domain/repository.dart';
import '../../settings/application/settings_controller.dart';
import '../../terminal/application/system_terminal_providers.dart';
import '../../terminal/data/system_terminal_service.dart';
import '../domain/session_event.dart';
import '../domain/session_event_types.dart';
import 'session_engine_provider.dart';
import 'session_providers.dart';
import 'session_ui_providers.dart';

/// Rename/delete operations available for **every** session in the app — native
/// engine sessions and imported CLI sessions alike. Imported operations also
/// propagate to the originating CLI store (best-effort).
class SessionActions {
  SessionActions(this._ref);
  final Ref _ref;

  void renameNative(String id, String title) {
    _ref.read(sessionDaoProvider).updateTitle(id, title);
    _bump();
  }

  void deleteNative(String id) {
    _ref.read(sessionDaoProvider).delete(id);
    if (_ref.read(selectedSessionIdProvider) == id) {
      _ref.read(selectedSessionIdProvider.notifier).select(null);
    }
    _bump();
  }

  Future<void> renameImported(ImportedSession session, String title) async {
    _ref.read(importedSessionDaoProvider).updateTitle(session.id, title);
    try {
      await _ref
          .read(cliSessionMutatorProvider)
          .rename(_toDetected(session), title);
    } catch (_) {
      // CLI store unavailable — the workspace title is still updated.
    }
    _bump();
  }

  Future<void> deleteImported(ImportedSession session) async {
    _ref.read(importedSessionDaoProvider).delete(session.id);
    try {
      await _ref.read(cliSessionMutatorProvider).delete(_toDetected(session));
    } catch (_) {}
    if (_ref.read(selectedImportedSessionIdProvider) == session.id) {
      _ref.read(selectedImportedSessionIdProvider.notifier).select(null);
    }
    _bump();
  }

  /// Resumes an imported CLI session in place: it becomes a live native session
  /// (seeded with its prior transcript and launched with `--resume`), and the
  /// imported entry is replaced by it so there is no duplicate. Returns the live
  /// session's id. Throws if the repository or a matching installation is gone.
  Future<String> resumeImported(ImportedSession session) async {
    final repo = _ref.read(repositoryDaoProvider).getById(session.repositoryId);
    if (repo == null) {
      throw StateError(
        'Repository for this session is no longer in the workspace.',
      );
    }
    final installs = _ref
        .read(agentInstallationDaoProvider)
        .getByEnvironment(session.environmentId)
        .where((i) => i.agentKind == session.cli)
        .toList();
    if (installs.isEmpty) {
      throw StateError(
        'No ${session.cli.name} installation in ${session.environmentId}. '
        'Run "Discover agents" in Settings first.',
      );
    }
    final permission = _ref
        .read(settingsControllerProvider)
        .permissionsFor(session.cli)
        .existingSessions;
    final started = await _ref
        .read(sessionEngineProvider)
        .start(
          repository: repo,
          installation: installs.first,
          title: session.displayTitle,
          resumeSessionId: session.externalId,
          permissionMode: permission,
        );
    await _seedHistory(started.id, session);
    // Replace the imported entry with the now-live session (drop only our row,
    // keeping the CLI store file intact).
    _ref.read(importedSessionDaoProvider).delete(session.id);
    if (_ref.read(selectedImportedSessionIdProvider) == session.id) {
      _ref.read(selectedImportedSessionIdProvider.notifier).select(null);
    }
    _ref.read(selectedSessionIdProvider.notifier).select(started.id);
    _bump();
    return started.id;
  }

  /// Resumes [session] and immediately sends [text] to it — the flow behind the
  /// imported session's message box, so typing a reply continues the session in
  /// place instead of spawning a separate one.
  Future<void> resumeAndSend(ImportedSession session, String text) async {
    final id = await resumeImported(session);
    final trimmed = text.trim();
    if (trimmed.isNotEmpty) {
      await _ref.read(sessionEngineProvider).sendMessage(id, trimmed);
    }
  }

  /// Copies the imported CLI session's prior transcript into the resumed native
  /// session's event log so resuming continues the conversation instead of
  /// starting blank. Capped to the most recent messages; best-effort.
  Future<void> _seedHistory(String sessionId, ImportedSession session) async {
    try {
      final messages = await readCliTranscript(session.filePath, session.cli);
      if (messages.isEmpty) return;
      const cap = 500;
      final recent = messages.length > cap
          ? messages.sublist(messages.length - cap)
          : messages;
      final eventDao = _ref.read(sessionEventDaoProvider);
      final now = _ref.read(clockProvider).nowUtc();
      for (final m in recent) {
        final type = switch (m.role) {
          'user' => SessionEventTypes.userMessage,
          'agent' => SessionEventTypes.agentMessage,
          _ => null,
        };
        if (type == null) continue;
        eventDao.append(
          SessionEvent(
            sessionId: sessionId,
            seq: 0,
            type: type,
            payload: jsonEncode({'text': m.text, 'history': true}),
            createdAt: now,
          ),
        );
      }
    } catch (_) {
      // History seeding is best-effort — resume still works without it.
    }
  }

  /// Launches a fresh agent session in an external [terminal]: runs the agent's
  /// executable in [repo]'s directory (wrapped in `wsl.exe` for WSL repos).
  Future<void> startNewInSystemTerminal({
    required Repository repo,
    required AgentInstallation installation,
    required SystemTerminal terminal,
  }) async {
    final env = _ref
        .read(executionEnvironmentDaoProvider)
        .getById(repo.path.environmentId);
    if (env == null) {
      throw StateError('The repository\'s environment is unavailable.');
    }
    final exe = installation.executable.path;
    final command = env.wslDistribution != null
        ? [
            'wsl.exe',
            '-d',
            env.wslDistribution!,
            '--cd',
            repo.path.path,
            '--',
            exe,
          ]
        : [exe];
    final cwd = env.wslDistribution == null ? repo.path.path : null;
    await _ref
        .read(systemTerminalServiceProvider)
        .launch(terminal, command: command, workingDirectory: cwd);
  }

  /// Opens [session] in an external [terminal] (Windows Terminal, WezTerm, …),
  /// starting in its repository and running the agent's resume command. Throws
  /// if the repository/environment is no longer available.
  Future<void> openInSystemTerminal(
    ImportedSession session,
    SystemTerminal terminal,
  ) async {
    final repo = _ref.read(repositoryDaoProvider).getById(session.repositoryId);
    if (repo == null) {
      throw StateError(
        'Repository for this session is no longer in the workspace.',
      );
    }
    final env = _ref
        .read(executionEnvironmentDaoProvider)
        .getById(repo.path.environmentId);
    if (env == null) {
      throw StateError('The session\'s environment is unavailable.');
    }
    final installs = _ref
        .read(agentInstallationDaoProvider)
        .getByEnvironment(session.environmentId)
        .where((i) => i.agentKind == session.cli)
        .toList();
    final agentExecutable = installs.isNotEmpty
        ? installs.first.executable.path
        : session.cli.name;
    final command = resumeCommandLine(
      agentExecutable: agentExecutable,
      cli: session.cli.name,
      externalId: session.externalId,
      environment: env,
      cwd: repo.path,
    );
    // For WSL the cwd is handled inside the wrapped `wsl --cd`; only host shells
    // take a start directory.
    final cwd = env.wslDistribution == null ? repo.path.path : null;
    await _ref
        .read(systemTerminalServiceProvider)
        .launch(terminal, command: command, workingDirectory: cwd);
  }

  DetectedSession _toDetected(ImportedSession session) => DetectedSession(
    cli: session.cli,
    sessionId: session.externalId,
    cwd: EnvironmentPath(environmentId: session.environmentId, path: ''),
    filePath: session.filePath,
    storeHome: session.storeHome,
  );

  void _bump() => _ref.read(sessionsRevisionProvider.notifier).bump();
}

final sessionActionsProvider = Provider<SessionActions>(
  (ref) => SessionActions(ref),
);
