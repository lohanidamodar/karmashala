import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../../app/widgets/desktop_dialog.dart';
import '../../../app/widgets/desktop_menu.dart';
import 'package:agent_cli/descriptors.dart';
import '../application/session_launcher.dart';
import '../application/session_notice.dart';
import '../application/session_signals.dart';

/// The composer's permission control: the mode this session will run under, and
/// a menu of the modes its agent can actually be put into.
///
/// It shows the *effective* mode, resolved by the same `SessionLauncher` call
/// the launcher makes; only modes the descriptor can express are selectable;
/// and a session following the Settings default says so and can go back, which
/// is what stops the first pick being irreversible. Changing it never touches
/// the running process — the policy is read off the command line at startup —
/// so the chip offers a restart and never performs one without saying what it
/// costs.
///
/// One row of the permission menu: a value on one axis, or the Settings
/// default. A type of its own rather than a nullable selection because
/// `PopupMenuButton` reads a null selection as a *dismissal*.
@immutable
class PermissionChoice {
  const PermissionChoice(this.axisId, this.valueId);

  /// Follow the per-agent default in Settings, live.
  static const followDefault = PermissionChoice(null, null);

  /// Which axis this row belongs to, or null for [followDefault]. Two axes may
  /// name values alike, so the value id alone is not an answer.
  final String? axisId;
  final String? valueId;

  @override
  bool operator ==(Object other) =>
      other is PermissionChoice &&
      other.axisId == axisId &&
      other.valueId == valueId;

  @override
  int get hashCode => Object.hash(axisId, valueId);
}

class PermissionModeChip extends ConsumerWidget {
  const PermissionModeChip({required this.sessionId, super.key});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The row is what the mode lives on, and only a write to *this* row redraws
    // it: `setPermissionMode` publishes `reconfigured` against the same id.
    ref.watchSession(sessionId);
    final launcher = ref.read(sessionLauncherProvider);
    final effective = launcher.effectivePermissionFor(sessionId);
    if (effective == null) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final agentName = effective.descriptor?.displayName ?? 'This agent';
    final support = effective.descriptor?.launch.permission;
    final known = support != null && support.isKnown;
    final axes = permissionAxisOptionsFor(
      effective.descriptor,
      selection: effective.selection,
      agentName: agentName,
    );

    // Colour carries meaning only: an agent we cannot govern and a selection
    // that bypasses everything. Nothing else is tinted.
    final dangerous = known && support.isDangerous(effective.selection);
    final foreground = !known || dangerous
        ? scheme.error
        : scheme.onSurfaceVariant;
    // The familiar name for the rung, ahead of this CLI's own word for it —
    // never instead of it. See `pairedWithFamiliarName`.
    final label = known
        ? describeSelectionFamiliarShort(support, effective.selection)
        : 'Not established';

