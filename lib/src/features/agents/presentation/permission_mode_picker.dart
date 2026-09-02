import 'package:flutter/material.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../../app/widgets/desktop_menu.dart';
import '../../settings/domain/permission_mode.dart';
import '../domain/agent_descriptor.dart';
import '../domain/agent_permission_options.dart';

/// A menu of the permission modes one agent can be put into.
///
/// The composer's `PermissionModeChip` is this same control bound to a running
/// session. Both build their rows from [permissionOptionsFor], so what is
/// offered — and what each mode is said to do to *this* agent — cannot differ
/// between them. This one is handed its options and its selection instead of
/// reading a session, because the agent it describes is one the user has not
/// started yet and may still change their mind about.
///
/// The chip's two rules hold here unchanged:
///
/// * **Only modes the descriptor can express are selectable** (Loop 31 §4,
///   option C). The rest are listed, disabled, and say why.
/// * **The selected mode may still be one the agent cannot express.** That is
///   what "nothing is passed and the agent's own default applies" looks like,
///   and it is flagged rather than quietly shown as if it were in force.
class PermissionModePicker extends StatelessWidget {
  const PermissionModePicker({
    required this.options,
    required this.selected,
    required this.onChanged,
    super.key,
  });

  /// Every mode with how it maps onto the agent, safest first —
  /// [permissionOptionsFor]'s answer for the agent currently chosen.
  final List<AgentPermissionOption> options;

  final PermissionMode selected;
  final ValueChanged<PermissionMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final current = options.firstWhere((option) => option.mode == selected);

    // Colour carries meaning only: a mode we cannot enforce and a bypass are
    // both things the user should notice, and nothing else is tinted.
    final alarming =
        current.fit == PermissionModeFit.none || current.mode.isDangerous;
    final foreground = alarming ? scheme.error : scheme.onSurfaceVariant;

    return PopupMenuButton<PermissionMode>(
      tooltip: '',
      position: PopupMenuPosition.under,
      onSelected: onChanged,
      itemBuilder: (context) => [
        for (final option in options)
          DesktopMenuDetailItem<PermissionMode>(
            value: option.mode,
            enabled: option.isSelectable,
            selected: option.mode == current.mode,
            label: option.mode.label,
            badge: option.fitLabel,
            badgeColor: permissionFitColour(
              Theme.of(context).colorScheme,
              option.fit,
            ),
            detail: option.summary,
          ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: Insets.sm, vertical: 3),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(Radii.sm),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_iconFor(current), size: Chrome.iconSmall, color: foreground),
            const SizedBox(width: Insets.xs),
            Text(
              current.mode.shortLabel,
              style: theme.textTheme.labelSmall?.copyWith(color: foreground),
            ),
            // The fit is on the face of the control, not only in the menu:
            // "Accept edits" that is really Codex's sandbox has to look
            // different from one that is really accept-edits.
            if (current.fit != PermissionModeFit.exact) ...[
              const SizedBox(width: Insets.xs),
              Text(
                '· ${current.fitLabel}',
                style: theme.textTheme.labelSmall?.copyWith(color: foreground),
              ),
            ],
            Icon(AppIcons.caretDown, size: 11, color: foreground),
          ],
        ),
      ),
    );
  }

  static IconData _iconFor(AgentPermissionOption option) =>
      switch (option.fit) {
        PermissionModeFit.none => AppIcons.warningCircle,
        PermissionModeFit.approximate => AppIcons.info,
        PermissionModeFit.exact =>
          option.mode.isDangerous ? AppIcons.warning : AppIcons.check,
      };
}

/// How faithfully a mode reaches the agent, as a colour. Only the two worth
/// noticing are tinted; an exact fit is a fact, not a warning.
///
/// Shared with `PermissionModeChip` for the same reason the options are: the
/// two controls are one control on two surfaces, and a fit that is amber in the
/// composer and grey in the launcher is two answers to one question.
Color permissionFitColour(ColorScheme scheme, PermissionModeFit fit) =>
    switch (fit) {
      PermissionModeFit.exact => scheme.onSurfaceVariant,
      PermissionModeFit.approximate => scheme.tertiary,
      PermissionModeFit.none => scheme.error,
    };
