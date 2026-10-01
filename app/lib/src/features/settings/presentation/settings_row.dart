import 'package:agent_cli/usage.dart';
import 'package:flutter/material.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import '../../agents/presentation/usage_window_meter.dart';
import 'settings_layout.dart';
import 'settings_theme.dart';

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

/// The approved board's hairline over a row: every row, card and note on a
/// settings page starts with one, so a section reads as a flat list under its
/// label (board `.set`: `box-shadow: 0 -1px 0`), never as a box.
class SettingsRuled extends StatelessWidget {
  const SettingsRuled({required this.child, this.padding, super.key});

  final Widget child;

  /// Inside the rule; the board's 11 px above and below when null.
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) => Row(
    // A row at full width under a start-aligned column too, so the hairline
    // runs the page's width and not the content's — without measuring, so it
    // stays safe under intrinsics.
    children: [
      Expanded(
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border(
              top: BorderSide(color: SettingsStyles.rule(context)),
            ),
          ),
          child: Padding(
            padding:
                padding ??
                const EdgeInsets.symmetric(vertical: SettingsLayout.rowPadding),
            child: child,
          ),
        ),
      ),
    ],
  );
}

/// One setting in the page's shared shape (board `.set`): a hairline above,
/// label (and small help text) left, control right — dropping under the label
/// once the row itself is narrower than [SettingsLayout.rowStackBelow] (grown
/// with the text scale). Settings is a workbench tab, so "narrow" is a split
/// pane as often as a small window.
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
    this.helpWidget,
    this.leading,
    this.controlMaxWidth = 320,
    this.stackedFit,
    super.key,
  });

  final String label;

  /// One quiet sentence under the label; omit it for self-explanatory rows.
  final String? help;

  /// Under the label instead of [help], for a line that is more than one
  /// plain sentence: a version with an update flag, a status in its own tone.
  final Widget? helpWidget;

  /// Before the label: a status dot, an agent's glyph.
  final Widget? leading;

  final Widget control;

  /// How wide the control may grow in the side-by-side layout. Dropdowns want
  /// ~320; a switch takes what it takes.
  final double controlMaxWidth;

  /// Where [control] goes on a narrow row, or null to tell from the control:
  /// switches, checkboxes and radios stay trailing, buttons, chips and value
  /// pills keep their own width, and anything else (fields, dropdowns,
  /// segmented buttons) takes the full width.
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
        SettingsValue() ||
        Text() => SettingsControlFit.start,
        _ => SettingsControlFit.stretch,
      };

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    final fit = _fit;
    // The board's 30 × 17 toggle, not Material's 52 × 32 one.
    final control = this.control is Switch
        ? SettingsCompactSwitch(child: this.control)
        : this.control;
    final help = this.help;
    final helpWidget = this.helpWidget;
    Widget labelBlock = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: SettingsStyles.rowLabel(context)),
        if (helpWidget != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: DefaultTextStyle.merge(
              style: SettingsStyles.rowHelp(context),
              child: helpWidget,
            ),
          )
        else if (help != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(help, style: SettingsStyles.rowHelp(context)),
          ),
      ],
    );
    final leading = this.leading;
    if (leading != null) {
      labelBlock = Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2, right: Insets.sm),
            child: leading,
          ),
          Expanded(child: labelBlock),
        ],
      );
    }
    return SettingsRuled(
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
                const SizedBox(height: Insets.sm),
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
              const SizedBox(width: SettingsLayout.rowGap),
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

  /// Null disables the switch and the row.
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final onChanged = this.onChanged;
    return MergeSemantics(
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.sm),
        hoverColor: SurfaceTones.of(context).hover.withValues(alpha: 0.5),
        onTap: onChanged == null ? null : () => onChanged(!value),
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

/// A Material [Switch] drawn at the board's toggle size (30 × 17) — scaled, not
/// rebuilt, so it keeps the switch's semantics, keyboard and hit testing, and
/// a test that finds a `Switch` still finds this one. Its colours come from
/// [SettingsControlsTheme].
class SettingsCompactSwitch extends StatelessWidget {
  const SettingsCompactSwitch({required this.child, super.key});

  final Widget child;

  static const width = 30.0;
  static const height = 17.0;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    height: height,
    child: FittedBox(fit: BoxFit.contain, child: child),
  );
}

