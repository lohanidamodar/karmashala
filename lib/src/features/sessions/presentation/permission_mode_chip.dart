import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../../app/widgets/desktop_dialog.dart';
import '../../../app/widgets/desktop_menu.dart';
import '../../agents/domain/agent_descriptor.dart';
import '../../agents/domain/agent_permission_options.dart';
import '../../agents/presentation/permission_mode_picker.dart';
import '../../settings/domain/permission_mode.dart';
import '../application/session_launcher.dart';
import '../application/session_notice.dart';
import '../application/session_signals.dart';

/// The composer's permission control: the mode this session will run under, and
/// a menu of the modes its agent can actually be put into.
///
/// Three rules, each of which is the fix for something:
///
/// * **It shows the *effective* mode**, resolved by `SessionLauncher` — the same
///   call the launcher makes. The chip cannot drift from the command line
///   because there is no second resolution to drift from.
/// * **Only modes the descriptor can express are selectable** (Loop 31 §4,
///   option C). The rest are listed, disabled, and say why. The user cannot ask
///   for something that would be silently dropped.
/// * **A session following the default says so, and can go back to it.** The
///   resolved mode drawn bare would read as this session's own decision, when
///   in fact it tracks the Settings default and moves when that moves — two
///   states that must not look alike. The menu's first row is the way back,
///   without which the first pick would be irreversible.
/// * **Changing it does not touch the running process.** Every agent here reads
///   its permission policy off the command line at startup, so the chip says the
///   change applies on the next launch instead of implying the live agent has
///   been re-governed. What it *does* offer is a restart — a second process
///   under the new flags, on the same conversation — and it never performs one
///   without saying what a restart costs: the turn in flight, and the tokens
///   the next message spends re-sending the conversation.
/// One row of the permission menu: a mode to set for this session, or the
/// Settings default to hand it back to.
///
/// A type of its own rather than a nullable [PermissionMode] because
/// `PopupMenuButton` reads a null selection as a *dismissal* and never calls
/// `onSelected` for it — so "follow the default" written as a null value would
/// have looked right and done nothing.
@immutable
class PermissionChoice {
  const PermissionChoice(this.mode);

  /// Follow the per-agent default in Settings, live.
  static const followDefault = PermissionChoice(null);

  final PermissionMode? mode;

  @override
  bool operator ==(Object other) =>
      other is PermissionChoice && other.mode == mode;

  @override
  int get hashCode => mode.hashCode;
}

class PermissionModeChip extends ConsumerWidget {
  const PermissionModeChip({required this.sessionId, super.key});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The row is what the mode lives on, so a write has to be able to redraw
    // this — and only a write to *this* row does. `setPermissionMode`
    // publishes `SessionChange.reconfigured` against the same id.
    ref.watchSession(sessionId);
    final launcher = ref.read(sessionLauncherProvider);
    final effective = launcher.effectivePermissionFor(sessionId);
    if (effective == null) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final options = permissionOptionsFor(effective.descriptor);
    final current = options.firstWhere((o) => o.mode == effective.mode);

    // Colour carries meaning only: a mode we cannot enforce and a bypass are
    // both things the user should notice, and nothing else is tinted.
    final alarming =
        current.fit == PermissionModeFit.none || current.mode.isDangerous;
    final foreground = alarming ? scheme.error : scheme.onSurfaceVariant;

