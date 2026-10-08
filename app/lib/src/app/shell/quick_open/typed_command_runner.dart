import '../../../features/workspaces/data/workspace_data.dart';
import 'package:flutter/widgets.dart' show WidgetsBinding;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_remote/host.dart' show RemoteApiRefusal;
import 'package:karmashala_remote/remote.dart'
    show RemoteQuestionAnswer, RemoteQuestionAnswerRequest;

import '../../../features/overview/application/overview_prefs.dart';
import '../../../features/overview/application/overview_providers.dart';
import '../../../features/overview/application/overview_quick_message.dart';
import '../../../features/overview/application/overview_resume.dart';
import '../../../features/remote/application/remote_approval_bindings.dart';
import '../../../features/sessions/application/session_actions.dart';
import '../../../features/sessions/presentation/approval_request_card.dart'
    show BoardApproval, answerBoardApprovalBy;
import 'package:karmashala_git/git.dart';
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala_session/launch.dart';

import '../../../features/agents/application/agent_providers.dart';
import '../../../features/explorer/application/checkout_default.dart';
import '../../../features/explorer/application/checkout_picker.dart';
import '../../../features/explorer/application/explorer_actions.dart';
import '../../../features/git/application/changes_providers.dart';
import 'package:karmashala_git/worktrees.dart';
import '../../../features/notifications/application/attention_inbox.dart';
import '../../../features/projects/application/projects_controller.dart';
import '../../../features/sessions/application/new_session_memory.dart';
import '../../../features/sessions/application/session_defaults.dart';
import '../../../features/sessions/application/session_handoff_service.dart';
import '../../../features/sessions/application/session_launcher.dart';
import '../../../features/sessions/application/session_providers.dart';
import '../../../features/sessions/application/session_status_providers.dart';
import '../../../features/terminal/application/terminal_profiles.dart';
import '../../../features/terminal/application/terminal_sessions_controller.dart';
import '../shell_state.dart';
import 'typed_command.dart';

/// The checkout a session started at [projectId] runs in — the one the
/// Explorer's `+` and the New-session dialog pick.
Repository? commandDefaultCheckout(
  ProviderContainer container,
  String projectId,
) {
  final project = container
      .read(sortedProjectsProvider)
      .where((p) => p.id == projectId)
      .firstOrNull;
  return projectDefaultCheckout(
    defaultRepositoryId: project?.defaultRepositoryId,
    offered: container.read(checkoutsInProjectProvider(projectId)),
    all: container.read(workspaceDataProvider).repositoriesOf(projectId),
  );
}

/// Runs a [CommandAction] through the action that already owns it; nothing
/// here decides anything those actions do not. Reads through a container, so
/// it keeps working after the palette that started it has closed.
class TypedCommandRunner {
  TypedCommandRunner(this._container, {required this.say, this.announce});

  final ProviderContainer _container;

  /// Tells the user what happened when the screen alone would not.
  final void Function(String message) say;

  /// Points at a session resumed or started with no tab: its card peeked
  /// when the dashboard shows, else a notice with Open. Null says it in
  /// words instead.
  final void Function(String sessionId, {bool started})? announce;

  /// The "Resume and start sessions in the background" setting.
  bool get _inBackground => _container.read(launchInBackgroundProvider);

  /// [sessionId], resumed or started with no tab, pointed at.
  void _announce(String sessionId, {bool started = false}) {
    final announce = this.announce;
    if (announce != null) return announce(sessionId, started: started);
    say('${started ? 'Started' : 'Resuming'} "${_title(sessionId)}".');
  }

  Future<void> run(CommandAction action) => switch (action) {
    StartCommand() => _start(action),
    OpenTerminalCommand() => Future.sync(() => _openTerminal(action)),
    AnswerCommand() => Future.sync(() => _answer(action)),
    StopCommand() => Future.sync(() => _stop(action)),
    ForkCommand() => _fork(action),
    EndCommand() => Future.sync(() => _end(action)),
    AnswerQuestionCommand() => _answerQuestion(action),
    ApprovalCommand() => _approve(action),
    MessageCommand() => _message(action),
    StopAllCommand() => Future.sync(() => _stopAll(action)),
    BackgroundResumeCommand() => _resume(action),
    ArchiveCommand() => _archive(action),
    PeekCommand() => Future.sync(() => _peek(action.sessionId)),
    // Resuming is quick open's own session jump, and the dialog needs a
    // context; the palette runs both.
    ResumeCommand() || OpenNewSessionDialogCommand() => Future.value(),
  };

