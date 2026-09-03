import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/logging/app_logger.dart';
import '../../../core/util/clock_provider.dart';
import '../../agents/application/agent_providers.dart';
import '../../agents/application/antigravity_resume_providers.dart';
import '../../agents/data/antigravity_session_resume.dart';
import '../../agents/domain/agent_descriptor.dart';
import '../../agents/domain/agent_installation.dart';
import '../../cli_detection/application/cli_detection_providers.dart';
import '../../cli_detection/application/detected_project_merger.dart';
import '../../cli_detection/data/cli_session_mutator.dart';
import '../../cli_detection/data/cli_transcript_reader.dart';
import '../../cli_detection/domain/detected_session.dart';
import '../../cli_detection/domain/imported_session.dart';
import '../../environments/application/environment_providers.dart';
import '../../environments/domain/environment_kind.dart';
import '../../environments/domain/environment_path.dart';
import '../../repositories/application/repository_providers.dart';
import '../../repositories/domain/repository.dart';
import '../../agents/domain/agent_permission_support.dart';
import '../../terminal/application/system_terminal_providers.dart';
import '../../terminal/data/system_terminal_service.dart';
import '../domain/session_event.dart';
import '../domain/session_event_types.dart';
import '../domain/session.dart';
import '../domain/session_launch.dart';
import '../domain/session_resume.dart';
import 'session_engine_provider.dart';
import 'session_launcher.dart';
import 'session_notice.dart';
import 'session_providers.dart';
import 'session_ui_providers.dart';
import 'session_working_directory.dart';
import '../../environments/domain/environment_label.dart';

/// Rename/delete operations available for **every** session in the app — native
/// engine sessions and imported CLI sessions alike. Imported operations also
/// propagate to the originating CLI store (best-effort).
class SessionActions {
  SessionActions(this._ref);
  final Ref _ref;

  /// Only the destructive path writes here. Renames and resumes are frequent,
  /// reversible and already visible in the UI; a delete that also removed the
  /// agent's own transcript is none of those things.
  static final _log = AppLogger.named('sessions.actions');

  void renameNative(String id, String title) {
    // `byUser`: this is the one event that makes a title the user's, and
    // recording it is what stops the CLI rename sync taking it back — for the
    // life of the row, not just this run of the app.
    _ref.read(sessionDaoProvider).updateTitle(id, title, byUser: true);
    // The narrowest fact the app publishes, and the most frequent: nothing but
    // this row's name moved. See `session_signal_cost_test.dart` for what the
    // coarse word used to cost — 108 session reads at a hundred sessions.
    _publish(SessionChange.renamed(id));
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
    _removeNativeRow(session, fromCliStore: deleteFromCli);
    _publish(SessionChange.removed(id));
  }

  /// Takes one native row out of the workspace, and nothing else: the row, the
  /// transcript pane if it was showing this one, and the line saying so.
  ///
  /// [fromCliStore] records what the *caller* already did to the agent's own
  /// transcript — this method never touches it. False in the bulk path even
  /// when a purge is about to run, because that purge logs its own line once it
  /// knows what it actually removed.
  ///
  /// **Publishes nothing.** The caller does, so a batch can publish once — see
  /// [deleteSessionsFromWorkspace].
  void _removeNativeRow(Session session, {required bool fromCliStore}) {
    _ref.read(sessionDaoProvider).delete(session.id);
    if (_ref.read(selectedSessionIdProvider) == session.id) {
      _ref.read(selectedSessionIdProvider.notifier).select(null);
    }
    // Deleting a session is the one act here that can reach irreversibly
    // outside the app, so it is written down. After the fact, so the line means
    // it happened rather than that it was attempted — the throws in
    // [deleteNative] all abandon the delete with the CLI store untouched.
    _log.info(
      'Deleted session ${session.id} (${session.title}): '
      'fromCliStore=$fromCliStore agent=${session.agentInstallationId}',
    );
  }

  void _removeImportedRow(ImportedSession session) {
    _ref.read(importedSessionDaoProvider).delete(session.id);
    if (_ref.read(selectedImportedSessionIdProvider) == session.id) {
      _ref.read(selectedImportedSessionIdProvider.notifier).select(null);
    }
  }

