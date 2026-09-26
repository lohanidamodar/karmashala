import 'where_you_are.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/util/frame_yield.dart';
import '../../agents/application/agent_providers.dart';
import '../../agents/application/directory_resume_providers.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart';
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';
import '../../git/application/changes_providers.dart';
import '../../repositories/application/repository_providers.dart';
import 'package:karmashala_git/repositories.dart';
import '../../sessions/application/session_actions.dart';
import '../../sessions/application/session_launcher.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_resume_providers.dart';
import '../../sessions/application/session_ui_providers.dart';
import '../../sessions/application/session_working_directory.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session/launch.dart';
import 'package:karmashala_session/resume.dart';
import '../../terminal/application/terminal_sessions_controller.dart';

/// What clicking a card or a `+` actually did.
enum ExplorerOutcome {
  /// The row is selected and nothing was started — the honest answer for a
  /// session there is no conversation to resume.
  selected,

  /// A pane of ours was already running it and has been brought back. Nothing
  /// was spawned.
  reattached,

  /// The agent was started on the existing conversation.
  resumed,

  /// A new session was started.
  started,

  /// Another process holds the conversation and this agent will not share.
  blocked,

  /// We could not do it, and [ExplorerResult.message] says why.
  failed,
}

/// The outcome of an Explorer action, plus whatever the user needs told.
class ExplorerResult {
  const ExplorerResult(this.outcome, {this.message});

  final ExplorerOutcome outcome;

  /// What to put in front of the user, or null when the change on screen is the
  /// whole answer. A reattach needs no sentence: the pane is simply back.
  final String? message;

  bool get isFailure =>
      outcome == ExplorerOutcome.failed || outcome == ExplorerOutcome.blocked;
}

/// One-click open and one-click start, for every row in the Explorer, so the
/// tree makes no launch decision in a `build()` and a card, a `+` and a menu
/// item cannot answer "is it already running?" three different ways.
class ExplorerActions {
  ExplorerActions(this._ref);

  final Ref _ref;

  /// Opens a native session: reattach if we still run it, else resume the
  /// conversation, else just select it. A session in a worktree resumes *in*
  /// that worktree — the repository root is a different branch.
  Future<ExplorerResult> openNative(String sessionId) async {
    final dao = _ref.read(sessionDaoProvider);
    final session = dao.getById(sessionId);
    if (session == null) {
      return const ExplorerResult(
        ExplorerOutcome.failed,
        message: 'This session no longer exists.',
      );
    }
    selectNative(session);

    final launcher = _ref.read(sessionLauncherProvider);
    // Its pane, or a pane attached to the host's session when none shows it.
    if (await launcher.show(sessionId)) {
      return const ExplorerResult(ExplorerOutcome.reattached);
    }

    // A previous resume of this conversation left a second row behind and its
    // pane may be the live one; revealing it beats a third process.
    final twin = _liveTwinOf(session);
    if (twin != null && await launcher.show(twin.id)) {
      return ExplorerResult(
        ExplorerOutcome.reattached,
        message: '"${twin.title}" is already running this conversation.',
      );
    }

    var externalId = session.externalSessionId;
    String? continueNotice;
    if (externalId == null || externalId.isEmpty) {
      // The CLI never told us its id, but an agent whose store records which
      // conversation each directory last used can still answer. Null means the
      // question does not apply to this agent.
      final plan = await _ref.read(directoryResumePlannerProvider)(session);
      final resolved = plan == null ? null : conversationIn(plan);
      if (plan is DirectoryResumeRefused) {
        // The row is still selected so its detail is on screen; what changes is
        // that the message now says *which* of several situations this is.
        return ExplorerResult(ExplorerOutcome.selected, message: plan.reason);
      }
      if (resolved == null) {
        // Nothing to resume: starting the agent here would be a *new*
        // conversation wearing this row's title. Said with a reason, because
        // silence is indistinguishable from a dead click.
        return const ExplorerResult(
          ExplorerOutcome.selected,
          message:
              'No resumable CLI session id was recorded for this one. For an '
              'older session, open its imported CLI history entry instead; new '
              'sessions capture their id automatically.',
        );
      }
      // Written before the launch: `SessionLauncher` reuses the row that holds
      // the conversation, so otherwise the click mints a second, phantom row.
      _ref
          .read(sessionDaoProvider)
          .updateExternalSessionId(sessionId, resolved);
      externalId = resolved;
      continueNotice = continueLatestNotice(
        _ref,
        session,
        resolved,
        sessionWorkingDirectoryOf(_ref, session)?.path ?? '',
      );
    }

    final installation = _ref
        .read(agentInstallationDaoProvider)
        .getById(session.agentInstallationId);
    final repository = _ref
        .read(repositoryDaoProvider)
        .getById(session.repositoryId);
    if (installation == null || repository == null) {
      return const ExplorerResult(
        ExplorerOutcome.failed,
        message:
            'The agent or repository for this session is no longer available.',
      );
    }

    final action = launcher.resumeActionForConversation(
      agentId: installation.agentId,
      sessionId: sessionId,
      externalSessionId: externalId,
      // The only certain knowledge we ever get about a process we do not own:
      // the agent's own refusal, read off the pane it died on.
      heldByAnotherProcess: _ref
          .read(sessionWhereaboutsProvider(sessionId))
          .knownHeldElsewhere,
    );
    switch (action) {
      case ResumeAction.blocked:
        return ExplorerResult(
          ExplorerOutcome.blocked,
          message: resumeBlockedMessage(
            launcher.agentDisplayName(installation.agentId),
          ),
        );
      case ResumeAction.reattach:
        // Unreachable in practice, and kept because the one thing this branch
        // must never do is fall through to a launch: that is a double writer.
        return const ExplorerResult(
          ExplorerOutcome.selected,
          message: 'That conversation is already running here.',
        );
      case ResumeAction.resume:
        break;
    }

    try {
      final launched = await launcher.launch(
        SessionLaunchRequest(
          repository: repository,
          installation: installation,
          title: session.title,
          purpose: SessionPurpose.existingSession,
          resumeExternalSessionId: externalId,
          existingWorktree: session.worktree,
        ),
      );
      _ref.read(selectedSessionIdProvider.notifier).select(launched.session.id);
      // A session whose recorded directory has gone resumes at the repository
      // root — a different conversation to an agent whose store is keyed by
      // directory, so it must not happen quietly. Both notices matter.
      final notices = [?continueNotice, ?launched.workingDirectoryNotice];
      return ExplorerResult(
        ExplorerOutcome.resumed,
        message: notices.isEmpty ? null : notices.join(' '),
      );
    } catch (error) {
      return ExplorerResult(ExplorerOutcome.failed, message: _say(error));
    }
  }