    return PopupMenuButton<PermissionChoice>(
      tooltip: '',
      position: PopupMenuPosition.over,
      onSelected: (choice) =>
          _apply(context, ref, launcher, choice.mode, current),
      itemBuilder: (context) => [
        // First, and its own row: handing the session back to the Settings
        // default is where every session starts and the only state that follows
        // a later change to that setting. It names what the default resolves to
        // *today*, because "follow the default" is not an answer to "what will
        // this run under" — and that is the question the menu was opened with.
        DesktopMenuDetailItem<PermissionChoice>(
          value: PermissionChoice.followDefault,
          selected: effective.inherited,
          label: 'Follow the Settings default',
          detail:
              'Currently ${current.mode.label.toLowerCase()} for '
              '${current.agentName}. Changing that setting changes this '
              'session too.',
        ),
        const DesktopMenuDivider(),
        for (final option in options)
          DesktopMenuDetailItem<PermissionChoice>(
            value: PermissionChoice(option.mode),
            enabled: option.isSelectable,
            selected: !effective.inherited && option.mode == current.mode,
            label: option.mode.label,
            badge: option.fitLabel,
            badgeColor: permissionFitColour(
              Theme.of(context).colorScheme,
              option.fit,
            ),
            detail: option.summary,
          ),
      ],
      child: Tooltip(
        message: _tooltip(current, inherited: effective.inherited),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: Insets.sm,
            vertical: 3,
          ),
          // The composer bar has exactly one flexible cell — the delivery strip
          // — and this is not it, so an unbounded chip pushes the whole row
          // into overflow at the minimum window with Windows' largest text
          // step. A third of the window is the most this control may take;
          // past that it gives up the tail of a qualifier rather than the row.
          constraints: BoxConstraints(
            maxWidth: MediaQuery.sizeOf(context).width / 3,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Radii.sm),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _iconFor(current.fit, current.mode),
                size: Chrome.iconSmall,
                color: foreground,
              ),
              const SizedBox(width: Insets.xs),
              // The mode's own name is the last thing to be given up, so it is
              // rigid and the qualifiers below are not.
              Text(
                current.mode.shortLabel,
                style: theme.textTheme.labelSmall?.copyWith(color: foreground),
              ),
              // Both qualifiers are on the chip, not only in the tooltip.
              // "Accept edits" that is really Codex's sandbox has to look
              // different from one that really is accept-edits, and a mode this
              // session is merely *following* has to look different from one it
              // chose — neither is discoverable by hovering.
              for (final qualifier in [
                if (effective.inherited) 'default',
                if (current.fit != PermissionModeFit.exact) current.fitLabel,
              ]) ...[
                const SizedBox(width: Insets.xs),
                Flexible(
                  child: Text(
                    '· $qualifier',
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: foreground,
                    ),
                  ),
                ),
              ],
              // A disclosure caret, a step under the chip's own glyph — the
              // same 11 the model chip and the permission picker draw.
              Icon(AppIcons.caretDown, size: 11, color: foreground),
            ],
          ),
        ),
      ),
    );
  }

  static IconData _iconFor(PermissionModeFit fit, PermissionMode mode) =>
      switch (fit) {
        PermissionModeFit.none => AppIcons.warningCircle,
        PermissionModeFit.approximate => AppIcons.info,
        PermissionModeFit.exact =>
          mode.isDangerous ? AppIcons.warning : AppIcons.check,
      };

  String _tooltip(AgentPermissionOption current, {required bool inherited}) {
    // "Following" rather than "inherited": inheriting sounds like something
    // that happened once, and the whole point of this state is that it is live
    // — change the setting and this session changes with it.
    final origin = inherited
        ? 'Following the ${current.agentName} default in Settings, so it '
              'changes when that setting does.'
        : 'Set for this session, and it stays set when the Settings default '
              'changes.';
    return '${current.mode.label}\n$origin\n${current.summary}';
  }

  Future<void> _apply(
    BuildContext context,
    WidgetRef ref,
    SessionLauncher launcher,
    PermissionMode? mode,
    AgentPermissionOption current,
  ) async {
    // The session's own bar rather than `ScaffoldMessenger`. Everything said
    // below is true of this session and false of the others open beside it, and
    // a snackbar says it across the bottom of the window with nothing naming
    // which session it means — while covering the status bar to do it.
    final notices = ref.read(sessionNoticesProvider.notifier);
    final running = launcher.livePaneFor(sessionId) != null;

    // Asked **before** the row is written, so Cancel leaves the session exactly
    // as the user found it — the mode unchanged and the agent still running.
    // Writing first and offering to undo would be a different promise: the
    // session would already be recorded as bypassing prompts, and the next
    // resume from anywhere else in the app would honour it.
    if (mode != null && mode.isDangerous) {
      final confirmed = await _confirmDangerous(
        context,
        mode: mode,
        option: current,
        restarts: running,
      );
      if (confirmed != true) return;
    }

    launcher.setPermissionMode(sessionId, mode);

    // The dialog above already said what a restart costs and the user said yes
    // to it, so this is the restart — not a second prompt for the same answer.
    if (mode != null && mode.isDangerous && running) {
      await _restart(notices, launcher, savedLabel: mode.label);
      return;
    }

    // Only claim what happened. A live agent was started with the old flags and
    // there is no documented way to re-govern any of these CLIs mid-session, so
    // saying anything else here would be the lie this control exists to remove.
    final what = mode == null
        ? 'Following the ${current.agentName} default in Settings'
        : mode.label;
    notices.post(
      sessionId,
      SessionNotice(
        message: running
            // Names both costs on the face of the message rather than behind
            // the button, because the action is one tap and the user has no
            // dialog to read them in. The token cost is the one nobody
            // expects: `--resume` reloads the transcript locally for nothing,
            // and then the next message carries all of it to the model.
            ? '$what — applies the next time this session is '
                  'launched or resumed, not to the agent running now. '
                  'Restarting ends the agent running now, and the next '
                  'message re-sends the conversation as context.'
            : '$what — applies when this session next runs.',
        // Only when something is running. With nothing to end, "applies when
        // this session next runs" is already true and a restart button would be
        // offering to solve a problem the user does not have.
        action: running
            ? SessionNoticeAction(
                label: 'Restart to apply',
                onPressed: () => _restart(notices, launcher, savedLabel: what),
              )
            : null,
      ),
    );
  }

  /// Runs the restart and reports either outcome.
  ///
  /// Takes the notices and the launcher rather than a [BuildContext] and a
  /// [WidgetRef] because both of its callers outlive the widget: one awaits a
  /// dialog, the other is a bar action the user may press seconds later, by
  /// which time the composer may have been rebuilt for another session. Both
  /// read from the root container, so they stay valid either way — and the
  /// outcome still lands in the right session's bar, which is the one thing a
  /// captured `BuildContext` could not promise.
  ///
  /// [savedLabel] is what was already written to the row. A failed restart must
  /// still say the choice was kept, or the user is left believing the whole
  /// action was rejected and picks the mode again.
  Future<void> _restart(
    SessionNotices notices,
    SessionLauncher launcher, {
    required String savedLabel,
  }) async {
    try {
      await launcher.restartSession(sessionId);
      notices.post(
        sessionId,
        SessionNotice(message: '$savedLabel — session restarted.'),
      );
    } on Object catch (error) {
      // `StateError.message` rather than the exception's `toString`, which
      // prefixes "Bad state:" — the same unwrapping the Explorer does.
      final reason = error is StateError ? error.message : '$error';
      notices.post(
        sessionId,
        SessionNotice(
          message: '$savedLabel is saved, but the restart failed. $reason',
          tone: SessionNoticeTone.warning,
        ),
      );
    }
  }

  /// Confirms a mode that removes the prompts, naming every consequence of
  /// saying yes.
  ///
  /// Three of them when [restarts], and the second and third are the ones the
  /// user cannot see coming:
  ///
  /// * bypass itself, which is the reason the mode is marked
  ///   [PermissionMode.isDangerous] and is the only one the chip's colour
  ///   already hints at;
  /// * the restart, because the flags are only read at startup — an agent
  ///   part-way through a turn is killed with that turn, and the resume picks
  ///   up from the last exchange the CLI wrote rather than from where it had
  ///   actually got to;
  /// * the tokens. Resuming reads the transcript off disk and costs nothing,
  ///   but the next message sends the accumulated conversation to the model as
  ///   input. Prompt caching discounts a prefix that is still warm; its TTL is
  ///   minutes, so a restart after a pause pays in full, and the longer the
  ///   session the larger that bill.
  ///
  /// With nothing running only the first applies, and the other two are left
  /// out rather than softened — a warning about ending an agent that is not
  /// there teaches the user to click through the next one.
  Future<bool?> _confirmDangerous(
    BuildContext context, {
    required PermissionMode mode,
    required AgentPermissionOption option,
    required bool restarts,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (context) {
        final theme = Theme.of(context);
        return AlertDialog(
          // Three paragraphs do not fit an 800x600 window, let alone a phone,
          // and a warning the user cannot read to the end is worse than none:
          // the cost they scroll to is the one this dialog was added for.
          scrollable: true,
          title: DesktopDialogTitle(
            icon: AppIcons.warning,
            title: '${mode.label}?',
            subtitle: restarts
                ? 'This restarts the session.'
                : 'This applies the next time the session runs.',
          ),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${option.agentName} will make every file edit and run '
                  'every command without asking. You will not be prompted, '
                  'and nothing here can stop a command the agent has already '
                  'decided to run.',
                ),
                if (restarts) ...[
                  const SizedBox(height: Insets.md),
                  Text(
                    'The agent running now is ended, because these flags are '
                    'only read when it starts. If it is part-way through a '
                    'turn, that work is lost: the resume continues from the '
                    'last exchange it recorded, not from where it had got to.',
                  ),
                  const SizedBox(height: Insets.md),
                  Text(
                    'Resuming itself costs nothing — the conversation is read '
                    'back from disk. The next message you send is what costs: '
                    'it carries the whole conversation to the model as '
                    'context, so a session that has run a long time is not '
                    'cheap to pick up again.',
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: theme.colorScheme.error,
                foregroundColor: theme.colorScheme.onError,
              ),
              onPressed: () => Navigator.of(context).pop(true),
              // Says what the button does, not that it agrees: "OK" on a
              // dialog offering three consequences names none of them.
              child: Text(restarts ? 'Restart in bypass' : 'Use bypass'),
            ),
          ],
        );
      },
    );
  }
}