  /// Removes a whole selection of rows from the workspace as **one act**.
  ///
  /// Each kind still goes through its own removal — the same DAO delete and the
  /// same selection clearing its single delete does — but the set publishes
  /// exactly once. That is not tidiness: three bare listeners sit on
  /// `sessionsRevisionProvider` (the quick-open file index, the terminal
  /// layout, the remote controller) and each does real work per bump, so
  /// thirty-three rows published one at a time would run all three
  /// thirty-three times for one click.
  ///
  /// The CLI store is not touched here. Removing a row from the workspace is
  /// undone by re-importing it; deleting an agent's transcript is undone by
  /// nothing, so that half runs behind this and reports for itself — see
  /// [purgeSessionsFromCliStore].
  void deleteSessionsFromWorkspace({
    List<Session> natives = const [],
    List<ImportedSession> imported = const [],
  }) {
    if (natives.isEmpty && imported.isEmpty) return;
    for (final session in natives) {
      _removeNativeRow(session, fromCliStore: false);
    }
    for (final session in imported) {
      _removeImportedRow(session);
    }
    // The coarse word, deliberately: this named several rows, and a change that
    // names no single one is exactly what `sessionId: null` means. Not
    // `workspaceChanged` — no project, repository or checkout moved.
    _publish(
      const SessionChange(
        kinds: {
          SessionChangeKind.membership,
          SessionChangeKind.status,
          SessionChangeKind.placement,
        },
      ),
    );
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
    _publish(SessionChange.renamed(session.id));
  }

  /// Removes [sessions] from their agents' own stores as **one batch**.
  ///
  /// Workspace rows are not touched: the caller that has a cascade — deleting a
  /// whole project — has already dropped them, and this is the half that
  /// reaches outside the app. Never throws; what could not be removed comes
  /// back in the report so a locked file is *told to the user* rather than
  /// swallowed by the `catch (_)` this replaces.
  ///
  /// Logged after the fact, like [deleteNative], so the line means the
  /// transcripts are gone rather than that we tried.
  Future<CliDeleteReport> purgeFromCliStore(List<ImportedSession> sessions) =>
      purgeSessionsFromCliStore(imported: sessions);

  /// The same batch, for a selection that holds **both** kinds of row.
  ///
  /// An imported row already carries its own store file, so it maps straight to
  /// a [DetectedSession]. A native row carries only the conversation id, and
  /// finding the file behind it means walking the CLI stores — which is why
  /// [deleteNative] can only afford to delete one session at a time. Here every
  /// native row is looked up in **one** pass over the stores, and the
  /// transcripts of both kinds then go to [CliSessionMutator.deleteAll] as a
  /// single batch: one index pass per store rather than one per session.
  ///
  /// Never throws. A native row whose conversation cannot be identified comes
  /// back as a failure under its own title, because that is the honest report —
  /// its transcript is still on disk.
  Future<CliDeleteReport> purgeSessionsFromCliStore({
    List<Session> natives = const [],
    List<ImportedSession> imported = const [],
  }) async {
    if (natives.isEmpty && imported.isEmpty) return CliDeleteReport.empty;
    // Resolved before the first await: this may outlive the container that
    // started it, and a provider read afterwards would throw.
    final mutator = _ref.read(cliSessionMutatorProvider);
    final installations = _ref.read(agentInstallationDaoProvider);

    final targets = <DetectedSession>[for (final s in imported) _toDetected(s)];
    final failures = <CliDeleteFailure>[];
    final wanted = <(String, String), Session>{};
    for (final session in natives) {
      final agentId = installations
          .getById(session.agentInstallationId)
          ?.agentId;
      final externalId = session.externalSessionId;
      if (agentId == null || externalId == null) {
        failures.add(
          CliDeleteFailure(
            label: session.title,
            error: StateError('The CLI session could not be identified.'),
          ),
        );
        continue;
      }
      wanted[(agentId, externalId)] = session;
    }
    if (wanted.isNotEmpty) {
      final found = await _detectedByKey(wanted.keys.toSet());
      for (final entry in wanted.entries) {
        final detected = found[entry.key];
        if (detected == null) {
          failures.add(
            CliDeleteFailure(
              label: entry.value.title,
              error: StateError('The CLI session file could not be found.'),
            ),
          );
        } else {
          targets.add(detected);
        }
      }
    }

    final report = targets.isEmpty
        ? CliDeleteReport.empty
        : await mutator.deleteAll(targets);
    if (report.deleted > 0) {
      _log.info(
        'Deleted ${report.deleted} session file(s) from the CLI store '
        '(${report.failures.length + failures.length} left behind).',
      );
    }
    if (failures.isEmpty) return report;
    return CliDeleteReport(
      deleted: report.deleted,
      failures: [...report.failures, ...failures],
    );
  }