/// **A value on a row** (board `.val`): a 26 px pill on the `raised` tone
/// holding the current value, with a caret when tapping it opens a choice.
/// For a read-only value — a version, a chord, an account in force — it is
/// the same pill without the caret, so a fact and a choice sit in one column.
class SettingsValue extends StatelessWidget {
  const SettingsValue({
    required this.label,
    this.onTap,
    this.caret,
    this.mono = false,
    this.tooltip,
    this.semanticsLabel,
    super.key,
  });

  final String label;
  final VoidCallback? onTap;

  /// Whether to draw the caret; by default, when [onTap] is set.
  final bool? caret;

  /// The ledger hand, for a chord, a path or a version.
  final bool mono;
  final String? tooltip;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tones = SurfaceTones.of(context);
    final style = mono
        ? MonoStyles.label.copyWith(color: theme.colorScheme.onSurface)
        : SettingsStyles.control(context);
    final onTap = this.onTap;
    final pill = Container(
      height: SettingsLayout.controlHeight,
      padding: const EdgeInsets.symmetric(horizontal: Insets.md - 2),
      decoration: BoxDecoration(
        color: tones.raised,
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
          ),
          if (caret ?? onTap != null) ...[
            const SizedBox(width: Insets.xs + 2),
            Icon(
              AppIcons.caretDown,
              size: Chrome.iconSmall,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ],
        ],
      ),
    );
    Widget result = onTap == null
        ? pill
        : Material(
            type: MaterialType.transparency,
            child: InkWell(
              borderRadius: BorderRadius.circular(Radii.sm),
              hoverColor: tones.hover,
              onTap: onTap,
              child: pill,
            ),
          );
    final tooltip = this.tooltip;
    if (tooltip != null) result = Tooltip(message: tooltip, child: result);
    return Semantics(
      button: onTap != null,
      label: semanticsLabel,
      child: result,
    );
  }
}

/// **One usage window on a row** (board: the label left, a 160 × 5 bar and its
/// percentage right). Coloured by the one severity every usage surface uses —
/// green, then the warning tone from `kUsageWarningPercent` — never the
/// accent. A window nothing measured says so in words instead of drawing an
/// empty bar.
class SettingsUsageRow extends StatelessWidget {
  const SettingsUsageRow({
    required this.label,
    required this.percent,
    this.help,
    super.key,
  });

  final String label;

  /// 0–100 used, or null when the reading carries none for this window.
  final double? percent;
  final String? help;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tones = SurfaceTones.of(context);
    final percent = this.percent;
    final Widget meter;
    if (percent == null) {
      meter = Text(
        kUsageNoQuotaReported,
        style: SettingsStyles.rowHelp(context),
      );
    } else {
      final fill = usageSeverityColor(context, usageSeverityFor(percent));
      meter = Semantics(
        label: '$label: ${percent.round()}% used',
        child: ExcludeSemantics(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Container(
                  width: SettingsLayout.usageBarWidth,
                  height: SettingsLayout.usageBarHeight,
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: tones.pressed,
                    borderRadius: BorderRadius.circular(3),
                  ),
                  alignment: Alignment.centerLeft,
                  child: FractionallySizedBox(
                    // At least a sliver, so 0% still reads as measured.
                    widthFactor: percent.clamp(1, 100) / 100,
                    heightFactor: 1,
                    child: ColoredBox(color: fill),
                  ),
                ),
              ),
              const SizedBox(width: Insets.sm + 2),
              SizedBox(
                width: SettingsLayout.usagePercentWidth,
                child: Text(
                  '${percent.round()}%',
                  textAlign: TextAlign.right,
                  style: SettingsStyles.control(context)?.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                    color: theme.colorScheme.onSurface,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }
    return SettingsRow(
      label: label,
      help: help,
      stackedFit: SettingsControlFit.start,
      control: meter,
    );
  }
}

/// A sentence that belongs to a section but is not a setting: what the
/// section is for, why a list is empty. Drawn as a row with only its help
/// line, so it sits in the section's rhythm — hairline and all — instead of
/// floating between rows.
class SettingsNote extends StatelessWidget {
  const SettingsNote(this.text, {this.child, super.key});

  final String text;

  /// Something under the sentence: a notice, a list of commands.
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final child = this.child;
    return SettingsRuled(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(text, style: SettingsStyles.rowHelp(context)),
          if (child != null) ...[const SizedBox(height: Insets.sm), child],
        ],
      ),
    );
  }
}
