import 'package:flutter/material.dart';

import 'package:karmashala_ui/tokens.dart';

/// One setting in the page's shared shape: label (and small help text) left,
/// control right — dropping under the label when the row is too narrow.
class SettingsRow extends StatelessWidget {
  const SettingsRow({
    required this.label,
    required this.control,
    this.help,
    this.controlMaxWidth = 320,
    super.key,
  });

  final String label;

  /// One quiet sentence under the label; omit it for self-explanatory rows.
  final String? help;

  final Widget control;

  /// How wide the control may grow in the side-by-side layout. Dropdowns want
  /// ~320; a switch takes what it takes.
  final double controlMaxWidth;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final labelBlock = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: theme.textTheme.bodyMedium),
        if (help != null)
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Text(help!, style: theme.textTheme.bodySmall),
          ),
      ],
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Insets.xs + 2),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 440) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                labelBlock,
                const SizedBox(height: Insets.xs),
                control,
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(child: labelBlock),
              const SizedBox(width: Insets.lg),
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: controlMaxWidth),
                child: control,
              ),
            ],
          );
        },
      ),
    );
  }
}

/// A boolean setting in the shared row shape, with the whole row tappable the
/// way a `SwitchListTile` is.
class SettingsSwitchRow extends StatelessWidget {
  const SettingsSwitchRow({
    required this.label,
    required this.value,
    required this.onChanged,
    this.help,
    super.key,
  });

  final String label;
  final String? help;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return MergeSemantics(
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.sm),
        onTap: () => onChanged(!value),
        child: SettingsRow(
          label: label,
          help: help,
          control: Switch(value: value, onChanged: onChanged),
        ),
      ),
    );
  }
}
