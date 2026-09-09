import 'package:flutter/material.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../../app/widgets/desktop_menu.dart';
import 'package:agent_cli/descriptors.dart';

/// A menu of the permission modes one agent really has, in that agent's own
/// words.
///
/// The composer's `PermissionModeChip` is this same control bound to a running
/// session. Both build their rows from [permissionAxisOptionsFor], so what is
/// offered — and what each mode is said to do — cannot differ between them.
///
/// Two properties carried over from the shared-enum design, both still doing
/// work:
///
/// * **A row the user cannot pick is shown, disabled, and says why.** What puts
///   a row there has changed: a mode the agent cannot express is no longer
///   possible, because every row *is* one of the agent's own modes. The live
///   case is an axis another axis has superseded — choose Codex's bypass and
///   its approval picker greys out, because that flag replaces it.
/// * **An agent whose modes have never been established says so**, in one
///   disabled row, rather than showing an empty menu or a set of guesses.
///
/// **Codex gets two pickers**, in one menu with a heading each. That is the
/// point of the change rather than an accident of it: a sandbox and an approval
/// policy are separate questions with separate answers, and the flattened cross
/// product would be both dishonest and longer (7 rows in two groups against 10
/// in one list).
class PermissionModePicker extends StatelessWidget {
  const PermissionModePicker({
    required this.descriptor,
    required this.selection,
    required this.onChanged,
    this.agentName,
    super.key,
  });

  final AgentDescriptor? descriptor;

  /// The selection in force, in this agent's vocabulary.
  final PermissionSelection selection;

  /// Called with the whole new selection, not just the changed axis, so the
  /// caller never has to merge one itself.
  final ValueChanged<PermissionSelection> onChanged;

  final String? agentName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final name = agentName ?? descriptor?.displayName ?? 'This agent';
    final support = descriptor?.launch.permission;
    final known = support != null && support.isKnown;
    final axes = permissionAxisOptionsFor(
      descriptor,
      selection: selection,
      agentName: name,
    );

    final dangerous = known && support.isDangerous(selection);
    // Colour carries meaning only: a bypass and an agent we cannot govern are
    // both things the user should notice, and nothing else is tinted.
    final foreground = dangerous || !known
        ? scheme.error
        : scheme.onSurfaceVariant;
    // Paired with the rung's familiar name, exactly as the composer chip is:
    // two controls drawing one selection must not name it two ways.
    final label = known
        ? describeSelectionFamiliarShort(support, selection)
        : 'Not established';

    return PopupMenuButton<PermissionAxisChoice>(
      tooltip: '',
      position: PopupMenuPosition.under,
      onSelected: (choice) => onChanged(
        PermissionSelection({
          ...support!.normalise(selection).values,
          choice.axisId: choice.valueId,
        }),
      ),
      itemBuilder: (context) => [
        if (!known)
          DesktopMenuDetailItem<PermissionAxisChoice>(
            value: const PermissionAxisChoice('', ''),
            enabled: false,
            label: 'No permission modes established',
            detail: unknownAgentReason(name),
          )
        else
          for (final axis in axes) ...[
            // Only when there is more than one: a heading over a single axis
            // labels the obvious and costs a row at the minimum window.
            if (axes.length > 1) DesktopMenuHeader(axis.label),
            for (final option in axis.options)
              DesktopMenuDetailItem<PermissionAxisChoice>(
                value: PermissionAxisChoice(axis.id, option.id),
                enabled: option.isSelectable,
                selected: option.id == axis.selectedId,
                label: option.pairedLabel,
                detail: option.summary,
              ),
            if (axis != axes.last) const DesktopMenuDivider(),
          ],
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
            Flexible(
              child: Text(
                label,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(color: foreground),
              ),
            ),
            Icon(AppIcons.caretDown, size: 11, color: foreground),
          ],
        ),
      ),
    );
  }
}

/// One menu row's answer: which axis, and which value on it.
///
/// A pair rather than a bare value id, because two axes may name values alike
/// and `PopupMenuButton` hands back only what the row carried. Public so a test
/// can name the menu row's type, the way `PermissionChoice` is.
@immutable
class PermissionAxisChoice {
  const PermissionAxisChoice(this.axisId, this.valueId);

  final String axisId;
  final String valueId;

  @override
  bool operator ==(Object other) =>
      other is PermissionAxisChoice &&
      other.axisId == axisId &&
      other.valueId == valueId;

  @override
  int get hashCode => Object.hash(axisId, valueId);
}

/// How a carried rung reaches the target, as a colour. Only the two worth
/// noticing are tinted; an exact carry is a fact, not a warning.
///
/// Shared with `PermissionModeChip` so the two controls are one control on two
/// surfaces, rather than a fit that is amber in the composer and grey in the
/// launcher.
Color permissionFitColour(ColorScheme scheme, PermissionModeFit fit) =>
    switch (fit) {
      PermissionModeFit.exact => scheme.onSurfaceVariant,
      PermissionModeFit.approximate => scheme.tertiary,
      PermissionModeFit.none => scheme.error,
    };

/// A short badge for the same fact.
String permissionFitLabel(PermissionModeFit fit) => switch (fit) {
  PermissionModeFit.exact => 'exact',
  PermissionModeFit.approximate => 'safer',
  PermissionModeFit.none => 'not enforced',
};

/// The rung a selection sits on, for a control that wants to say how permissive
/// something is without naming one CLI's mode.
PermissionRisk? riskOfSelection(
  AgentDescriptor? descriptor,
  PermissionSelection? selection,
) => descriptor?.launch.permission.riskOf(selection);
