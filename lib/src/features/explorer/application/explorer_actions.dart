import 'package:riverpod/riverpod.dart';

import '../../../core/util/frame_yield.dart';
import '../../agents/application/agent_providers.dart';
import '../../agents/application/antigravity_resume_providers.dart';
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
import '../../sessions/domain/session.dart';
import '../../sessions/domain/session_launch.dart';
import '../../sessions/domain/session_resume.dart';
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

/// One-click open and one-click start, for every row in the Explorer.
///
/// This exists so the tree does not make launch decisions in a `build()`, and so
/// a card, a `+` button and a context-menu item cannot answer "is it already
/// running?" three different ways. Every decision below is delegated:
/// [SessionLauncher.reveal] owns reattaching, [resumeActionFor] owns the choice
/// between reattach / resume / blocked, and [SessionLauncher.launch] owns
/// creating anything.
class ExplorerActions {
  ExplorerActions(this._ref);

  final Ref _ref;

  /// Opens a native session: reattach if we are still running it, otherwise
  /// resume the conversation, otherwise just select it.
  ///
  /// **A session in a worktree resumes in that worktree.** Until Loop 54 added
  /// [SessionLaunchRequest.existingWorktree] there was no way to say so, and
  /// every resume path — this one, and the MCP `open_session` tool — put the
  /// agent back in the repository root: a different directory, on a different
  /// branch, from the work being resumed.
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
    if (launcher.reveal(sessionId)) {
      return const ExplorerResult(ExplorerOutcome.reattached);
    }

    // A previous resume of this same conversation left a second row behind (a
    // resume mints one — see the loop report), and that row's pane may well be
    // the live one. Reveal it rather than stacking a third process on the
    // conversation, which is what clicking the older card would otherwise do.
    final twin = _liveTwinOf(session);
    if (twin != null && launcher.reveal(twin.id)) {
      return ExplorerResult(
        ExplorerOutcome.reattached,
        message: '"${twin.title}" is already running this conversation.',
      );
    }

    var externalId = session.externalSessionId;
    String? continueNotice;
    if (externalId == null || externalId.isEmpty) {
      // The CLI never told us its id — but for an agent whose store records
      // which conversation each directory last used, that is not the end of it.
      // `planAntigravityResume` reads the entry and either names what it would
      // continue or refuses for a reason of its own; `null` means the question
      // does not apply to this agent.
      final plan = await _ref.read(antigravityResumePlannerProvider)(session);
      final resolved = plan == null ? null : conversationIn(plan);
      if (plan is AntigravityResumeRefused) {
        // The row is still selected so its detail is on screen; what changes is
        // that the message now says *which* of several situations this is.
        return ExplorerResult(ExplorerOutcome.selected, message: plan.reason);
      }
      if (resolved == null) {
        // Nothing to resume: starting the agent here would be a *new*
        // conversation wearing this row's title. The menu's "Copy resume
        // command" is the honest way out, and the row is selected so its
        // transcript is on screen.
        //
        // With a *reason*, because silence is indistinguishable from a dead
        // click. The words are the ones `resumeSession` already uses.
        return const ExplorerResult(
          ExplorerOutcome.selected,
          message:
              'No resumable CLI session id was recorded for this one. For an '
              'older session, open its imported CLI history entry instead; new '
              'sessions capture their id automatically.',
        );
      }
      // Written before the launch, not after: `SessionLauncher` reuses the row
      // that already holds the conversation, so without this the click would
      // mint a *second* row and leave this one a phantom for ever.
      _ref
          .read(sessionDaoProvider)
          .updateExternalSessionId(sessionId, resolved);
      externalId = resolved;
      continueNotice = antigravityContinueNotice(
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
        // Unreachable in practice — every way `hostedLive` can be true is a
        // pane the two reveals above would have brought back. Kept because the
        // one thing this branch must never do is fall through to a launch: a
        // conversation we are certain we hold is the double-writer case.
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
      // A session whose recorded directory has gone — an unmounted drive, a
      // stopped distro — is resumed at the repository root instead. That is a
      // different conversation to the agent, whose store is keyed by
      // directory, so the one thing this must not do is happen quietly.
      // Both notices matter and neither replaces the other: one says which
      // conversation is being continued, the other that it is being continued
      // somewhere other than where it ran.
      final notices = [?continueNotice, ?launched.workingDirectoryNotice];
      return ExplorerResult(
        ExplorerOutcome.resumed,
        message: notices.isEmpty ? null : notices.join(' '),
      );
    } catch (error) {
      return ExplorerResult(ExplorerOutcome.failed, message: _say(error));
    }
  }

