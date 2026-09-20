import 'dart:convert';

import 'package:riverpod/riverpod.dart';

import 'package:karmashala_core/logging.dart';
import '../../../core/util/clock_provider.dart';
import '../../agents/application/agent_providers.dart';
import '../../agents/application/antigravity_resume_providers.dart';
import 'package:agent_cli/read.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import '../../cli_detection/application/cli_detection_providers.dart';
import '../../cli_detection/application/codex_app_server_providers.dart';
import '../../cli_detection/application/detected_project_merger.dart';
import '../../cli_detection/data/cli_session_mutator.dart';
import '../../environments/application/environment_providers.dart';
import '../../environments/application/environment_resolver.dart';
import 'package:agent_cli/process.dart';
import '../../repositories/application/repository_providers.dart';
import 'package:karmashala_git/repositories.dart';
import '../../terminal/application/system_terminal_providers.dart';
import '../../terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_runtime/system_terminals.dart';
import 'package:karmashala_session/events.dart';
import 'package:agent_cli/stream.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session/launch.dart';
import 'package:karmashala_session/resume.dart';
import 'session_engine_provider.dart';
import 'session_launcher.dart';
import 'session_message_typist.dart';
import 'session_notice.dart';
import 'session_providers.dart';
import 'session_ui_providers.dart';
import 'session_working_directory.dart';

/// Rename/delete for every session in the app, native or imported; both
/// propagate to the originating CLI store, best-effort.
class SessionActions {
  SessionActions(this._ref);
  final Ref _ref;

  static final _log = AppLogger.named('sessions.actions');

  /// Renames a native row, then tells the CLI store behind it — best-effort, so
  /// an uninstalled CLI cannot undo a rename already on screen.
  Future<void> renameNative(String id, String title) async {
    // `byUser` is what stops the CLI rename sync taking the title back, for the
    // life of the row.
    _ref.read(sessionDaoProvider).updateTitle(id, title, byUser: true);
    // The narrowest signal on purpose: the coarse word cost 108 session reads
    // at a hundred sessions.
    _publish(SessionChange.renamed(id));
    _ref.read(terminalSessionsControllerProvider.notifier).notifyTitleChanged();
    final store = await _propagateNativeRename(id, title);
    _log.info('Renamed $id: byUser=true store=$store');
  }

  /// Carries a native row's new title out to the CLI store. Codex needs only
  /// the thread id; every other costs one pass over the stores. Never throws.
  Future<String> _propagateNativeRename(String id, String title) async {
    final session = _ref.read(sessionDaoProvider).getById(id);
    final externalId = session?.externalSessionId;
    if (session == null || externalId == null) return 'no-conversation';
    final installation = _ref
        .read(agentInstallationDaoProvider)
        .getById(session.agentInstallationId);
    if (installation == null) return 'no-installation';
    final mutator = _ref.read(cliSessionMutatorProvider);
    try {
      if (installation.agentId == AgentIds.codex) {
        await mutator.rename(
          DetectedSession(
            cli: AgentIds.codex,
            sessionId: externalId,
            cwd: EnvironmentPath(
              environmentId: installation.environmentId,
              path: '',
            ),
            // No store file is read or written on this path; the app-server is.
            filePath: '',
            storeHome: '',
          ),
          title,
          codex: _ref.read(codexAppServersProvider),
        );
        return 'app-server';
      }
      final detected = await _detectedSessionById(
        installation.agentId,
        externalId,
      );
      if (detected == null) return 'not-in-store';
      await mutator.rename(detected, title);
      return 'transcript';
    } catch (error) {
      _log.warning(
        'Could not rename $id in the ${installation.agentId} store',
        error,
      );
      return 'failed';
    }
  }

  /// Removes the app's record of [id], and the CLI transcript behind it when
  /// asked. Returns what the user should be told beyond "it is gone", or null.
  /// Throws when nothing was deleted at all.
  Future<String?> deleteNative(String id, {bool deleteFromCli = true}) async {
    final session = _ref.read(sessionDaoProvider).getById(id);
    if (session == null) return null;
    var fromCliStore = deleteFromCli;
    String? notice;
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
      final environment = _environmentOf(session, repo);
      // A store on another machine is not ours to delete from. Refusing the
      // whole delete over it left the row on screen with no way to remove it.
      if (environment != null && !cliStoreIsReachable(environment.kind)) {
        fromCliStore = false;
        notice =
            'Removed from Karmashala. The transcript on ${environment.name} '
            'was left: a CLI store on another machine cannot be deleted from '
            'here.';
      } else {
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
    }
    _removeNativeRow(session, fromCliStore: fromCliStore);
    _publish(SessionChange.removed(id));
    return notice;
  }

