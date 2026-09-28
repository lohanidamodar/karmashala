import 'package:flutter/material.dart';

import 'package:karmashala_ui/tokens.dart';
import 'settings_layout.dart';

/// Where a row's control goes once the row is too narrow to hold it beside its
/// label.
enum SettingsControlFit {
  /// Under the label at the row's full width: a dropdown, a field or a
  /// segmented control, which all read better (and stop squeezing) full width.
  stretch,

  /// Under the label at its own width, left-aligned: a button or a chip, which
  /// looks broken stretched across a pane.
  start,

  /// Never moves: beside the label at every width. A switch or a checkbox is
  /// narrow enough that the label wraps around it instead.
  trailing,
}

/// One setting in the page's shared shape: label (and small help text) left,
/// control right — dropping under the label once the row itself is narrower
/// than [SettingsLayout.rowStackBelow] (grown with the text scale). Settings
/// is a workbench tab, so "narrow" is a split pane as often as a small window.
///
/// Measures its own width with a `LayoutBuilder`: the rows sit in the page's
/// scroll view, never where intrinsics are asked for, and the row's width —
/// not the window's — is what decides whether a control still fits beside its
/// label, inside a card or an indented block too. Do not put one in an
/// `AlertDialog`'s content or a menu item.
class SettingsRow extends StatelessWidget {
  const SettingsRow({
    required this.label,
    required this.control,
    this.help,
    this.controlMaxWidth = 320,
    this.stackedFit,
    super.key,
  });

  final String label;

  /// One quiet sentence under the label; omit it for self-explanatory rows.
  final String? help;

  final Widget control;

  /// How wide the control may grow in the side-by-side layout. Dropdowns want
  /// ~320; a switch takes what it takes.
  final double controlMaxWidth;

  /// Where [control] goes on a narrow row, or null to tell from the control:
  /// switches, checkboxes and radios stay trailing, buttons and chips keep
  /// their own width, and anything else (fields, dropdowns, segmented
  /// buttons) takes the full width.
  final SettingsControlFit? stackedFit;

  /// Below this row width (at 1x text) the control drops under its label.
  static const stackBelow = SettingsLayout.rowStackBelow;

  SettingsControlFit get _fit =>
      stackedFit ??
      switch (control) {
        Switch() || Checkbox() || Radio() => SettingsControlFit.trailing,
        ButtonStyleButton() ||
        IconButton() ||
        Chip() ||
        Text() => SettingsControlFit.start,
        _ => SettingsControlFit.stretch,
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    final fit = _fit;
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
          final width = constraints.maxWidth;
          if (fit != SettingsControlFit.trailing &&
              SettingsLayout.rowStacks(width, scaler)) {
            return Column(
              crossAxisAlignment: fit == SettingsControlFit.stretch
                  ? CrossAxisAlignment.stretch
                  : CrossAxisAlignment.start,
              children: [
                labelBlock,
                const SizedBox(height: Insets.xs),
                control,
              ],
            );
          }
          // Side by side the label keeps a readable column: a wide control
          // cap still leaves it at least the rest of the row.
          final cap = width.isFinite
              ? controlMaxWidth.clamp(0.0, width * SettingsLayout.controlShare)
              : controlMaxWidth;
          return Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(child: labelBlock),
              const SizedBox(width: Insets.lg),
              ConstrainedBox(
                constraints: BoxConstraints(
                  // A switch is never capped: squeezing it would clip it.
                  maxWidth: fit == SettingsControlFit.trailing
                      ? controlMaxWidth
                      : cap,
                ),
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
/// way a `SwitchListTile` is. The switch stays beside its label at every
/// width; the label wraps around it on a narrow pane.
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
          stackedFit: SettingsControlFit.trailing,
          control: Switch(value: value, onChanged: onChanged),
        ),
      ),
    );
  }
}