  Future<void> deleteImported(
    ImportedSession session, {
    bool deleteFromCli = true,
  }) async {
    if (deleteFromCli) {
      await _ref.read(cliSessionMutatorProvider).delete(_toDetected(session));
    }
    _removeImportedRow(session);
    _publish(SessionChange.removed(session.id));
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
        'No ${session.cli} installation in ${describeEnvironmentId(session.environmentId)}. '
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
    _publish(SessionChange.removed(session.id));
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
          .resolvedPermissionFor(
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
        permission: permission,
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
    PermissionSelection? permissionMode,
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
    _refuseWhatCannotResume(session.cli, session.externalId);
    return shellCommandLine(
      agentExecutable: exe,
      cli: session.cli,
      externalId: session.externalId,
      permission: _ref
          .read(sessionLauncherProvider)
          .permissionFor(session.cli, SessionPurpose.existingSession),
      cwd: repo.path.path,
      environment: _shellKindOf(session.environmentId),
      registry: _ref.read(agentRegistryProvider),
    );
  }

  /// The shell family a copied command has to be spelled for: the one belonging
  /// to the directory the command `cd`s into, never the host's. A Windows
  /// session gets PowerShell even when the row was adopted from a WSL store.
  EnvironmentKind _shellKindOf(String environmentId) {
    final environment = _ref
        .read(executionEnvironmentDaoProvider)
        .getById(environmentId);
    if (environment == null) {
      throw StateError('The environment "$environmentId" is not configured.');
    }
    return environment.kind;
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
    _refuseWhatCannotResume(installation.agentId, session.externalSessionId);
    final workingDirectory =
        sessionWorkingDirectoryOf(_ref, session) ?? repo.path;
    return shellCommandLine(
      agentExecutable: installation.executable.path,
      cli: installation.agentId,
      externalId: session.externalSessionId,
      permission: _ref
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
      cwd: workingDirectory.path,
      // The *working directory's* environment, not the installation's: the
      // shell that has to understand this line is the one that shell opens in.
      environment: _shellKindOf(workingDirectory.environmentId),
      registry: _ref.read(agentRegistryProvider),
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
        'No agent installed in ${describeEnvironmentId(repo.path.environmentId)}. '
        'Run "Discover agents" in Settings.',
      );
    }
    final installation =
        _ref
            .read(sessionLauncherProvider)
            .defaultInstallationIn(repo.path.environmentId) ??
        installs.first;
    // Through the same decision as the two resume commands, where it always
    // answers "nothing to refuse": this command names no conversation, so it
    // cannot be mistaken for continuing one.
    _refuseWhatCannotResume(installation.agentId, null);
    return shellCommandLine(
      agentExecutable: installation.executable.path,
      cli: installation.agentId,
      permission: _ref
          .read(sessionLauncherProvider)
          .permissionFor(installation.agentId, SessionPurpose.newSession),
      cwd: repo.path.path,
      environment: _shellKindOf(repo.path.environmentId),
      registry: _ref.read(agentRegistryProvider),
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
    _refuseWhatCannotResume(session.cli, session.externalId);
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
      permission: _ref
          .read(sessionLauncherProvider)
          .permissionFor(session.cli, SessionPurpose.existingSession),
      registry: _ref.read(agentRegistryProvider),
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
    // Resolved once and used three times: the command line's `cd`, the
    // terminal's own start directory, and the refusal below — which is about
    // the difference between this and where the conversation was written.
    final recorded = sessionWorkingDirectoryOf(_ref, session);
    final directory = directoryOrFallback(
      _ref,
      directory: recorded,
      fallback: repo.path,
    ).directory;
    // After the id is resolved, not before: `_recoverExternalSessionId` and
    // `_continuableConversationFor` can both supply one the row did not carry,
    // and it is the id we end up with that the command has to continue.
    _refuseWhatCannotResume(installation.agentId, externalId);
    // The weaker sibling of that refusal, and the reason it is a notice rather
    // than a throw is [resumeDirectoryCaveatFor]'s: this surface is where the
    // substitution actually happens — an archived worktree opens the repository
    // root here — and a session the user can no longer open at all is worse
    // than one they were warned about. Posted against the session rather than
    // raised, because the terminal is about to open either way.
    final caveat = resumeDirectoryCaveatFor(
      _ref.read(agentRegistryProvider),
      installation.agentId,
      externalId,
      recordedDirectory: recorded?.path,
      launchDirectory: directory.path,
    );
    if (caveat != null) {
      _ref
          .read(sessionNoticesProvider.notifier)
          .post(
            sessionId,
            SessionNotice(message: caveat, tone: SessionNoticeTone.warning),
          );
    }
    final command = resumeCommandLine(
      agentExecutable: installation.executable.path,
      cli: installation.agentId,
      externalId: externalId,
      environment: env,
      cwd: directory,
      permission: _ref
          .read(sessionLauncherProvider)
          .permissionFor(
            installation.agentId,
            SessionPurpose.existingSession,
            // The session's own mode, when it has one: a resume runs under what
            // this session carries, not under whatever the global default has
            // become since it started.
            sessionMode: session.permissionMode,
          ),
      registry: _ref.read(agentRegistryProvider),
    );
    // For WSL the cwd is handled inside the wrapped `wsl --cd`; only host
    // shells take a start directory.
    final cwd = env.wslDistribution == null ? directory.path : null;
    await _ref
        .read(systemTerminalServiceProvider)
        .launch(terminal, command: command, workingDirectory: cwd);
  }

  /// Refuses to build anything that would claim to continue [externalId] for an
  /// agent that cannot be told to continue anything.
  ///
  /// **This replaces a stopgap, and the replacement is narrower on purpose.**
  /// The old guard fired on `store.format == antigravityStore` and tested the
  /// *built command* for the id, because the builder chose its resume arguments
  /// from a hard-coded `switch (cli)` and so produced a bare executable for
  /// every agent outside it. It was written to stop refusing by itself once the
  /// builder read the registry — which it now does, so testing the builder's
  /// output against the same descriptor that produced it would prove nothing.
  ///
  /// What is left is the case the registry itself calls hopeless: an agent
  /// whose `interactiveResume` is [AgentResumeStyle.unsupported], or one this
  /// registry has never heard of. Those still have to end in a sentence, not in
  /// a command that quietly starts a fresh conversation under an old session's
  /// name.
  ///
  /// Called with a null/empty [externalId] by the fresh-session command too,
  /// where the answer is always "nothing to refuse" — one decision, every
  /// surface, rather than three call sites deciding for themselves.
  void _refuseWhatCannotResume(String agentId, String? externalId) {
    final refusal = resumeRefusalFor(
      _ref.read(agentRegistryProvider),
      agentId,
      externalId,
    );
    if (refusal != null) throw StateError(refusal);
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
    _ref
        .read(sessionDaoProvider)
        .updateExternalSessionId(session.id, conversationId);
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
      // Which conversation this row is on: a placement, not a name.
      _publish(SessionChange.moved(session.id));
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
  ) async =>
      (await _detectedByKey({(agentId, externalId)}))[(agentId, externalId)];

  /// The store files behind `(agentId, conversationId)` pairs, in **one** walk
  /// of the CLI stores however many are asked for. Single and bulk deletes
  /// share it so neither can come to read a store differently from the other.
  Future<Map<(String, String), DetectedSession>> _detectedByKey(
    Set<(String, String)> wanted,
  ) async {
    final environments = _ref.read(executionEnvironmentDaoProvider).getAll();
    final stores = await _ref
        .read(cliStoreLocatorProvider)
        .locate(environments);
    final projects = await _ref.read(cliDetectionServiceProvider).detect(
      stores,
      {for (final environment in environments) environment.id: environment},
    );
    final found = <(String, String), DetectedSession>{};
    for (final project in projects) {
      for (final session in [
        ...project.sessions,
        ...project.subagentSessions,
      ]) {
        final key = (session.cli, session.sessionId);
        if (wanted.contains(key)) found[key] = session;
      }
    }
    return found;
  }

  DetectedSession _toDetected(ImportedSession session) => DetectedSession(
    cli: session.cli,
    sessionId: session.externalId,
    cwd: EnvironmentPath(environmentId: session.environmentId, path: ''),
    filePath: session.filePath,
    storeHome: session.storeHome,
    // Carried so a failure can be reported in the session's own name. Without
    // them `displayTitle` falls back to "(empty session)", which is what a
    // "could not be deleted" notification would otherwise have called it.
    title: session.title,
    preview: session.preview,
  );

  /// The coarse word, for the paths that genuinely move several things at
  /// once — a resume launches a process, writes a status and claims a pane.
  void _bump() => _ref.read(sessionsRevisionProvider.notifier).bump();

  void _publish(SessionChange change) =>
      _ref.read(sessionsRevisionProvider.notifier).changed(change);
}

final sessionActionsProvider = Provider<SessionActions>(
  (ref) => SessionActions(ref),
);
