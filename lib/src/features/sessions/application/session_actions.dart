import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/util/clock_provider.dart';
import '../../agents/application/agent_providers.dart';
import '../../agents/application/antigravity_resume_providers.dart';
import '../../agents/data/antigravity_session_resume.dart';
import '../../agents/domain/agent_descriptor.dart';
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
import '../../settings/domain/permission_mode.dart';
import '../../terminal/application/system_terminal_providers.dart';
import '../../terminal/data/system_terminal_service.dart';
import '../domain/session_event.dart';
import '../domain/session_event_types.dart';
import '../domain/session.dart';
import '../domain/session_launch.dart';
import '../domain/session_resume.dart';
import 'session_engine_provider.dart';
import 'session_launcher.dart';
import 'session_providers.dart';
import 'session_ui_providers.dart';
import 'session_working_directory.dart';

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
  ///
  /// If we are **already running** that conversation, nothing is launched: the
  /// running pane is reopened instead. Since Loop 38 a closed tab leaves its
  /// agent running, so the CLI store keeps listing a session whose process is
  /// very much alive — and resuming it started a second writer on the same
  /// transcript, which Codex refuses outright.
  ///
  /// Reattaching wins here for **every** agent, including one that would have
  /// permitted a second process: this surface can reopen the pane, and doing so
  /// is instant, keeps the scrollback and cannot fail. Whether the agent would
  /// have allowed it only matters where reopening is not on offer — see
  /// [openInSystemTerminal].
  Future<String> resumeImported(ImportedSession session) async {
    final launcher = _ref.read(sessionLauncherProvider);
    final action = launcher.resumeActionForConversation(
      agentId: session.cli,
      externalSessionId: session.externalId,
    );
    final running = launcher.runningSessionWithExternalId(session.externalId);
    if (action == ResumeAction.reattach && running != null) {
      launcher.reveal(running.id);
      // Same replacement the launch path does: the imported row was only ever a
      // second record of a session we own, and we are now showing that one.
      _dropImported(session);
      return running.id;
    }

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
    _dropImported(session);
    _ref.read(selectedSessionIdProvider.notifier).select(started.id);
    return started.id;
  }

  /// Drops the imported record for [session] and deselects it, leaving the CLI
  /// store file alone. Shared by both resume outcomes — launched, and revealed
  /// because it was already running — so the two cannot tidy up differently.
  void _dropImported(ImportedSession session) {
    _ref.read(importedSessionDaoProvider).delete(session.id);
    if (_ref.read(selectedImportedSessionIdProvider) == session.id) {
      _ref.read(selectedImportedSessionIdProvider.notifier).select(null);
    }
    _bump();
  }

  /// Resumes [session] and immediately sends [text] to it — the flow behind the
  /// imported session's message box, so typing a reply continues the session in
  /// place instead of spawning a separate one.
  ///
  /// Delivery goes through [continueSession] rather than the engine, so the text
  /// is typed into the PTY the resume just produced — the one write path into
  /// the agent. It also means a session that was *already* running receives the
  /// message instead of the send being aimed at an engine that never started it.
  Future<void> resumeAndSend(ImportedSession session, String text) async {
    final id = await resumeImported(session);
    await continueSession(id, text);
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
          .read(sessionLauncherProvider)
          .permissionFor(
            installation.agentId,
            SessionPurpose.existingSession,
            // The session's own mode, when it has one: a resume runs under what
            // this session carries, not under whatever the global default has
            // become since it started.
            sessionMode: session.permissionMode,
          );
      await engine.resume(
        session: session,
        // Where this session was actually running, when we know: the CLIs key
        // their conversation stores by directory, so the root is a fallback
        // rather than an answer. A directory that has gone away falls back to
        // it rather than failing the resume.
        workingDirectory: directoryOrFallback(
          _ref,
          directory: sessionWorkingDirectoryOf(_ref, session),
          fallback: repo.path,
        ).directory,
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
          .read(sessionLauncherProvider)
          .permissionFor(session.cli, SessionPurpose.existingSession),
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
          .read(sessionLauncherProvider)
          .permissionFor(
            installation.agentId,
            SessionPurpose.existingSession,
            // The session's own mode, when it has one: a resume runs under what
            // this session carries, not under whatever the global default has
            // become since it started.
            sessionMode: session.permissionMode,
          ),
      // No existence check: nothing is being started, and a command the user
      // copies for later should name the directory the conversation belongs
      // to even if that folder is not mounted at this moment.
      cwd: (sessionWorkingDirectoryOf(_ref, session) ?? repo.path).path,
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
    final installation =
        _ref
            .read(sessionLauncherProvider)
            .defaultInstallationIn(repo.path.environmentId) ??
        installs.first;
    return shellCommandLine(
      agentExecutable: installation.executable.path,
      cli: installation.agentId,
      permissionMode: _ref
          .read(sessionLauncherProvider)
          .permissionFor(installation.agentId, SessionPurpose.newSession),
      cwd: repo.path.path,
    );
  }

  /// Opens [session] in an external [terminal] (Windows Terminal, WezTerm, …),
  /// starting in its repository and running the agent's resume command. Throws
  /// if the repository/environment is no longer available.
  ///
  /// Refuses when we are already running that conversation **and the agent will
  /// not share it**: the external terminal would be a second writer, which is
  /// not something reopening a tab can stand in for, so the user is told in
  /// plain words rather than shown the CLI's own JSON-RPC refusal.
  ///
  /// For an agent that permits it — Claude Code — this is allowed and is the
  /// point: a second terminal listening to the same conversation.
  Future<void> openInSystemTerminal(
    ImportedSession session,
    SystemTerminal terminal,
  ) async {
    _ref
        .read(sessionLauncherProvider)
        .refuseIfForbidden(
          agentId: session.cli,
          externalSessionId: session.externalId,
        );
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
          .read(sessionLauncherProvider)
          .permissionFor(session.cli, SessionPurpose.existingSession),
    );
    _refuseCommandThatCannotResume(command, session.externalId, session.cli);
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
  ///
  /// Refuses a session whose pane is still live **when its agent forbids a
  /// second process**, for the same reason [openInSystemTerminal] does.
  Future<void> openSessionInSystemTerminal(
    String sessionId,
    SystemTerminal terminal,
  ) async {
    final session = _ref.read(sessionDaoProvider).getById(sessionId);
    if (session == null) {
      throw StateError('This session no longer exists.');
    }
    final installationForGuard = _ref
        .read(agentInstallationDaoProvider)
        .getById(session.agentInstallationId);
    _ref
        .read(sessionLauncherProvider)
        .refuseIfForbidden(
          // An installation we can no longer resolve resolves to no capability,
          // which is `false` — the safe answer, and the same one an unknown
          // agent gets.
          agentId: installationForGuard?.agentId ?? '',
          sessionId: sessionId,
          externalSessionId: session.externalSessionId,
        );
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
        await _recoverExternalSessionId(session, repo, installation) ??
        await _continuableConversationFor(session);
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
    // Resolved once and used twice: the command line's `cd` and the terminal's
    // own start directory must never disagree.
    final directory = directoryOrFallback(
      _ref,
      directory: sessionWorkingDirectoryOf(_ref, session),
      fallback: repo.path,
    ).directory;
    final command = resumeCommandLine(
      agentExecutable: installation.executable.path,
      cli: installation.agentId,
      externalId: externalId,
      environment: env,
      cwd: directory,
      permissionMode: _ref
          .read(sessionLauncherProvider)
          .permissionFor(
            installation.agentId,
            SessionPurpose.existingSession,
            // The session's own mode, when it has one: a resume runs under what
            // this session carries, not under whatever the global default has
            // become since it started.
            sessionMode: session.permissionMode,
          ),
    );
    _refuseCommandThatCannotResume(command, externalId, installation.agentId);
    // For WSL the cwd is handled inside the wrapped `wsl --cd`; only host
    // shells take a start directory.
    final cwd = env.wslDistribution == null ? directory.path : null;
    await _ref
        .read(systemTerminalServiceProvider)
        .launch(terminal, command: command, workingDirectory: cwd);
  }

  /// Refuses a command line that would start a *new* conversation while
  /// claiming to continue [externalId].
  ///
  /// `resumeCommandLine` builds its resume arguments from a hard-coded switch on
  /// `claudeCode`/`codex` rather than from the descriptor's own
  /// `interactiveResume`, so for anything else it produces the bare executable
  /// — which, run in a terminal, opens a fresh conversation wearing an old
  /// session's name. That is a wider gap than this guard, and it belongs to the
  /// terminal feature that owns the builder; what is caught here is the part
  /// this branch made reachable.
  ///
  /// **Scoped to the agent whose store this branch learned an id from.** Before
  /// attribution and `_continuableConversationFor`, an Antigravity session had
  /// no CLI id at all, so this method threw the "no resumable id" error long
  /// before building a command. Now it has one, and without this the user would
  /// be handed a terminal quietly running a *different* conversation.
  ///
  /// The test itself is against the **built command**, not against an agent
  /// name, so the day `resumeCommandLine` reads the registry this stops
  /// refusing by itself.
  void _refuseCommandThatCannotResume(
    List<String> command,
    String externalId,
    String agentId,
  ) {
    if (externalId.isEmpty) return;
    final descriptor = _ref.read(agentRegistryProvider).byId(agentId);
    if (descriptor?.store?.format != AgentStoreFormat.antigravityStore) return;
    if (command.any((argument) => argument.contains(externalId))) return;
    throw StateError(
      'Opening this in an external terminal would start a new '
      '${descriptor!.displayName} conversation instead of continuing '
      '$externalId: Karmashala only builds external-terminal resume commands '
      'for Claude Code and Codex. Open the session in Karmashala instead, '
      'where the agent is launched from its own registry entry.',
    );
  }

  /// The conversation an agent's own store says this session's directory last
  /// used, recorded on the row so the rest of the resume is ordinary.
  ///
  /// The last of three ways to answer "which conversation is this?", after the
  /// row's own id and [_recoverExternalSessionId]'s transcript match. It exists
  /// because `agy` gives neither: it mints its own id, tells us nothing, and
  /// writes a transcript we cannot read — so before this, every stopped
  /// Antigravity session hit "No resumable CLI session id could be found" while
  /// its store held the answer.
  ///
  /// A **refusal is thrown in the store's own words** rather than returned as
  /// null: "the store names no conversation here" and "another session already
  /// holds the one it names" are different problems, and collapsing them into
  /// the generic sentence is the bug being fixed. `null` means only that this
  /// agent has no such notion, and the caller's own message stands.
  Future<String?> _continuableConversationFor(Session session) async {
    final plan = await _ref.read(antigravityResumePlannerProvider)(session);
    if (plan == null) return null;
    if (plan is AntigravityResumeRefused) throw StateError(plan.reason);
    final conversationId = conversationIn(plan);
    if (conversationId == null) return null;
    // Recorded, exactly as `_recoverExternalSessionId` records what it finds:
    // the session is about to be continued as that conversation, so the row
    // should say so before anything else asks.
    _ref.read(sessionDaoProvider).updateExternalSessionId(
      session.id,
      conversationId,
    );
    return conversationId;
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
