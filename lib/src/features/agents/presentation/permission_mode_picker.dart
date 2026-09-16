import 'package:flutter/material.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:agent_cli/descriptors.dart';

import 'picker_face.dart';

/// A menu of the permission modes one agent really has. Rows come from
/// [permissionAxisOptionsFor]; a superseded axis is shown but disabled.
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
    final name = agentName ?? descriptor?.displayName ?? 'This agent';
    final support = descriptor?.launch.permission;
    final known = support != null && support.isKnown;
    final axes = permissionAxisOptionsFor(
      descriptor,
      selection: selection,
      agentName: name,
    );

    final dangerous = known && support.isDangerous(selection);
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
      child: PickerFace(
        icon: !known
            ? AppIcons.warningCircle
            : dangerous
            ? AppIcons.warning
            : AppIcons.check,
        label: label,
        // Colour carries meaning only: a bypass and an agent we cannot govern
        // are both things the user should notice, and nothing else is tinted.
        alarming: dangerous || !known,
      ),
    );
  }
}

/// One menu row's answer: which axis, and which value on it. A pair, since two
/// axes may name values alike and `PopupMenuButton` returns only the row's.
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

/// How a carried rung reaches the target, as a colour; an exact carry is a
/// fact, not a warning. Shared with `PermissionModeChip` so the two agree.
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
