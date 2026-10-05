import '../../workspaces/data/workspace_data.dart';
import 'dart:async';
import 'dart:convert';

import 'package:riverpod/riverpod.dart';

import 'package:karmashala_core/logging.dart';
import '../../../core/capabilities/capabilities.dart';
import '../../../core/util/clock_provider.dart';
import '../../agents/application/agent_providers.dart';
import '../../agents/application/directory_resume_providers.dart';
import 'package:agent_cli/read.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import '../../cli_detection/application/cli_detection_providers.dart';
import '../../cli_detection/application/agent_store_server_providers.dart';
import '../../cli_detection/data/cli_session_mutator.dart';
import '../../environments/application/environment_providers.dart';
import '../../environments/application/environment_resolver.dart';
import 'package:agent_cli/process.dart';
import '../../projects/application/projects_controller.dart';
import 'package:karmashala_git/repositories.dart';
import '../../terminal/application/system_terminal_providers.dart';
import '../../terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_runtime/system_terminals.dart';
import 'package:karmashala_session/events.dart';
import 'package:agent_cli/stream.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session/launch.dart';
import 'package:karmashala_session/resume.dart';
import 'acp_session_providers.dart';
import 'host_lifecycle/host_agent_statuses.dart';
import 'host_lifecycle/host_lifecycle_providers.dart';
import 'session_chat_source.dart';
import 'session_engine_provider.dart';
import 'session_launcher.dart';
import 'session_input.dart';
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
    _ref.read(sessionsDataProvider).updateTitle(id, title, byUser: true);
    // The narrowest signal on purpose: the coarse word cost 108 session reads
    // at a hundred sessions.
    _publish(SessionChange.renamed(id));
    _ref.read(terminalSessionsControllerProvider.notifier).notifyTitleChanged();
    final store = await _propagateNativeRename(id, title);
    _log.info('Renamed $id: byUser=true store=$store');
  }

  /// Carries a native row's new title out to the CLI store. An agent with a
  /// store server needs only the conversation id; every other costs one pass
  /// over the stores. Never throws.
  Future<String> _propagateNativeRename(String id, String title) async {
    final session = _ref.read(sessionsDataProvider).getById(id);
    final externalId = session?.externalSessionId;
    if (session == null || externalId == null) return 'no-conversation';
    final installation = _ref
        .read(agentInstallationsDataProvider)
        .getById(session.agentInstallationId);
    if (installation == null) return 'no-installation';
    final mutator = _ref.read(cliSessionMutatorProvider);
    try {
      final adapter = _ref
          .read(agentRegistryProvider)
          .adapterFor(installation.agentId);
      if (adapter?.storeServer != null) {
        await mutator.rename(
          DetectedSession(
            cli: installation.agentId,
            sessionId: externalId,
            cwd: EnvironmentPath(
              environmentId: installation.environmentId,
              path: '',
            ),
            // No store file is read or written on this path; the server is.
            filePath: '',
            storeHome: '',
          ),
          title,
          servers: _ref.read(agentStoreServersProvider),
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
    final session = _ref.read(sessionsDataProvider).getById(id);
    if (session == null) return null;
    // An ACP session's conversation is the server's own rows: no CLI store
    // holds it, so there is nothing there to look for or delete.
    final hasCliStore = !installationSpeaksAcp(
      _ref,
      session.agentInstallationId,
    );
    var fromCliStore = deleteFromCli && hasCliStore;
    String? notice;
    if (fromCliStore) {
      final repo = _ref
          .read(workspaceDataProvider)
          .repository(session.repositoryId);
      final installation = _ref
          .read(agentInstallationsDataProvider)
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
      .read(environmentsDataProvider)
      .getById(
        session.workingDirectory?.environmentId ?? repo.path.environmentId,
      );

  /// Takes one native row out of the workspace and nothing else. Publishes
  /// nothing — the caller does, so a batch can publish once.
  void _removeNativeRow(Session session, {required bool fromCliStore}) {
    _ref.read(sessionsDataProvider).delete(session.id);
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
    _ref.read(importedSessionsProvider).delete(session.id);
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
    _ref.read(importedSessionsProvider).updateTitle(session.id, title);
    try {
      await _ref
          .read(cliSessionMutatorProvider)
          .rename(
            _toDetected(session),
            title,
            servers: _ref.read(agentStoreServersProvider),
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
    final installations = _ref.read(agentInstallationsDataProvider);

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
      await launcher.show(running.id);
      // The imported row was only ever a second record of a session we own.
      _dropImported(session);
      _log.info(
        'Resumed imported ${session.id} (${session.cli}): '
        'reattached to ${running.id} conversation=${session.externalId}',
      );
      return running.id;
    }

    final repo = _ref
        .read(workspaceDataProvider)
        .repository(session.repositoryId);
    if (repo == null) {
      throw StateError(
        'Repository for this session is no longer in the workspace.',
      );
    }
    final installs = _ref
        .read(agentInstallationsDataProvider)
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
    _ref.read(importedSessionsProvider).delete(session.id);
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
  /// [requestId] keys a send the server types, kept by a caller that retries.
  Future<void> continueSession(
    String sessionId,
    String text, {
    String? requestId,
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;

    final row = _ref.read(sessionsDataProvider).getById(sessionId);
    if (row != null && installationSpeaksAcp(_ref, row.agentInstallationId)) {
      return _continueOverProtocol(row, trimmed, requestId: requestId);
    }

    // A PTY-hosted session is typed into, not messaged: chat and terminal are
    // two views of one session, so there is one write path into the agent. The
    // typist reads the Return back off the screen — a composer that folded it
    // into a newline is pressed again rather than left holding the message.
    if (await _ref
        .read(sessionInputProvider)
        .send(sessionId, trimmed, requestId: requestId)) {
      _log.info('Continued $sessionId: typed into it');
      return;
    }

    final engine = _ref.read(sessionEngineProvider);

    var resumed = false;
    if (!engine.isActive(sessionId)) {
      // Resuming an agent still live elsewhere would start a second one on
      // the same conversation.
      if (_liveOutsideEngine(sessionId)) {
        throw StateError(
          'This session is still running, but its terminal could not be '
          'typed into from here, so nothing was sent. It was not started a '
          'second time. Try again, or send from its terminal.',
        );
      }
      final session = _ref.read(sessionsDataProvider).getById(sessionId);
      if (session == null) {
        throw StateError('This session no longer exists.');
      }
      final repo = _ref
          .read(workspaceDataProvider)
          .repository(session.repositoryId);
      if (repo == null) {
        throw StateError('The session\'s repository is no longer available.');
      }
      final installation = _ref
          .read(agentInstallationsDataProvider)
          .getById(session.agentInstallationId);
      if (installation == null) {
        throw StateError(
          'The agent for this session is not installed. '
          'Run "Discover agents" in Settings.',
        );
      }
      // A headless turn has nobody to ask its questions and approvals, so a
      // session that ran in a pane comes back in one, as Resume brings it.
      if (session.surface != SessionSurface.external) {
        await _resumeInPane(session, repo, installation, message: trimmed);
        return;
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
      _offerResumeHere(sessionId);
    }

    _log.info('Continued $sessionId through the engine: resumed=$resumed');
    await engine.sendMessage(sessionId, trimmed);
  }

  /// Relaunches [session]'s terminal at the server, claiming its restored
  /// pane, with [message] as its first prompt: the server delivers it the way
  /// the agent's descriptor declares. Shown as starting until it is up.
  Future<void> _resumeInPane(
    Session session,
    Repository repo,
    AgentInstallation installation, {
    String? message,
  }) async {
    final launcher = _ref.read(sessionLauncherProvider);
    final conversation = session.externalSessionId;
    final hasConversation = conversation != null && conversation.isNotEmpty;
    // A launch of a conversation another row runs only reveals that row, so
    // the message goes to it rather than being dropped.
    final twin = launcher.runningSessionWithExternalId(conversation);
    if (twin != null && message != null) {
      await launcher.show(twin.id);
      if (!await _ref.read(sessionInputProvider).send(twin.id, message)) {
        throw StateError(
          '"${twin.title}" is already running this conversation, but it could '
          'not be typed into, so nothing was sent.',
        );
      }
      _log.info('Continued ${session.id}: typed into its twin ${twin.id}');
      return;
    }
    final starting = _ref.read(sessionsStartingProvider.notifier)
      ..add(session.id);
    try {
      final launched = await launcher.launch(
        SessionLaunchRequest(
          repository: repo,
          installation: installation,
          title: session.title,
          purpose: SessionPurpose.existingSession,
          resumeExternalSessionId: hasConversation ? conversation : null,
          // No conversation to resume: a fresh one, in this row.
          restartSessionId: hasConversation ? null : session.id,
          existingWorktree: session.worktree,
          workingDirectory: session.workingDirectory,
          firstMessage: message,
        ),
      );
      _ref.read(selectedSessionIdProvider.notifier).select(launched.session.id);
      final notice = launched.workingDirectoryNotice;
      if (notice != null) {
        _ref
            .read(sessionNoticesProvider.notifier)
            .post(
              session.id,
              SessionNotice(message: notice, tone: SessionNoticeTone.warning),
            );
      }
      _log.info(
        'Continued ${session.id}: resumed in pane ${launched.paneId} '
        'to take the message=${message != null}',
      );
    } finally {
      starting.remove(session.id);
    }
  }

  /// Says, on a session in an external terminal, that the turn just run here
  /// cannot ask anything, and offers to bring it back in a pane instead.
  void _offerResumeHere(String sessionId) {
    final notices = _ref.read(sessionNoticesProvider.notifier);
    notices.post(
      sessionId,
      SessionNotice(
        message:
            'This session runs in an external terminal, so your message ran '
            "here as a one-off turn: questions and approvals can't be asked "
            'in it. Resume the session here to answer them.',
        tone: SessionNoticeTone.warning,
        sticky: true,
        action: SessionNoticeAction(
          label: 'Resume here',
          onPressed: () {
            notices.dismiss(sessionId);
            unawaited(_resumeHere(sessionId));
          },
        ),
      ),
    );
  }

  Future<void> _resumeHere(String sessionId) async {
    try {
      final session = _ref.read(sessionsDataProvider).getById(sessionId);
      if (session == null) throw StateError('This session no longer exists.');
      final repo = _ref
          .read(workspaceDataProvider)
          .repository(session.repositoryId);
      final installation = _ref
          .read(agentInstallationsDataProvider)
          .getById(session.agentInstallationId);
      if (repo == null || installation == null) {
        throw StateError(
          'The agent or repository for this session is no longer available.',
        );
      }
      // The one-off turn ends first: two processes on one conversation.
      await _ref.read(sessionEngineProvider).stop(sessionId);
      await _resumeInPane(session, repo, installation);
    } on Object catch (error) {
      _ref
          .read(sessionNoticesProvider.notifier)
          .post(
            sessionId,
            SessionNotice(
              message: error is StateError ? error.message : '$error',
              tone: SessionNoticeTone.warning,
            ),
          );
    }
  }

  /// Sends [text] to [row]'s agent over its protocol, at the server: a
  /// session the server no longer runs is resumed there first —
  /// `session/load` where the agent can, a fresh conversation in the same
  /// row otherwise — and the message is its next turn. Never typed into a
  /// pane, never started by this app's own engine: the server owns the
  /// process.
  Future<void> _continueOverProtocol(
    Session row,
    String text, {
    String? requestId,
  }) async {
    // A server that resumes on send does it in the same request, for every
    // client alike; only an older one is asked to resume first.
    final running =
        _ref.read(capabilitiesProvider).sendResumesAtServer ||
        (row.status.claimsLive &&
            _ref.read(sessionRunningOnHostProvider)(row.id));
    if (!running) {
      final launched = await _ref
          .read(sessionLauncherProvider)
          .resumeAtServer(row.id);
      final notice = launched.workingDirectoryNotice;
      _log.info(
        'Resumed ${row.id} at the server before sending'
        '${notice == null ? '' : ': $notice'}',
      );
    }
    final sent = await _ref
        .read(sessionInputProvider)
        .send(row.id, text, requestId: requestId);
    if (!sent) {
      throw StateError(
        'The server does not run this session, so nothing was sent. Resume '
        'it and try again.',
      );
    }
    _log.info('Continued ${row.id} over its protocol');
  }

  /// Whether [sessionId]'s agent runs outside this app's engine: the server
  /// runs it or keeps its status (a box session), or a pane here shows it.
  bool _liveOutsideEngine(String sessionId) =>
      _ref.read(sessionRunningOnHostProvider)(sessionId) ||
      _ref.read(hostAgentStatusesProvider).of(sessionId) != null ||
      _ref.read(sessionLauncherProvider).livePaneFor(sessionId) != null;

  /// Copies the imported session's prior transcript into the resumed session's
  /// event log, so a resume continues rather than starts blank. Best-effort.
  Future<void> _seedHistory(String sessionId, ImportedSession session) async {
    try {
      const cap = 500;
      // Read where it was recorded, the tail only, when the server offers it.
      final served = await serverSessionTurns(
        _ref,
        session.id,
        enough: (held) => held.length >= cap,
      );
      final messages =
          served?.turns ??
          await readCliTranscript(session.filePath, session.cli);
      if (messages.isEmpty) return;
      final recent = messages.length > cap
          ? messages.sublist(messages.length - cap)
          : messages;
      final now = _ref.read(clockProvider).nowUtc();
      final events = <SessionEvent>[];
      for (final m in recent) {
        final type = switch (m.role) {
          'user' => SessionEventTypes.userMessage,
          'agent' => SessionEventTypes.agentMessage,
          _ => null,
        };
        if (type == null) continue;
        events.add(
          SessionEvent(
            sessionId: sessionId,
            seq: 0,
            type: type,
            payload: jsonEncode({'text': m.text, 'history': true}),
            createdAt: now,
          ),
        );
      }
      // One request for the lot, numbered in this order.
      if (events.isNotEmpty) {
        await _ref.read(sessionRecordsProvider).appendAll(events);
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
    final repo = _ref
        .read(workspaceDataProvider)
        .repository(session.repositoryId);
    if (repo == null) {
      throw StateError('This session\'s repository is no longer available.');
    }
    final installs = _ref
        .read(agentInstallationsDataProvider)
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
    final session = _ref.read(sessionsDataProvider).getById(sessionId);
    if (session == null) throw StateError('This session no longer exists.');
    final repo = _ref
        .read(workspaceDataProvider)
        .repository(session.repositoryId);
    if (repo == null) {
      throw StateError('This session\'s repository is no longer available.');
    }
    final installation = _ref
        .read(agentInstallationsDataProvider)
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
  Future<String> newSessionShellCommand(String projectId) async {
    final repos = _ref.read(workspaceDataProvider).repositoriesOf(projectId);
    // Nothing recorded is not nowhere to run: the project's own folder is, and
    // recording it here is what the Explorer's own start does.
    final repo =
        repos.firstOrNull ??
        await _ref
            .read(projectsControllerProvider.notifier)
            .ensureRunLocation(projectId);
    final installs = _ref
        .read(agentInstallationsDataProvider)
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
    final repo = _ref
        .read(workspaceDataProvider)
        .repository(session.repositoryId);
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
        .read(agentInstallationsDataProvider)
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
    final session = _ref.read(sessionsDataProvider).getById(sessionId);
    if (session == null) {
      throw StateError('This session no longer exists.');
    }
    final installationForGuard = _ref
        .read(agentInstallationsDataProvider)
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
    final repo = _ref
        .read(workspaceDataProvider)
        .repository(session.repositoryId);
    if (repo == null) {
      throw StateError('The session\'s repository is no longer available.');
    }
    final installation = _ref
        .read(agentInstallationsDataProvider)
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
    final plan = await _ref.read(directoryResumePlannerProvider)(session);
    if (plan == null) return null;
    if (plan is DirectoryResumeRefused) throw StateError(plan.reason);
    final conversationId = conversationIn(plan);
    if (conversationId == null) return null;
    // Recorded now, so the row names the conversation before anything else
    // asks.
    _ref
        .read(sessionsDataProvider)
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
      final events = await _ref
          .read(sessionRecordsProvider)
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
      final environmentDao = _ref.read(environmentsDataProvider);
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
                    .read(sessionsDataProvider)
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
          .read(sessionsDataProvider)
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
    final environments = _ref.read(environmentsDataProvider).getAll();
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