  /// Resumes the session whose **restored** pane is [paneId].
  ///
  /// The terminal's own way in, for the button on a dormant agent pane's status
  /// bar. It is deliberately [openNative] and not a second implementation: the
  /// pane says which session it is holding history for, and every question
  /// after that — is one of our processes already on this conversation, did a
  /// previous resume leave a twin row, will this agent share a conversation at
  /// all, is there a CLI id to resume in the first place — has exactly one
  /// answer in this app and it is the one above.
  ///
  /// **Nothing is started here.** `SessionLauncher` looks for a pane still
  /// marked `PaneLiveness.restored` and runs its newly built `--resume` in it,
  /// so this pane is the one the launch is about to claim; giving it a process
  /// first would take it away from the resume and leave two terminals for one
  /// session. See `shouldResumeRatherThanRestart`.
  ///
  /// A pane with no session behind it is not an error worth a dialog — an agent
  /// pane opened outside a session row has nothing to resume, and saying so is
  /// the whole answer.
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

  /// Resumes every pane holding restored agent history, one pane per frame.
  ///
  /// The answer to *"give me an easy button to resume all active tabs"*, and
  /// the reason it is not a `for` loop over [resumeRestoredPane]:
  ///
  /// * **A frame between panes.** Four resumes back to back are one unbroken
  ///   block of main-isolate work and the window is frozen for the sum of it.
  ///   See [frameYieldProvider] for why the wait is a frame and not a guessed
  ///   delay.
  /// * **One layout save for all of them.** Each resume ends in a full
  ///   structural write; [TerminalSessionsController.withOneLayoutSave] holds
  ///   them and writes once at the end, the way [closeTabs] does for a bulk
  ///   close.
  ///
  /// The pane list is taken **once**, before anything starts: each resume
  /// claims the pane it was offered, so re-asking mid-loop would only be able
  /// to disagree with itself.
  ///
  /// Refusals are counted rather than thrown. One session that cannot be
  /// resumed is not a reason to leave the other three dormant, and it is not
  /// something the user can act on in the middle of a bulk verb — but it is
  /// something they must be told about at the end, or the button silently did
  /// less than it said.
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

  /// Opens an imported CLI session: reattach when we are already running that
  /// conversation, otherwise resume it in place (which replaces the imported
  /// row with a live one — [SessionActions.resumeImported] owns that).
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

  /// Starts a session in [repository], or in [existingWorktree] when a worktree
  /// row asked for it.
  ///
  /// [installation] is the "…with" choice; omitted, the configured default agent
  /// for the repository's environment is used, which is what makes `+` a single
  /// click rather than a dialog.
  ///
  /// **A worktree with no `repositories` row of its own is startable now.** Loop
  /// 57 could only offer `+` where the workspace happened to have a row at that
  /// exact path, because a session needs a repository id and there was no way to
  /// say "this id, but run over there". [existingWorktree] is that way: the
  /// owning repository supplies the id and the worktree supplies the directory.
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
    _ref
        .read(selectedRepositoryIdProvider.notifier)
        .select(session.repositoryId);
    _ref.read(selectedImportedSessionIdProvider.notifier).select(null);
    _ref.read(selectedSessionIdProvider.notifier).select(session.id);
  }

  void selectImported(ImportedSession session) {
    _ref
        .read(selectedRepositoryIdProvider.notifier)
        .select(session.repositoryId);
    _ref.read(selectedSessionIdProvider.notifier).select(null);
    _ref.read(selectedImportedSessionIdProvider.notifier).select(session.id);
  }

  /// Another of our rows for the same CLI conversation whose pane is live.
  ///
  /// `SessionLauncher.runningSessionWithExternalId` asks the DAO for *a* row
  /// with that external id and takes the first of them; once a resume has
  /// produced a second row (it mints one — see the loop report) the first is the
  /// dead one, so that check comes back empty and the click launches a third
  /// process. Scanning every row costs one query on a click and cannot be fooled
  /// that way — and it is deliberately not scoped to the repository, because a
  /// resume that joined an existing worktree can land the twin on a different
  /// repository row from the one clicked.
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

  /// The user-facing half of an error. A [StateError]'s message is already
  /// written for a human; anything else is shown as it stands rather than
  /// swallowed.
  String _say(Object error) => switch (error) {
    StateError() => error.message,
    SessionAlreadyRunning() => error.toString(),
    _ => '$error',
  };
}

final explorerActionsProvider = Provider<ExplorerActions>(
  (ref) => ExplorerActions(ref),
);