  /// Resumes the session whose **restored** pane is [paneId] — the terminal's
  /// way in, deliberately [openNative] and not a second implementation.
  /// Nothing is started here: the launch claims this very pane.
  Future<ExplorerResult> resumeRestoredPane(String paneId) async {
    final sessionId = _ref
        .read(terminalSessionsControllerProvider.notifier)
        .instanceFor(paneId)
        ?.agentLaunch
        ?.sessionId;
    if (sessionId == null) {
      return const ExplorerResult(
        ExplorerOutcome.failed,
        message:
            'This terminal is not one of our sessions, so there is no '
            'conversation to continue in it.',
      );
    }
    return openNative(sessionId);
  }

  /// Resumes every pane holding restored agent history, one pane per frame:
  /// back-to-back resumes freeze the window for the sum of them. One layout
  /// write for all of them, and refusals are counted rather than thrown.
  Future<({int resumed, int refused, String? message})>
  resumeAllRestoredPanes() async {
    final terminals = _ref.read(terminalSessionsControllerProvider.notifier);
    final panes = terminals.restoredAgentPanes();
    if (panes.isEmpty) return (resumed: 0, refused: 0, message: null);
    final yieldFrame = _ref.read(frameYieldProvider);
    return terminals.withOneLayoutSave(() async {
      var resumed = 0;
      final refusals = <String>[];
      for (var i = 0; i < panes.length; i++) {
        if (i > 0) await yieldFrame();
        final result = await resumeRestoredPane(panes[i]);
        if (result.outcome == ExplorerOutcome.resumed ||
            result.outcome == ExplorerOutcome.reattached) {
          resumed++;
        } else {
          refusals.add(result.message ?? 'One session could not be resumed.');
        }
      }
      return (
        resumed: resumed,
        refused: refusals.length,
        message: switch (refusals.length) {
          0 => null,
          // One refusal gets its own words; several would be a wall of them, so
          // the count leads and the first stands as the example.
          1 => refusals.single,
          _ =>
            '${refusals.length} sessions could not be resumed. '
                '${refusals.first}',
        },
      );
    });
  }

