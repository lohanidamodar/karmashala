import '../../../features/workspaces/data/workspace_data.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
  TypedCommandRunner(this._container, {required this.say});

  final ProviderContainer _container;

  /// Tells the user what happened when the screen alone would not.
  final void Function(String message) say;

  Future<void> run(CommandAction action) => switch (action) {
    StartCommand() => _start(action),
    OpenTerminalCommand() => Future.sync(() => _openTerminal(action)),
    AnswerCommand() => Future.sync(() => _answer(action)),
    StopCommand() => Future.sync(() => _stop(action)),
    ForkCommand() => _fork(action),
    EndCommand() => Future.sync(() => _end(action)),
    // Resuming is quick open's own session jump, which the palette runs.
    ResumeCommand() => Future.value(),
  };

  Future<void> _start(StartCommand command) async {
    Repository repository;
    try {
      repository =
          commandDefaultCheckout(_container, command.projectId) ??
          await _container
              .read(projectsControllerProvider.notifier)
              .ensureRunLocation(command.projectId);
    } on StateError catch (error) {
      say(error.message);
      return;
    }
    final installation = _container
        .read(agentInstallationDaoProvider)
        .getById(command.installationId);
    if (installation == null ||
        installation.environmentId != repository.path.environmentId) {
      say('That agent is no longer installed where this project runs.');
      return;
    }
    // The card the session appears on has to be on screen, as the `+` does.
    if (_container.read(selectedProjectIdProvider) != command.projectId) {
      _container
          .read(selectedProjectIdProvider.notifier)
          .select(command.projectId);
    }
    final explorer = _container.read(explorerActionsProvider);
    if (!command.worktree) {
      final result = await explorer.startSession(
        repository: repository,
        installation: installation,
      );
      if (result.message case final message?) say(message);
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
        ),
      );
      explorer.selectNative(launched.session);
    } on WorktreeCreationCancelled catch (error) {
      say('Cancelled. ${error.cleanup}');
    } catch (error) {
      say(error is StateError ? error.message : 'Could not start: $error');
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