  String _title(String sessionId) =>
      _container.read(sessionsDataProvider).getById(sessionId)?.title ??
      'that session';

  /// [sessionId] in the dashboard's peek once the board is up to take it.
  /// Quick open brings the dashboard forward before it runs this.
  void _peek(String sessionId) {
    _container.read(overviewPrefsProvider.notifier).setView(OverviewView.board);
    var tries = 0;
    void peekWhenUp(Duration _) {
      // The board's focus lives only while the dashboard is built.
      if (!_container.exists(overviewFocusProvider)) {
        if (++tries < 4) {
          WidgetsBinding.instance.addPostFrameCallback(peekWhenUp);
        }
        return;
      }
      _container.read(overviewFocusProvider.notifier).peek(sessionId);
    }

    WidgetsBinding.instance.addPostFrameCallback(peekWhenUp);
  }

  Future<void> _answerQuestion(AnswerQuestionCommand command) async {
    try {
      await _container.read(chatQuestionAnswerProvider)(
        RemoteQuestionAnswerRequest(
          sessionId: command.sessionId,
          toolUseId: command.toolUseId,
          answers: [
            RemoteQuestionAnswer.options([command.option]),
          ],
        ),
      );
      say('Answered "${_title(command.sessionId)}".');
    } on RemoteApiRefusal catch (refusal) {
      say(refusal.message);
    } on Object catch (error) {
      say('Could not answer: $error');
    }
  }

  /// The board's Allow and Deny, by the same path.
  Future<void> _approve(ApprovalCommand command) async {
    final refused = await answerBoardApprovalBy(
      _container.read,
      command.sessionId,
      command.allow ? BoardApproval.allow : BoardApproval.deny,
    );
    say(
      refused ??
          '${command.allow ? 'Allowed' : 'Denied'} for '
              '"${_title(command.sessionId)}".',
    );
  }

  /// The dashboard's quick message to each, which queues behind a turn that
  /// is running and resumes a session that ended.
  Future<void> _message(MessageCommand command) async {
    final quick = _container.read(overviewQuickMessageProvider);
    var queued = 0;
    final failed = <String>[];
    for (final id in command.sessionIds) {
      try {
        if (await quick.send(id, command.text) == QuickMessageOutcome.queued) {
          queued++;
        }
      } on Object catch (error) {
        failed.add(
          '"${_title(id)}": ${error is StateError ? error.message : error}',
        );
      }
    }
    final sent = command.sessionIds.length - failed.length;
    final one = command.sessionIds.length == 1;
    say(
      [
        if (sent > 0)
          one
              ? queued > 0
                    ? 'Queued for "${_title(command.sessionIds.single)}" — '
                          'it goes when the turn ends.'
                    : 'Sent to "${_title(command.sessionIds.single)}".'
              : 'Sent to $sent${queued > 0 ? ' ($queued queued behind a '
                          'turn)' : ''}.',
        if (failed.isNotEmpty) 'Not sent to ${failed.join('; ')}.',
      ].join(' '),
    );
  }

  void _stopAll(StopAllCommand command) {
    for (final id in command.sessionIds) {
      _stop(StopCommand(id));
    }
  }

  /// Round 43's Resume from the dashboard: at the server, with no tab — or,
  /// with the background setting off, into its tab.
  Future<void> _resume(BackgroundResumeCommand command) async {
    final id = command.sessionId;
    if (!_inBackground) {
      final message = command.message;
      if (message != null) {
        try {
          await _container
              .read(sessionActionsProvider)
              .continueSession(id, message);
        } on Object catch (error) {
          say(
            'Could not resume: ${error is StateError ? error.message : error}',
          );
        }
        return;
      }
      final result = await _container
          .read(explorerActionsProvider)
          .openNative(id);
      if (result.message case final message?) say(message);
      return;
    }
    final result = await _container
        .read(overviewResumerProvider)
        .resume(id, message: command.message);
    if (result.isFailure) {
      say(result.message ?? 'Could not resume "${_title(id)}".');
      return;
    }
    if (result.message case final message?) say(message);
    _announce(id);
  }