    return PopupMenuButton<PermissionChoice>(
      tooltip: '',
      position: PopupMenuPosition.over,
      onSelected: (choice) =>
          _apply(
            context,
            ref,
            launcher,
            choice,
            effective.selection,
            support,
            agentName,
          ),
      itemBuilder: (context) => [
        // First, and its own row: the default is where every session starts and
        // the only state that follows a later change to that setting. It names
        // what it resolves to *today* — the question the menu was opened with.
        DesktopMenuDetailItem<PermissionChoice>(
          value: PermissionChoice.followDefault,
          selected: effective.inherited,
          label: 'Follow the Settings default',
          detail: known
              ? 'Currently ${describeSelection(support, effective.selection)} '
                    'for $agentName. Changing that setting changes this '
                    'session too.'
              : unknownAgentReason(agentName),
        ),
        const DesktopMenuDivider(),
        if (!known)
          DesktopMenuDetailItem<PermissionChoice>(
            value: const PermissionChoice(null, null),
            enabled: false,
            label: 'No permission modes established',
            detail: unknownAgentReason(agentName),
          )
        else
          for (final axis in axes) ...[
            // Only when there is more than one: a flat list would imply Codex's
            // sandbox and approval policy are one question with seven answers.
            if (axes.length > 1) DesktopMenuHeader<PermissionChoice>(axis.label),
            for (final option in axis.options)
              DesktopMenuDetailItem<PermissionChoice>(
                value: PermissionChoice(axis.id, option.id),
                enabled: option.isSelectable,
                selected: !effective.inherited && option.id == axis.selectedId,
                label: option.pairedLabel,
                detail: option.summary,
              ),
            if (axis != axes.last) const DesktopMenuDivider(),
          ],
      ],
      child: Tooltip(
        message: _tooltip(
          support,
          effective.selection,
          agentName: agentName,
          inherited: effective.inherited,
          unrecognised: effective.unrecognised,
        ),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: Insets.sm,
            vertical: 3,
          ),
          // The composer bar's one flexible cell is the delivery strip, not
          // this, so an unbounded chip overflows the row at the minimum window.
          // A third of the width; past that it gives up a qualifier's tail.
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
                !known
                    ? AppIcons.warningCircle
                    : dangerous
                    ? AppIcons.warning
                    : AppIcons.check,
                size: Chrome.iconSmall,
                color: foreground,
              ),
              const SizedBox(width: Insets.xs),
              // The mode's own name is what the chip is for, so it gives up its
              // tail before the row does. Codex's two axes make it long.
              Flexible(
                child: Text(
                  label,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: foreground,
                  ),
                ),
              ),
              // A mode this session is merely *following* has to look different
              // from one it chose, and that is not discoverable by hovering.
              for (final qualifier in [
                if (effective.inherited) 'default',
                // A mode this build does not name, substituted down to the
                // agent's default. Said on the face rather than only on hover:
                // the user set something else.
                if (effective.unrecognised) 'unrecognised',
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

  String _tooltip(
    AgentPermissionSupport? support,
    PermissionSelection selection, {
    required String agentName,
    required bool inherited,
    required bool unrecognised,
  }) {
    if (support == null || !support.isKnown) {
      return unknownAgentReason(agentName);
    }
    // "Following" rather than "inherited": inheriting sounds like something
    // that happened once, and the point of this state is that it is live.
    final origin = inherited
        ? 'Following the $agentName default in Settings, so it changes when '
              'that setting does.'
        : 'Set for this session, and it stays set when the Settings default '
              'changes.';
    if (unrecognised) {
      return '${describeSelection(support, selection)}\n'
          'This session was set to a mode this build of Karmashala does not '
          'name — by a newer build, or by hand. It runs under the '
          '$agentName default shown here instead.';
    }
    final detail = describeSelectionDetail(support, selection) ?? '';
    return '${describeSelection(support, selection)}\n$origin\n$detail';
  }

  Future<void> _apply(
    BuildContext context,
    WidgetRef ref,
    SessionLauncher launcher,
    PermissionChoice choice,
    PermissionSelection currentSelection,
    AgentPermissionSupport? support,
    String agentName,
  ) async {
    // One axis changes; the rest of the selection is carried through unchanged,
    // so picking a sandbox never silently resets the approval policy beside it.
    final selection = choice.axisId == null || support == null
        ? null
        : support.normalise(
            PermissionSelection({
              ...support.normalise(currentSelection).values,
              choice.axisId!: choice.valueId!,
            }),
          );
    final dangerous =
        selection != null && (support?.isDangerous(selection) ?? false);
    final label = selection == null || support == null
        ? ''
        : describeSelection(support, selection);
    // The session's own bar rather than `ScaffoldMessenger`: everything below
    // is true of this session and false of the others open beside it.
    final notices = ref.read(sessionNoticesProvider.notifier);
    final running = launcher.livePaneFor(sessionId) != null;

    // Asked **before** the row is written, so Cancel leaves the session exactly
    // as the user found it. Writing first and offering to undo would already
    // have recorded a session that bypasses prompts, and a resume would honour it.
    if (dangerous) {
      final confirmed = await _confirmDangerous(
        context,
        label: label,
        detail: describeSelectionDetail(support!, selection) ?? '',
        agentName: agentName,
        restarts: running,
      );
      if (confirmed != true) return;
    }

    launcher.setPermissionMode(sessionId, selection);

    // The dialog above already said what a restart costs and the user said yes
    // to it, so this is the restart — not a second prompt for the same answer.
    if (dangerous && running) {
      await _restart(notices, launcher, savedLabel: label);
      return;
    }

    // Only claim what happened: a live agent was started with the old flags and
    // there is no documented way to re-govern any of these CLIs mid-session.
    final what = selection == null
        ? 'Following the $agentName default in Settings'
        : label;
    notices.post(
      sessionId,
      SessionNotice(
        message: running
            // Names both costs on the face of the message rather than behind
            // Names both costs on the face of the message: the token one is the
            // one nobody expects — `--resume` reloads the transcript locally
            // for nothing, then the next message carries all of it to the model.
            ? '$what — applies the next time this session is '
                  'launched or resumed, not to the agent running now. '
                  'Restarting ends the agent running now, and the next '
                  'message re-sends the conversation as context.'
            : '$what — applies when this session next runs.',
        // Only when something is running. With nothing to end, a restart button
        // offers to solve a problem the user does not have.
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
  /// [WidgetRef] because both callers outlive the widget; both read from the
  /// root container, so the outcome still lands in the right session's bar.
  ///
  /// [savedLabel] is what was already written to the row: a failed restart must
  /// still say the choice was kept, or the user picks the mode again.
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
  /// Three of them when [restarts], and the last two are the ones the user
  /// cannot see coming: the restart, because the flags are only read at startup
  /// so a turn in flight is lost; and the tokens, because the next message
  /// re-sends the accumulated conversation and prompt caching's TTL is minutes.
  /// With nothing running only bypass applies, and the other two are left out
  /// rather than softened.
  Future<bool?> _confirmDangerous(
    BuildContext context, {
    required String label,
    required String detail,
    required String agentName,
    required bool restarts,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (context) {
        final theme = Theme.of(context);
        return AlertDialog(
          // Three paragraphs do not fit an 800x600 window, and a warning the
          // user cannot read to the end is worse than none.
          scrollable: true,
          title: DesktopDialogTitle(
            icon: AppIcons.warning,
            title: '$label?',
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
                  '$agentName will make every file edit and run every command '
                  'without asking. You will not be prompted, and nothing here '
                  'can stop a command the agent has already decided to run.',
                ),
                // The agent's own words for what was picked. For Codex that is
                // the pair — each unremarkable, together leaving nothing in the
                // way — which the user has no other way to see.
                if (detail.isNotEmpty) ...[
                  const SizedBox(height: Insets.md),
                  Text(detail),
                ],
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
              child: Text(restarts ? 'Restart in $label' : 'Use $label'),
            ),
          ],
        );
      },
    );
  }
}
