import 'package:flutter/material.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../../app/widgets/desktop_menu.dart';
import 'package:agent_cli/descriptors.dart';

/// One row of a model menu: a model to run on, or the row that names no model
/// at all.
///
/// A type of its own rather than a nullable `String` because `PopupMenuButton`
/// reads a null selection as a *dismissal* and never calls `onSelected` for it
/// — so the row that means "no model" written as a null value would have looked
/// right and done nothing.
///
/// It lives here rather than beside either control because both need it and
/// they must agree: the Settings picker's "let the agent choose" row and
/// `ModelChip`'s "follow the Settings default" row are the same null travelling
/// through two menus, and two wrappers would be two chances to reintroduce the
/// trap.
@immutable
class ModelChoice {
  const ModelChoice(this.modelId);

  /// Name no model here. On a session that reads as "follow the Settings
  /// default"; in Settings it reads as "let the agent choose" — no `--model`
  /// passed at all. One constant, because it is one value: the absence of a
  /// model, whoever is being asked.
  static const followDefault = ModelChoice(null);

  final String? modelId;

  @override
  bool operator ==(Object other) =>
      other is ModelChoice && other.modelId == modelId;

  @override
  int get hashCode => modelId.hashCode;
}

/// A menu of the models one agent can be put on, with "let the agent choose"
/// as its first row.
///
/// `PermissionModePicker`'s twin, and the same control as `ModelChip`'s menu on
/// a different surface: both build their rows from [modelOptionsFor], so what
/// is offered — and what each model is said to do to *this* agent — cannot
/// differ between Settings and a running session. This one is handed its
/// options and its selection because it describes an agent's default rather
/// than a session, and there is no session to read.
///
/// The chip's rules hold here unchanged:
///
/// * **Only models the descriptor can express are selectable.** The rest are
///   listed, disabled, and say why — an agent that takes no model flag is the
///   one this surface has to be honest about, because a default nobody can
///   pass is a setting that lies every time it is read.
/// * **Naming no model is a row, not an empty selection.** It is first, it is
///   always selectable, and it is the shipped default.
class ModelPicker extends StatelessWidget {
  const ModelPicker({
    required this.options,
    required this.selected,
    required this.onChanged,
    super.key,
  });

  /// Every model with how it maps onto the agent — [modelOptionsFor]'s answer
  /// for the agent this picker is for.
  final List<AgentModelOption> options;

  /// The model chosen, or null for "let the agent choose".
  final String? selected;

  final ValueChanged<ModelChoice> onChanged;

  /// The row the current selection draws, or null when nothing is selected.
  AgentModelOption? get _current =>
      options.where((o) => o.model.id == selected).firstOrNull;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final current = _current;
    // Colour carries meaning only: a default this agent can never be told is
    // the one state worth noticing, and nothing else is tinted.
    final alarming = current != null && !current.isSelectable;
    final foreground = alarming ? scheme.error : scheme.onSurfaceVariant;
    final qualifier = current?.fitLabel;

    return PopupMenuButton<ModelChoice>(
      tooltip: '',
      position: PopupMenuPosition.under,
      onSelected: onChanged,
      itemBuilder: (context) => [
        // First, and its own row: naming no model is where every agent starts
        // and the only way back from a pick.
        DesktopMenuDetailItem<ModelChoice>(
          value: ModelChoice.followDefault,
          selected: selected == null,
          label: 'Let the agent choose',
          detail:
              'No model flag is passed, so the agent starts on whatever it is '
              'configured to use.',
        ),
        const DesktopMenuDivider(),
        for (final option in options)
          DesktopMenuDetailItem<ModelChoice>(
            value: ModelChoice(option.model.id),
            enabled: option.isSelectable,
            selected: option.model.id == selected,
            label: option.model.label,
            badge: option.fitLabel,
            badgeColor: option.isSelectable
                ? scheme.onSurfaceVariant
                : scheme.error,
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
            Icon(
              alarming ? AppIcons.warningCircle : AppIcons.robot,
              size: Chrome.iconSmall,
              color: foreground,
            ),
            const SizedBox(width: Insets.xs),
            Flexible(
              child: Text(
                current?.model.label ?? selected ?? 'Let the agent choose',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(color: foreground),
              ),
            ),
            // The fit is on the face of the control, not only in the menu: a
            // default the CLI will never be told has to look different from one
            // it will.
            if (qualifier != null) ...[
              const SizedBox(width: Insets.xs),
              Text(
                '· $qualifier',
                style: theme.textTheme.labelSmall?.copyWith(color: foreground),
              ),
            ],
            Icon(AppIcons.caretDown, size: 11, color: foreground),
          ],
        ),
      ),
    );
  }
}

/// Why [descriptor]'s model cannot be set at all, or null when it can.
///
/// The picker says this per row; a settings card has to say it once, above the
/// control, or the only place that honesty lives is behind a click. Read off
/// the same [modelOptionsFor] rows the menu draws, so the two cannot word it
/// differently.
String? modelNotSettableReason(AgentDescriptor? descriptor) {
  if (descriptor == null || descriptor.launch.model.isSupported) return null;
  return modelOptionsFor(descriptor)
      .where((o) => o.fit == AgentModelFit.notTellable)
      .firstOrNull
      ?.summary;
}