  /// The row's Archive, keeping any worktree: deleting one is asked for
  /// where it can be chosen.
  Future<void> _archive(ArchiveCommand command) async {
    try {
      final result = await _container
          .read(sessionActionsProvider)
          .archiveSessions([command.sessionId]);
      say(
        result.live.isNotEmpty
            ? '"${_title(command.sessionId)}" is still running, so it was '
                  'not archived.'
            : 'Archived "${_title(command.sessionId)}".',
      );
    } on Object catch (error) {
      say('Could not archive: ${error is StateError ? error.message : error}');
    }
  }

  /// Round 40's New session from the dashboard: started at the server, no
  /// tab, its card peeked.
  Future<void> _startHere(StartCommand command, Repository repository) async {
    final installation = _container
        .read(agentInstallationsDataProvider)
        .getById(command.installationId);
    if (installation == null ||
        installation.environmentId != repository.path.environmentId) {
      say('That agent is no longer installed where this project runs.');
      return;
    }
    try {
      final launched = await _container
          .read(sessionLauncherProvider)
          .launch(
            SessionLaunchRequest(
              repository: repository,
              installation: installation,
              title: defaultSessionTitle,
              purpose: SessionPurpose.newSession,
              firstMessage: command.firstMessage,
              openTab: false,
            ),
          );
      _container
          .read(newSessionMemoryProvider)
          .remember(
            projectId: repository.projectId,
            installationId: installation.id,
          );
      _peek(launched.session.id);
    } catch (error) {
      say(error is StateError ? error.message : 'Could not start: $error');
    }
  }

  Future<void> _start(StartCommand command) async {
    final projectId = command.projectId;
    if (projectId == null) return _startWithoutProject(command);
    Repository repository;
    try {
      repository =
          commandDefaultCheckout(_container, projectId) ??
          await _container
              .read(projectsControllerProvider.notifier)
              .ensureRunLocation(projectId);
    } on StateError catch (error) {
      say(error.message);
      return;
    }
    if (command.keepHere) return _startHere(command, repository);
    final installation = _container
        .read(agentInstallationsDataProvider)
        .getById(command.installationId);
    if (installation == null ||
        installation.environmentId != repository.path.environmentId) {
      say('That agent is no longer installed where this project runs.');
      return;
    }
    final background = _inBackground;
    // The card the session appears on has to be on screen, as the `+` does —
    // unless it starts where the person is, which moves nothing.
    if (!background &&
        _container.read(selectedProjectIdProvider) != projectId) {
      _container.read(selectedProjectIdProvider.notifier).select(projectId);
    }
    final explorer = _container.read(explorerActionsProvider);
    if (!command.worktree) {
      final result = await explorer.startSession(
        repository: repository,
        installation: installation,
        firstMessage: command.firstMessage,
        openTab: !background,
      );
      _said(result, background: background);
      return;
    }
    // The dialog's worktree path: the same launcher, asked the same way, after
    // the same refusal of a plain folder.
    final launcher = _container.read(sessionLauncherProvider);
    final presence = await _container.read(
      checkoutGitPresenceProvider(repository.path).future,
    );
    if (presence == GitPresence.notARepository) {
      say(
        '${repository.path.path} is not a Git repository, so it has no '
        'worktrees. Start without --worktree to run in the folder itself.',
      );
      return;
    }
    try {
      final launched = await launcher.launch(
        SessionLaunchRequest(
          repository: repository,
          installation: installation,
          title: defaultSessionTitle,
          purpose: SessionPurpose.newSession,
          useWorktree: true,
          firstMessage: command.firstMessage,
          openTab: !background,
        ),
      );
      _container
          .read(newSessionMemoryProvider)
          .remember(projectId: projectId, installationId: installation.id);
      if (background) {
        _announce(launched.session.id, started: true);
      } else {
        explorer.selectNative(launched.session);
      }
    } on WorktreeCreationCancelled catch (error) {
      say('Cancelled. ${error.cleanup}');
    } catch (error) {
      say(error is StateError ? error.message : 'Could not start: $error');
    }
  }

