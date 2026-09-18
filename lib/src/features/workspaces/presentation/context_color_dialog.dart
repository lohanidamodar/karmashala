import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../application/workspaces_controller.dart';
import '../domain/workspace.dart';

/// A grid of the context hues, and *None*. One tap picks and closes: a colour
/// is a glance, not a form.
class ContextColorDialog extends ConsumerWidget {
  const ContextColorDialog({required this.workspace, super.key});

  final Workspace workspace;

  static Future<void> show(BuildContext context, Workspace workspace) =>
      showDialog<void>(
        context: context,
        builder: (_) => ContextColorDialog(workspace: workspace),
      );

  /// A swatch's diameter — a thumb-sized target even under a pointer, because
  /// the grid is small and the whole point is telling the discs apart.
  static const swatch = 32.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ContextHue.tryParse(workspace.color);
    void pick(ContextHue? hue) {
      ref
          .read(workspacesControllerProvider.notifier)
          .setColor(workspace.id, hue?.name);
      Navigator.of(context).pop();
    }

    return AlertDialog(
      title: DesktopDialogTitle(
        icon: AppIcons.circleHalf,
        title: 'Colour',
        subtitle: 'For "${workspace.name}", on its header and its chip.',
      ),
      content: Wrap(
        spacing: Insets.sm,
        runSpacing: Insets.sm,
        children: [
          _Swatch(
            hue: null,
            selected: current == null,
            onTap: () => pick(null),
          ),
          for (final hue in ContextHue.values)
            _Swatch(hue: hue, selected: current == hue, onTap: () => pick(hue)),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.hue,
    required this.selected,
    required this.onTap,
  });

  /// Null is *None*: a hollow ring where the others are discs.
  final ContextHue? hue;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hue = this.hue;
    final label = hue?.label ?? 'None';
    final fill = hue?.of(theme.brightness);
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: Tooltip(
        message: label,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox.square(
            dimension: ContextColorDialog.swatch,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: fill,
                shape: BoxShape.circle,
                // The pick is said by a ring, so the one colour a swatch is
                // never has to make room for a mark inside it.
                border: Border.all(
                  color: selected ? scheme.primary : scheme.outlineVariant,
                  width: selected ? 2 : 1,
                ),
              ),
              child: fill == null
                  ? Icon(
                      AppIcons.prohibit,
                      size: Chrome.icon,
                      color: scheme.onSurfaceVariant,
                    )
                  : null,
            ),
          ),
        ),
      ),
    );
  }
}
