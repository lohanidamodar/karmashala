import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/util/clock_provider.dart';
import '../../agents/application/agent_installations_controller.dart';
import '../../agents/application/agent_providers.dart';
import '../../agents/domain/agent_installation.dart';
import '../../cli_detection/application/cli_detection_providers.dart';
import '../../cli_detection/application/detected_project_merger.dart';
import '../../cli_detection/data/cli_transcript_reader.dart';
import '../../cli_detection/domain/detected_session.dart';
import '../../cli_detection/domain/imported_session.dart';
import '../../environments/application/environment_providers.dart';
import '../../environments/domain/environment_path.dart';
import '../../repositories/application/repository_providers.dart';
import '../../repositories/domain/repository.dart';
import '../../settings/application/settings_controller.dart';
import '../../settings/domain/permission_mode.dart';
import '../../terminal/application/system_terminal_providers.dart';
import '../../terminal/data/system_terminal_service.dart';
import '../domain/session_event.dart';
import '../domain/session_event_types.dart';
import '../domain/session.dart';
import '../domain/session_launch.dart';
import 'session_engine_provider.dart';
import 'session_launcher.dart';
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

  Future<void> deleteNative(String id, {bool deleteFromCli = true}) async {
    final session = _ref.read(sessionDaoProvider).getById(id);
    if (session == null) return;
    if (deleteFromCli) {
      final repo = _ref
          .read(repositoryDaoProvider)
          .getById(session.repositoryId);
      final installation = _ref
          .read(agentInstallationDaoProvider)
          .getById(session.agentInstallationId);
      if (repo == null || installation == null) {
        throw StateError('The session repository or agent is unavailable.');
      }
      final externalId =
          session.externalSessionId ??
          await _recoverExternalSessionId(session, repo, installation);
      if (externalId == null) {
        throw StateError(
          'The CLI session could not be identified. Uncheck "Delete from CLI '
          'store" to remove only the app record.',
        );
      }
      final detected = await _detectedSessionById(
        installation.agentId,
        externalId,
      );
      if (detected == null) {
        throw StateError('The CLI session file could not be found.');
      }
      await _ref.read(cliSessionMutatorProvider).delete(detected);
    }
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

  Future<void> deleteImported(
    ImportedSession session, {
    bool deleteFromCli = true,
  }) async {
    if (deleteFromCli) {
      await _ref.read(cliSessionMutatorProvider).delete(_toDetected(session));
    }
    _ref.read(importedSessionDaoProvider).delete(session.id);
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
        .where((i) => i.agentId == session.cli)
        .toList();
    if (installs.isEmpty) {
      throw StateError(
        'No ${session.cli} installation in ${session.environmentId}. '
        'Run "Discover agents" in Settings first.',
      );
    }
    // Through the one launcher, so a resumed session is the same kind of thing
    // as a new one: a PTY, a row, and the *existing-session* permission mode —
    // which this path used to apply to `SessionEngine.start`, i.e. to a
    // genuinely new session (Loop 33 §6.1).
    final launched = await _ref
        .read(sessionLauncherProvider)
        .launch(
          SessionLaunchRequest(
            repository: repo,
            installation: installs.first,
            title: session.displayTitle,
            purpose: SessionPurpose.existingSession,
            resumeExternalSessionId: session.externalId,
          ),
        );
    final started = launched.session;
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

  /// Sends [text] to a native session, relaunching its agent first when the
  /// session has ended — so the message box always works, not only while the
  /// agent happens to be live. Throws a clear error if the repository or agent is
  /// no longer available.
  Future<void> continueSession(String sessionId, String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;

    // A PTY-hosted session is typed into, not messaged: chat and terminal are
    // two views of one session, so there is exactly one write path into the
    // agent and the two views cannot get out of step.
    if (_ref.read(sessionLauncherProvider).sendTo(sessionId, trimmed)) return;

    final engine = _ref.read(sessionEngineProvider);

    if (!engine.isActive(sessionId)) {
      final session = _ref.read(sessionDaoProvider).getById(sessionId);
      if (session == null) {
        throw StateError('This session no longer exists.');
      }
      final repo = _ref
          .read(repositoryDaoProvider)
          .getById(session.repositoryId);
      if (repo == null) {
        throw StateError('The session\'s repository is no longer available.');
      }
      final installation = _ref
          .read(agentInstallationDaoProvider)
          .getById(session.agentInstallationId);
      if (installation == null) {
        throw StateError(
          'The agent for this session is not installed. '
          'Run "Discover agents" in Settings.',
        );
      }
      final permission = _ref
          .read(settingsControllerProvider)
          .permissionsFor(installation.agentId)
          .existingSessions;
      await engine.resume(
        session: session,
        workingDirectory: session.worktree ?? repo.path,
        installation: installation,
        permissionMode: permission,
        resumeSessionId: session.externalSessionId,
      );
      _bump();
    }

    await engine.sendMessage(sessionId, trimmed);
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
  Future<Session> startNewInSystemTerminal({
    required Repository repo,
    required AgentInstallation installation,
    required SystemTerminal terminal,
    PermissionMode? permissionMode,
    String? title,
  }) async {
    // Now goes through the one launcher, which means it **records a session**.
    // Spawning an external terminal used to change real-world state with no row
    // and no UI feedback; the session only reappeared later, as an unrelated
    // `ImportedSession` (Loop 33 §6.5).
    //
    // [terminal] is no longer chosen here: the launcher resolves the configured
    // default so the dialog, the mini launcher and the MCP tool cannot pick
    // three different ones. The parameter stays so callers that already asked
    // the user keep compiling, and is honoured by preference below.
    final launched = await _ref
        .read(sessionLauncherProvider)
        .launch(
          SessionLaunchRequest(
            repository: repo,
            installation: installation,
            title: title ?? 'Session',
            purpose: SessionPurpose.newSession,
            surface: SessionSurface.external,
            permissionOverride: permissionMode,
            externalTerminal: terminal,
          ),
        );
    return launched.session;
  }

  /// A shell command (cd + resume, with permission flags) for [session], to copy
  /// to the clipboard. Throws if the repository is gone.
  String resumeShellCommand(ImportedSession session) {
    final repo = _ref.read(repositoryDaoProvider).getById(session.repositoryId);
    if (repo == null) {
      throw StateError('This session\'s repository is no longer available.');
    }
    final installs = _ref
        .read(agentInstallationDaoProvider)
        .getByEnvironment(session.environmentId)
        .where((i) => i.agentId == session.cli)
        .toList();
    final exe = installs.isNotEmpty
        ? installs.first.executable.path
        : session.cli;
    return shellCommandLine(
      agentExecutable: exe,
      cli: session.cli,
      externalId: session.externalId,
      permissionMode: _ref
          .read(settingsControllerProvider)
          .permissionsFor(session.cli)
          .existingSessions,
      cwd: repo.path.path,
    );
  }

  /// A shell command (cd + resume, with permission flags) for native [sessionId].
  String nativeResumeShellCommand(String sessionId) {
    final session = _ref.read(sessionDaoProvider).getById(sessionId);
    if (session == null) throw StateError('This session no longer exists.');
    final repo = _ref.read(repositoryDaoProvider).getById(session.repositoryId);
    if (repo == null) {
      throw StateError('This session\'s repository is no longer available.');
    }
    final installation = _ref
        .read(agentInstallationDaoProvider)
        .getById(session.agentInstallationId);
    if (installation == null) {
      throw StateError('The agent for this session is not installed.');
    }
    return shellCommandLine(
      agentExecutable: installation.executable.path,
      cli: installation.agentId,
      externalId: session.externalSessionId,
      permissionMode: _ref
          .read(settingsControllerProvider)
          .permissionsFor(installation.agentId)
          .existingSessions,
      cwd: (session.worktree ?? repo.path).path,
    );
  }

  /// A shell command (cd + fresh session, with permission flags) for [projectId]'s
  /// first repository with the default agent.
  String newSessionShellCommand(String projectId) {
    final repos = _ref.read(repositoryDaoProvider).getByProject(projectId);
    if (repos.isEmpty) {
      throw StateError('This project has no Git repositories to run in.');
    }
    final repo = repos.first;
    final installs = _ref
        .read(agentInstallationDaoProvider)
        .getByEnvironment(repo.path.environmentId);
    if (installs.isEmpty) {
      throw StateError(
        'No agent installed in ${repo.path.environmentId}. '
        'Run "Discover agents" in Settings.',
      );
    }
    final settings = _ref.read(settingsControllerProvider);
    final installation =
        resolveDefaultInstallation(
          installs,
          defaultInstallationId: settings.defaultAgentInstallationId,
          defaultAgentId: settings.defaultAgent,
        ) ??
        installs.first;
    return shellCommandLine(
      agentExecutable: installation.executable.path,
      cli: installation.agentId,
      permissionMode: _ref
          .read(settingsControllerProvider)
          .permissionsFor(installation.agentId)
          .newSessions,
      cwd: repo.path.path,
    );
  }

  /// Starts a new session for [projectId] in an external [terminal] using the
  /// configured default agent (or the first installed one) in the project's first
  /// repository. For the mini launcher, where there is no New-session dialog.
  Future<void> startNewSessionInTerminal(
    String projectId,
    SystemTerminal terminal,
  ) async {
    final repos = _ref.read(repositoryDaoProvider).getByProject(projectId);
    if (repos.isEmpty) {
      throw StateError('This project has no Git repositories to run in.');
    }
    final repo = repos.first;
    final installs = _ref
        .read(agentInstallationDaoProvider)
        .getByEnvironment(repo.path.environmentId);
    if (installs.isEmpty) {
      throw StateError(
        'No agent installed in ${repo.path.environmentId}. '
        'Run "Discover agents" in Settings.',
      );
    }
    final installation =
        _ref
            .read(sessionLauncherProvider)
            .defaultInstallationIn(repo.path.environmentId) ??
        installs.first;
    await startNewInSystemTerminal(
      repo: repo,
      installation: installation,
      terminal: terminal,
    );
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
        .where((i) => i.agentId == session.cli)
        .toList();
    final agentExecutable = installs.isNotEmpty
        ? installs.first.executable.path
        : session.cli;
    final command = resumeCommandLine(
      agentExecutable: agentExecutable,
      cli: session.cli,
      externalId: session.externalId,
      environment: env,
      cwd: repo.path,
      permissionMode: _ref
          .read(settingsControllerProvider)
          .permissionsFor(session.cli)
          .existingSessions,
    );
    // For WSL the cwd is handled inside the wrapped `wsl --cd`; only host shells
    // take a start directory.
    final cwd = env.wslDistribution == null ? repo.path.path : null;
    await _ref
        .read(systemTerminalServiceProvider)
        .launch(terminal, command: command, workingDirectory: cwd);
  }

  /// Opens the native [sessionId] in an external [terminal], starting in its
  /// repository and running the agent there. Throws a clear error if the repo or
  /// agent installation is no longer available.
  Future<void> openSessionInSystemTerminal(
    String sessionId,
    SystemTerminal terminal,
  ) async {
    final session = _ref.read(sessionDaoProvider).getById(sessionId);
    if (session == null) {
      throw StateError('This session no longer exists.');
    }
    final repo = _ref.read(repositoryDaoProvider).getById(session.repositoryId);
    if (repo == null) {
      throw StateError('The session\'s repository is no longer available.');
    }
    final installation = _ref
        .read(agentInstallationDaoProvider)
        .getById(session.agentInstallationId);
    if (installation == null) {
      throw StateError(
        'The agent for this session is not installed. '
        'Run "Discover agents" in Settings.',
      );
    }
    final externalId =
        session.externalSessionId ??
        await _recoverExternalSessionId(session, repo, installation);
    if (externalId == null || externalId.isEmpty) {
      throw StateError(
        'No resumable CLI session id could be found. For an older session, '
        'open its imported CLI history entry instead; new sessions capture '
        'their id automatically.',
      );
    }
    final env = _ref
        .read(executionEnvironmentDaoProvider)
        .getById(repo.path.environmentId);
    if (env == null) {
      throw StateError('The session\'s environment is unavailable.');
    }
    final command = resumeCommandLine(
      agentExecutable: installation.executable.path,
      cli: installation.agentId,
      externalId: externalId,
      environment: env,
      cwd: session.worktree ?? repo.path,
      permissionMode: _ref
          .read(settingsControllerProvider)
          .permissionsFor(installation.agentId)
          .existingSessions,
    );
    final cwd = env.wslDistribution == null
        ? (session.worktree ?? repo.path).path
        : null;
    await _ref
        .read(systemTerminalServiceProvider)
        .launch(terminal, command: command, workingDirectory: cwd);
  }

  /// Recovers the CLI id for sessions created before schema v5. Matching is
  /// intentionally conservative: the agent kind and repository must match and
  /// the first user message must identify exactly one CLI transcript.
  Future<String?> _recoverExternalSessionId(
    Session session,
    Repository repo,
    AgentInstallation installation,
  ) async {
    try {
      final events = _ref
          .read(sessionEventDaoProvider)
          .listForSession(session.id);
      String? firstUserMessage;
      for (final event in events) {
        if (event.type != SessionEventTypes.userMessage) continue;
        final payload = jsonDecode(event.payload);
        if (payload is Map && payload['text'] is String) {
          firstUserMessage = _normalizeMatchText(payload['text'] as String);
          if (firstUserMessage.isNotEmpty) break;
        }
      }
      final environmentDao = _ref.read(executionEnvironmentDaoProvider);
      final environments = environmentDao.getAll();
      final stores = await _ref
          .read(cliStoreLocatorProvider)
          .locate(environments);
      final detected = await _ref.read(cliDetectionServiceProvider).detect(
        stores,
        {for (final environment in environments) environment.id: environment},
      );
      final environment = environmentDao.getById(repo.path.environmentId);
      final (key, _) = canonicalProjectPath(repo.path, environment);
      final project = detected
          .where((item) => item.canonicalKey == key)
          .firstOrNull;
      if (project == null) return null;

      final candidates = [...project.sessions, ...project.subagentSessions]
          .where((candidate) => candidate.cli == installation.agentId)
          .where(
            (candidate) =>
                _ref
                    .read(sessionDaoProvider)
                    .getByExternalSessionId(candidate.sessionId) ==
                null,
          )
          .toList();
      var matches = firstUserMessage == null || firstUserMessage.isEmpty
          ? <DetectedSession>[]
          : candidates.where((candidate) {
              final preview = _normalizeMatchText(candidate.preview);
              return preview.isNotEmpty &&
                  (firstUserMessage!.startsWith(preview) ||
                      preview.startsWith(firstUserMessage));
            }).toList();
      if (matches.isEmpty) {
        final normalizedTitle = _normalizeMatchText(session.title);
        matches = candidates
            .where(
              (candidate) =>
                  candidate.title != null &&
                  _normalizeMatchText(candidate.title!) == normalizedTitle,
            )
            .toList();
      }
      if (matches.length != 1) return null;

      final recovered = matches.single.sessionId;
      _ref
          .read(sessionDaoProvider)
          .updateExternalSessionId(session.id, recovered);
      _bump();
      return recovered;
    } catch (_) {
      return null;
    }
  }

  String _normalizeMatchText(String value) =>
      value.replaceAll(RegExp(r'\s+'), ' ').trim().toLowerCase();

  Future<DetectedSession?> _detectedSessionById(
    String agentId,
    String externalId,
  ) async {
    final environments = _ref.read(executionEnvironmentDaoProvider).getAll();
    final stores = await _ref
        .read(cliStoreLocatorProvider)
        .locate(environments);
    final projects = await _ref.read(cliDetectionServiceProvider).detect(
      stores,
      {for (final environment in environments) environment.id: environment},
    );
    for (final project in projects) {
      for (final session in [
        ...project.sessions,
        ...project.subagentSessions,
      ]) {
        if (session.cli == agentId && session.sessionId == externalId) {
          return session;
        }
      }
    }
    return null;
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