  /// The dialog's No project: a scratch folder on the agent's machine, named
  /// after what it was asked to do.
  Future<void> _startWithoutProject(StartCommand command) async {
    final installation = _container
        .read(agentInstallationsDataProvider)
        .getById(command.installationId);
    if (installation == null) {
      say('That agent is no longer installed.');
      return;
    }
    final Repository repository;
    try {
      repository = await _container
          .read(projectsControllerProvider.notifier)
          .scratchCheckout(
            installation.environmentId,
            hint: command.firstMessage ?? defaultSessionTitle,
          );
    } catch (error) {
      say('Could not make a scratch folder: $error');
      return;
    }
    final background = _inBackground;
    if (!background &&
        _container.read(selectedProjectIdProvider) != repository.projectId) {
      _container
          .read(selectedProjectIdProvider.notifier)
          .select(repository.projectId);
    }
    final result = await _container
        .read(explorerActionsProvider)
        .startSession(
          repository: repository,
          installation: installation,
          firstMessage: command.firstMessage,
          openTab: !background,
        );
    _said(result, background: background);
  }

  /// A start's result: its words, and a session started with no tab pointed
  /// at.
  void _said(ExplorerResult result, {required bool background}) {
    if (result.message case final message?) say(message);
    if (background && !result.isFailure) {
      if (result.sessionId case final id?) _announce(id, started: true);
    }
  }

  /// The terminal controller the tab bar and the Explorer's "Open terminal"
  /// call, with the profile the environment's own terminal uses.
  void _openTerminal(OpenTerminalCommand command) {
    final profile = _container
        .read(terminalProfilesProvider)
        .where((p) => p.id == command.profileId)
        .firstOrNull;
    if (profile == null) {
      say('That terminal is no longer available on this machine.');
      return;
    }
    final terminals = _container.read(
      terminalSessionsControllerProvider.notifier,
    );
    terminals.openTab(profile, workingDirectory: command.workingDirectory);
    terminals.showTerminalHere();
  }

  /// Exactly what clicking the item in the attention inbox does.
  void _answer(AnswerCommand command) {
    final inbox = _container.read(attentionInboxProvider);
    final item = inbox.items.where((i) => i.id == command.itemId).firstOrNull;
    if (item == null) {
      say('That has already been answered.');
      return;
    }
    _container.read(attentionInboxProvider.notifier).open(item);
    _container
        .read(shellControllerProvider.notifier)
        .focusPane(ShellPane.detail);
  }

  /// Esc, pressed through the launcher's own key path — only while the agent
  /// is mid-turn, never into a prompt it would answer.
  void _stop(StopCommand command) {
    final report = _container.read(sessionStatusLookupProvider)(
      command.sessionId,
    );
    if ((report?.hasOpenPrompt ?? false) ||
        (report?.hasOpenQuestion ?? false)) {
      say('It is asking you something now — Esc would answer it.');
      return;
    }
    if (!_container
        .read(sessionLauncherProvider)
        .pressKeys(command.sessionId, '\x1b')) {
      say('That session has no live terminal to interrupt.');
    }
  }

  /// `session_fork`'s path: the plan first, and its refusal in its own words.
  Future<void> _fork(ForkCommand command) async {
    final service = _container.read(sessionHandoffServiceProvider);
    final explorer = _container.read(explorerActionsProvider);
    final plan = service.forkPlanFor(command.sessionId);
    if (plan.isRefused) {
      say(plan.explanation);
      return;
    }
    try {
      final launched = await service.forkSession(sessionId: command.sessionId);
      explorer.selectNative(launched.session);
    } catch (error) {
      say(error is StateError ? error.message : 'Could not fork: $error');
    }
  }

  /// `session_end`'s path: the live pane, or the session host's session when
  /// no pane shows it, ended through the launcher.
  Future<void> _end(EndCommand command) async {
    if (_container.read(sessionsDataProvider).getById(command.sessionId) ==
        null) {
      say('That session no longer exists.');
      return;
    }
    try {
      final ended = await _container
          .read(sessionLauncherProvider)
          .endRunning(command.sessionId);
      if (ended == null) {
        say('Nothing is running that session, so there is nothing to end.');
      }
    } on Object catch (error) {
      say('Could not end that session: $error');
    }
  }
}