  /// Where this session's CLI store would live: the directory it runs in, or
  /// failing that its repository's.
  ExecutionEnvironment? _environmentOf(Session session, Repository repo) => _ref
      .read(executionEnvironmentDaoProvider)
      .getById(
        session.workingDirectory?.environmentId ?? repo.path.environmentId,
      );

  /// Takes one native row out of the workspace and nothing else. Publishes
  /// nothing — the caller does, so a batch can publish once.
  void _removeNativeRow(Session session, {required bool fromCliStore}) {
    _ref.read(sessionDaoProvider).delete(session.id);
    if (_ref.read(selectedSessionIdProvider) == session.id) {
      _ref.read(selectedSessionIdProvider.notifier).select(null);
    }
    // After the fact, so the line means the delete happened: every throw in
    // [deleteNative] abandons it with the CLI store untouched.
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

  /// Removes a whole selection from the workspace as **one act**, publishing
  /// once: three bare listeners do real work per bump. The CLI store is left.
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
    // Coarse on purpose: this named several rows, so no single one. Not
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
          .rename(
            _toDetected(session),
            title,
            codex: _ref.read(codexAppServersProvider),
          );
    } catch (_) {
      // CLI store unavailable — the workspace title is still updated.
    }
    _publish(SessionChange.renamed(session.id));
  }

  /// Removes [sessions] from their agents' own stores as one batch. Never
  /// throws — what could not be removed comes back in the report.
  Future<CliDeleteReport> purgeFromCliStore(List<ImportedSession> sessions) =>
      purgeSessionsFromCliStore(imported: sessions);

  /// The same batch for a selection of both kinds: native rows are looked up in
  /// one pass. One we cannot identify comes back as a failure, honestly.
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

  /// Resumes an imported CLI session in place as a live native session and
  /// returns its id; reattaches instead when that conversation is already live.
  Future<String> resumeImported(ImportedSession session) async {
    final launcher = _ref.read(sessionLauncherProvider);
    final action = launcher.resumeActionForConversation(
      agentId: session.cli,
      externalSessionId: session.externalId,
    );
    final running = launcher.runningSessionWithExternalId(session.externalId);
    if (action == ResumeAction.reattach && running != null) {
      launcher.reveal(running.id);
      // The imported row was only ever a second record of a session we own.
      _dropImported(session);
      _log.info(
        'Resumed imported ${session.id} (${session.cli}): '
        'reattached to ${running.id} conversation=${session.externalId}',
      );
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
    // Through the one launcher, so the resume gets the *existing-session*
    // permission mode rather than a new session's.
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
    _log.info(
      'Resumed imported ${session.id} (${session.cli}) as ${started.id}: '
      'agent=${installs.first.id} conversation=${session.externalId} '
      'environment=${session.environmentId}',
    );
    await _seedHistory(started.id, session);
    _dropImported(session);
    _ref.read(selectedSessionIdProvider.notifier).select(started.id);
    return started.id;
  }

  /// Drops the imported record and deselects it, leaving the CLI store file
  /// alone. Shared by both resume outcomes so they cannot tidy up differently.
  void _dropImported(ImportedSession session) {
    _ref.read(importedSessionDaoProvider).delete(session.id);
    if (_ref.read(selectedImportedSessionIdProvider) == session.id) {
      _ref.read(selectedImportedSessionIdProvider.notifier).select(null);
    }
    _publish(SessionChange.removed(session.id));
  }

  /// Resumes [session] and sends [text] through [continueSession], not the
  /// engine, so it lands in the PTY the resume produced — the one write path.
  Future<void> resumeAndSend(ImportedSession session, String text) async {
    final id = await resumeImported(session);
    await continueSession(id, text);
  }

  /// Sends [text] to a native session, relaunching its agent first if the
  /// session has ended. Throws if the repository or agent is gone.
  Future<void> continueSession(String sessionId, String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;

    // A PTY-hosted session is typed into, not messaged: chat and terminal are
    // two views of one session, so there is one write path into the agent. The
    // typist reads the Return back off the screen — a composer that folded it
    // into a newline is pressed again rather than left holding the message.
    if (await _ref
        .read(sessionMessageTypistProvider)
        .send(sessionId, trimmed)) {
      _log.info('Continued $sessionId: typed into its pane');
      return;
    }

    final engine = _ref.read(sessionEngineProvider);

    var resumed = false;
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
            // The session's own mode, not the global default as it now stands.
            sessionMode: session.permissionMode,
          );
      await engine.resume(
        session: session,
        // The CLIs key their conversation stores by directory, so the repo root
        // is a fallback rather than an answer.
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
      resumed = true;
    }

    _log.info('Continued $sessionId through the engine: resumed=$resumed');
    await engine.sendMessage(sessionId, trimmed);
  }

  /// Copies the imported session's prior transcript into the resumed session's
  /// event log, so a resume continues rather than starts blank. Best-effort.
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
    // Through the one launcher, so an external terminal records a session row
    // too; [terminal] is honoured, but the launcher owns the default.
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
          ),
          externalTerminal: terminal,
        );
    return launched.session;
  }

  /// A shell command (cd + resume, with permission flags) for [session], to
  /// copy to the clipboard. Throws if the repository is gone.
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

  /// The shell family a copied command must be spelled for: the one belonging
  /// to the directory it `cd`s into, never the host's.
  EnvironmentKind _shellKindOf(String environmentId) =>
      // `runnable: false`: nothing is launched here, only spelled out to copy.
      _ref
          .read(environmentResolverProvider)
          .resolve(environmentId, runnable: false)
          .require
          .kind;

  /// A shell command (cd + resume, with permission flags) for native
  /// [sessionId].
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
            // The session's own mode, not the global default as it now stands.
            sessionMode: session.permissionMode,
          ),
      // No existence check: a command copied for later should name the
      // conversation's directory even if it is not mounted right now.
      cwd: workingDirectory.path,
      // The *working directory's* environment, not the installation's: the
      // shell that has to understand this line is the one that shell opens in.
      environment: _shellKindOf(workingDirectory.environmentId),
      registry: _ref.read(agentRegistryProvider),
    );
  }

  /// A shell command (cd + fresh session, with permission flags) for
  /// [projectId]'s first repository with the default agent.
  String newSessionShellCommand(String projectId) {
    final repos = _ref.read(repositoryDaoProvider).getByProject(projectId);
    if (repos.isEmpty) {
      throw StateError(kNowhereToRunIn);
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
    // Always "nothing to refuse" here: this command names no conversation.
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

  /// Opens [session] in an external [terminal], starting in its repository, and
  /// refuses when we run that conversation and the agent will not share it.
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
        .read(environmentResolverProvider)
        .resolveFor(repo.path)
        .require;
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
    // For WSL the cwd is handled inside the wrapped `wsl --cd`; only host
    // shells take a start directory.
    final cwd = env.wslDistribution == null ? repo.path.path : null;
    await _ref
        .read(systemTerminalServiceProvider)
        .launch(terminal, command: command, workingDirectory: cwd);
  }

  /// Opens native [sessionId] in an external [terminal]. Refuses a live pane
  /// whose agent forbids a second process, as [openInSystemTerminal] does.
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
          // An installation we can no longer resolve has no capability, which
          // is `false` — the safe answer.
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
        .read(environmentResolverProvider)
        .resolveFor(repo.path)
        .require;
    final recorded = sessionWorkingDirectoryOf(_ref, session);
    final directory = directoryOrFallback(
      _ref,
      directory: recorded,
      fallback: repo.path,
    ).directory;
    // After the id is resolved: the two recovery paths above can supply one the
    // row did not carry, and it is that id the command has to continue.
    _refuseWhatCannotResume(installation.agentId, externalId);
    // A notice, not a throw: this surface is where the substitution happens,
    // and the terminal opens either way.
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
            // The session's own mode, not the global default as it now stands.
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

  /// Refuses to claim to continue [externalId] for an agent the registry calls
  /// hopeless — [AgentResumeStyle.unsupported], or one it never heard of.
  void _refuseWhatCannotResume(String agentId, String? externalId) {
    final refusal = resumeRefusalFor(
      _ref.read(agentRegistryProvider),
      agentId,
      externalId,
    );
    if (refusal != null) throw StateError(refusal);
  }

  /// The conversation the agent's own store says this directory last used —
  /// the last resort for `agy`, which mints an id and never tells us.
  Future<String?> _continuableConversationFor(Session session) async {
    final plan = await _ref.read(antigravityResumePlannerProvider)(session);
    if (plan == null) return null;
    if (plan is AntigravityResumeRefused) throw StateError(plan.reason);
    final conversationId = conversationIn(plan);
    if (conversationId == null) return null;
    // Recorded now, so the row names the conversation before anything else
    // asks.
    _ref
        .read(sessionDaoProvider)
        .updateExternalSessionId(session.id, conversationId);
    return conversationId;
  }

  /// Recovers the CLI id for sessions created before schema v5, conservatively:
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

  /// The store files behind `(agentId, conversationId)` pairs in **one** walk,
  /// however many are asked for; single and bulk deletes share it.
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
    // Carried so a failure is reported under the session's own name; without
    // them `displayTitle` says "(empty session)".
    title: session.title,
    preview: session.preview,
  );

  /// The coarse word, for paths that genuinely move several things at once.
  void _bump() => _ref.read(sessionsRevisionProvider.notifier).bump();

  void _publish(SessionChange change) =>
      _ref.read(sessionsRevisionProvider.notifier).changed(change);
}

final sessionActionsProvider = Provider<SessionActions>(
  (ref) => SessionActions(ref),
);
