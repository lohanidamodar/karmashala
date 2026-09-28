import 'package:flutter/material.dart';

import 'package:karmashala_ui/tokens.dart';
import 'settings_layout.dart';

/// **The approved settings board's type and tone** (N5), read from the theme
/// so light, dark and every accent follow. One place, so a section in another
/// feature draws its label, help and controls in the same hand as the rows
/// here instead of guessing at a `textTheme` role.
abstract final class SettingsStyles {
  /// A row's label (board `.t1`: 13, medium).
  static TextStyle? rowLabel(BuildContext context) =>
      Theme.of(context).textTheme.bodyMedium?.copyWith(
        fontSize: 13,
        fontWeight: FontWeight.w500,
        height: 1.35,
      );

  /// The quiet sentence under a label (board `.t2`: 12 on a 17 line, muted).
  static TextStyle? rowHelp(BuildContext context) {
    final theme = Theme.of(context);
    return theme.textTheme.bodySmall?.copyWith(
      fontSize: 12,
      height: 17 / 12,
      color: theme.colorScheme.onSurfaceVariant,
    );
  }

  /// A section's label (board `.sec`: 11, semibold, tracked, uppercase, dim).
  /// The caller writes it uppercase; the catalogue's `heading` already is.
  static TextStyle? sectionLabel(BuildContext context) {
    final theme = Theme.of(context);
    return theme.textTheme.labelSmall
        ?.merge(Chrome.groupLabel)
        .copyWith(letterSpacing: 0.55, color: theme.colorScheme.outline);
  }

  /// Text on a control: a value pill, a button (board: 12.5).
  static TextStyle? control(BuildContext context) => Theme.of(
    context,
  ).textTheme.bodyMedium?.copyWith(fontSize: 12.5, height: 1.2);

  /// The page's title (board: 19, semibold) — a step down on a narrow page.
  static TextStyle? pageTitle(BuildContext context, {required bool narrow}) =>
      Theme.of(context).textTheme.titleLarge?.copyWith(
        fontSize: narrow ? 16 : 19,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.2,
      );

  /// The page's one-line blurb under its title (board: 12.5, muted).
  static TextStyle? pageBlurb(BuildContext context) {
    final theme = Theme.of(context);
    return theme.textTheme.bodySmall?.copyWith(
      fontSize: 12.5,
      height: 18 / 12.5,
      color: theme.colorScheme.onSurfaceVariant,
    );
  }

  /// The hairline over each row (board `.set`: a 1 px shadow one step above
  /// the page's `term` surface). The `raised` step: faint in both themes, and
  /// drawn whatever the region separation is, because it separates rows, not
  /// regions.
  static Color rule(BuildContext context) => SurfaceTones.of(context).raised;
}

/// **The board's controls, for everything under a settings page**: a 26 px
/// value pill on the `raised` tone with no outline, a 26 px button on the
/// `selected` tone, a 30 × 17 switch in the accent. Applied once around the
/// page, so every section — including the ones other features own, which
/// build stock `DropdownButtonFormField`s, `OutlinedButton`s and `Switch`es —
/// draws the board's controls without knowing it is on one.
///
/// Themes are captured into dialogs and menus opened from the page too; that
/// is deliberate: a dialog opened from a row keeps the row's controls.
class SettingsControlsTheme extends StatelessWidget {
  const SettingsControlsTheme({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tones = SurfaceTones.of(context);
    final controlText = SettingsStyles.control(context);
    const shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.all(Radius.circular(Radii.sm)),
    );
    const minSize = Size(0, SettingsLayout.controlHeight);
    const padding = EdgeInsets.symmetric(horizontal: Insets.md - 2);
    OutlineInputBorder border(Color color, [double width = 1]) =>
        OutlineInputBorder(
          borderRadius: BorderRadius.circular(Radii.sm),
          borderSide: color == Colors.transparent
              ? BorderSide.none
              : BorderSide(color: color, width: width),
        );
    // A button on the board is a filled `s2` chip, not an outline: quiet until
    // it is the row's one action.
    final quietButton = ButtonStyle(
      minimumSize: const WidgetStatePropertyAll(minSize),
      padding: const WidgetStatePropertyAll(padding),
      shape: const WidgetStatePropertyAll(shape),
      textStyle: WidgetStatePropertyAll(controlText),
      iconSize: const WidgetStatePropertyAll(Chrome.iconSmall),
      visualDensity: VisualDensity.compact,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      side: const WidgetStatePropertyAll(BorderSide.none),
      foregroundColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.disabled)
            ? scheme.onSurface.withValues(alpha: 0.38)
            : scheme.onSurface,
      ),
      backgroundColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.disabled)
            ? tones.raised
            : states.contains(WidgetState.hovered)
            ? tones.pressed
            : tones.selected,
      ),
    );
    return Theme(
      data: theme.copyWith(
        // DropdownButtonFormField draws its value in titleMedium (16px) when
        // given no style; on a settings page that is the control text, so
        // every dropdown matches the board's 26px fields. Nothing on these
        // pages uses titleMedium otherwise.
        textTheme: theme.textTheme.copyWith(titleMedium: controlText),
        inputDecorationTheme: theme.inputDecorationTheme.copyWith(
          isDense: true,
          filled: true,
          fillColor: tones.raised,
          hoverColor: tones.hover,
          border: border(Colors.transparent),
          enabledBorder: border(Colors.transparent),
          disabledBorder: border(Colors.transparent),
          focusedBorder: border(scheme.primary),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: Insets.md - 2,
            vertical: Insets.xs + 2,
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(style: quietButton),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            minimumSize: minSize,
            padding: padding,
            shape: shape,
            textStyle: controlText,
            iconSize: Chrome.iconSmall,
            visualDensity: VisualDensity.compact,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            minimumSize: minSize,
            padding: padding,
            shape: shape,
            textStyle: controlText,
            iconSize: Chrome.iconSmall,
            visualDensity: VisualDensity.compact,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ),
        segmentedButtonTheme: SegmentedButtonThemeData(
          style: ButtonStyle(
            visualDensity: VisualDensity.compact,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            minimumSize: const WidgetStatePropertyAll(minSize),
            textStyle: WidgetStatePropertyAll(controlText),
            iconSize: const WidgetStatePropertyAll(Chrome.iconSmall),
            side: const WidgetStatePropertyAll(BorderSide.none),
            shape: const WidgetStatePropertyAll(shape),
            backgroundColor: WidgetStateProperty.resolveWith(
              (states) => states.contains(WidgetState.selected)
                  ? tones.pressed
                  : tones.raised,
            ),
          ),
        ),
        // The board's toggle: an `s3` track that fills with the accent, and a
        // thumb that is the same size on or off. The icon property is what
        // keeps Material 3 from shrinking the off thumb.
        switchTheme: SwitchThemeData(
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
          trackColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? scheme.primary
                : tones.pressed,
          ),
          thumbColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? tones.background
                : scheme.onSurfaceVariant,
          ),
          thumbIcon: const WidgetStatePropertyAll(Icon(null)),
        ),
        // The board has no cards. A shared list entry that is a `Card` (the
        // kit's `ItemCard`: a variable, a snippet, an automation) is drawn
        // flat on the page under a row's hairline instead of as a box.
        cardTheme: CardThemeData(
          color: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          shadowColor: Colors.transparent,
          elevation: 0,
          margin: EdgeInsets.zero,
          shape: Border(
            top: BorderSide(color: SettingsStyles.rule(context)),
          ),
        ),
      ),
      child: child,
    );
  }
}
