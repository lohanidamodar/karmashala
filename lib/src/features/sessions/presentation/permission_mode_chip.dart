import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../agents/domain/agent_descriptor.dart';
import '../../agents/domain/agent_permission_options.dart';
import '../../settings/domain/permission_mode.dart';
import '../application/session_launcher.dart';
import '../application/session_ui_providers.dart';

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
/// * **Changing it does not touch the running process.** Every agent here reads
///   its permission policy off the command line at startup, so the chip says the
///   change applies on the next launch instead of implying the live agent has
///   been re-governed.
class PermissionModeChip extends ConsumerWidget {
  const PermissionModeChip({required this.sessionId, super.key});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The row is what the mode lives on, so a write has to be able to redraw
    // this. `setPermissionMode` bumps the same revision every other session
    // mutation does.
    ref.watch(sessionsRevisionProvider);
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

    return PopupMenuButton<PermissionMode>(
      tooltip: '',
      position: PopupMenuPosition.over,
      onSelected: (mode) => _apply(context, ref, launcher, mode),
      itemBuilder: (context) => [
        for (final option in options)
          PopupMenuItem<PermissionMode>(
            value: option.mode,
            enabled: option.isSelectable,
            child: _MenuRow(
              option: option,
              selected: option.mode == current.mode,
            ),
          ),
      ],
      child: Tooltip(
        message: _tooltip(current, inherited: effective.inherited),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: Insets.sm,
            vertical: 3,
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
                size: 13,
                color: foreground,
              ),
              const SizedBox(width: Insets.xs),
              Text(
                current.mode.shortLabel,
                style: theme.textTheme.labelSmall?.copyWith(color: foreground),
              ),
              // The fit is on the chip, not only in the tooltip: "Accept edits"
              // that is really Codex's sandbox has to look different from one
              // that is really accept-edits, without a hover.
              if (current.fit != PermissionModeFit.exact) ...[
                const SizedBox(width: Insets.xs),
                Text(
                  '· ${current.fitLabel}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: foreground,
                  ),
                ),
              ],
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
    final origin = inherited
        ? 'Inherited from the ${current.agentName} default in Settings.'
        : 'Set for this session.';
    return '${current.mode.label}\n$origin\n${current.summary}';
  }

  void _apply(
    BuildContext context,
    WidgetRef ref,
    SessionLauncher launcher,
    PermissionMode mode,
  ) {
    final messenger = ScaffoldMessenger.of(context);
    final running = launcher.livePaneFor(sessionId) != null;
    launcher.setPermissionMode(sessionId, mode);
    // Only claim what happened. A live agent was started with the old flags and
    // there is no documented way to re-govern any of these CLIs mid-session, so
    // saying anything else here would be the lie this control exists to remove.
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          running
              ? '${mode.label} — applies the next time this session is '
                    'launched or resumed, not to the agent running now.'
              : '${mode.label} — applies when this session next runs.',
        ),
      ),
    );
  }
}

class _MenuRow extends StatelessWidget {
  const _MenuRow({required this.option, required this.selected});

  final AgentPermissionOption option;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = !option.isSelectable;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 18,
          child: selected
              ? Icon(AppIcons.check, size: 13, color: scheme.primary)
              : null,
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      option.mode.label,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: muted ? scheme.onSurfaceVariant : null,
                      ),
                    ),
                  ),
                  const SizedBox(width: Insets.xs),
                  Text(
                    option.fitLabel,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: switch (option.fit) {
                        PermissionModeFit.exact => scheme.onSurfaceVariant,
                        PermissionModeFit.approximate => scheme.tertiary,
                        PermissionModeFit.none => scheme.error,
                      },
                    ),
                  ),
                ],
              ),
              Text(
                option.summary,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