  /// Opens an imported CLI session: reattach when we already run that
  /// conversation, else resume in place ([SessionActions.resumeImported]).
  Future<ExplorerResult> openImported(ImportedSession session) async {
    selectImported(session);
    final launcher = _ref.read(sessionLauncherProvider);
    final action = launcher.resumeActionForConversation(
      agentId: session.cli,
      externalSessionId: session.externalId,
    );
    if (action == ResumeAction.blocked) {
      return ExplorerResult(
        ExplorerOutcome.blocked,
        message: resumeBlockedMessage(launcher.agentDisplayName(session.cli)),
      );
    }
    final reattaching = action == ResumeAction.reattach;
    try {
      await _ref.read(sessionActionsProvider).resumeImported(session);
      return ExplorerResult(
        reattaching ? ExplorerOutcome.reattached : ExplorerOutcome.resumed,
        message: reattaching ? null : 'Resuming session…',
      );
    } catch (error) {
      return ExplorerResult(ExplorerOutcome.failed, message: _say(error));
    }
  }

  /// Starts a session in [repository], or in [existingWorktree]; [installation]
  /// omitted means the environment's default agent. A worktree needs no
  /// `repositories` row: the owning repository supplies the id.
  Future<ExplorerResult> startSession({
    required Repository repository,
    EnvironmentPath? existingWorktree,
    AgentInstallation? installation,
    String? title,
  }) async {
    final launcher = _ref.read(sessionLauncherProvider);
    final environmentId = repository.path.environmentId;
    final agent =
        installation ??
        launcher.defaultInstallationIn(environmentId) ??
        _ref
            .read(agentInstallationDaoProvider)
            .getByEnvironment(environmentId)
            .firstOrNull;
    if (agent == null) {
      return ExplorerResult(
        ExplorerOutcome.failed,
        message:
            'No agent is installed in $environmentId. '
            'Run "Discover agents" in Settings first.',
      );
    }
    try {
      final launched = await launcher.launch(
        SessionLaunchRequest(
          repository: repository,
          installation: agent,
          title: title ?? 'New session',
          purpose: SessionPurpose.newSession,
          existingWorktree: existingWorktree,
        ),
      );
      selectNative(launched.session);
      return const ExplorerResult(ExplorerOutcome.started);
    } catch (error) {
      return ExplorerResult(ExplorerOutcome.failed, message: _say(error));
    }
  }

  /// Every agent installed where [repository] lives, for the "…with" menu.
  List<AgentInstallation> installationsFor(Repository repository) => _ref
      .read(agentInstallationDaoProvider)
      .getByEnvironment(repository.path.environmentId);

  /// Selects a native session, and the repository above it, so the detail pane
  /// and the workbench follow the tree.
  void selectNative(Session session) {
    _ref.read(explorerFollowHoldProvider.notifier).hold();
    _ref
        .read(selectedRepositoryIdProvider.notifier)
        .select(session.repositoryId);
    _ref.read(selectedImportedSessionIdProvider.notifier).select(null);
    _ref.read(selectedSessionIdProvider.notifier).select(session.id);
  }

  void selectImported(ImportedSession session) {
    _ref.read(explorerFollowHoldProvider.notifier).hold();
    _ref
        .read(selectedRepositoryIdProvider.notifier)
        .select(session.repositoryId);
    _ref.read(selectedSessionIdProvider.notifier).select(null);
    _ref.read(selectedImportedSessionIdProvider.notifier).select(session.id);
  }

  /// Another of our rows for the same CLI conversation whose pane is live.
  /// `runningSessionWithExternalId` takes the *first* row with that id, which
  /// after a resume is the dead one; scanning every row cannot be fooled.
  Session? _liveTwinOf(Session session) {
    final externalId = session.externalSessionId;
    if (externalId == null || externalId.isEmpty) return null;
    final launcher = _ref.read(sessionLauncherProvider);
    for (final candidate in _ref.read(sessionDaoProvider).getAll()) {
      if (candidate.id == session.id) continue;
      if (candidate.externalSessionId != externalId) continue;
      if (launcher.livePaneFor(candidate.id) != null) return candidate;
    }
    return null;
  }

  /// The user-facing half of an error: a [StateError]'s message is already
  /// written for a human, anything else is shown as it stands.
  String _say(Object error) => switch (error) {
    StateError() => error.message,
    SessionAlreadyRunning() => error.toString(),
    _ => '$error',
  };
}

final explorerActionsProvider = Provider<ExplorerActions>(
  (ref) => ExplorerActions(ref),
);
