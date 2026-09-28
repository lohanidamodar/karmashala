import 'package:flutter/material.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

// **The window's menus, drawn as every other menu in the app.**
//
// The `+` New menu and the right-click menus are `PopupMenuItem`s built by
// `DesktopMenuItem` (karmashala_ui `menus.dart`): a 32px row, a 16px glyph,
// the label in `bodySmall`, the chord right-aligned in `labelSmall`. The
// Workspace / View / Tools menus need submenus and keyboard traversal, which
// only `MenuAnchor` gives — and Material's own `MenuItemButton` look (a 26px
// row, a checkbox widget, 1px dividers, Flutter's shortcut text in the label's
// style) made them "not look consistent" beside the rest (owner, 2026-09-28).
// These wrappers keep `MenuItemButton` / `SubmenuButton` for the behaviour and
// draw the row themselves, on `DesktopMenuItem`'s measurements.
//
// Nothing here may use a `LayoutBuilder`: a menu panel sizes itself by
// intrinsics, which a `LayoutBuilder` cannot answer.

/// `DesktopMenuItem`'s gutter and glyph gap (private there), restated so the
/// two kinds of menu line their glyphs and labels up at the same x.
const double _rowGutter = 10;
const double _glyphGap = 10;

/// The least room between a label and its chord. `MenuItemButton` already
/// puts its own label spacing before a trailing widget; this tops it up to
/// roughly `DesktopMenuItem`'s [Insets.xl].
const double _chordGap = Insets.sm;

/// The floating panel a menu or submenu opens: read from the popup menu theme,
/// so a `showMenu` popup and a `MenuAnchor` panel cannot drift apart.
MenuStyle shellMenuPanelStyle(BuildContext context) {
  final popup = Theme.of(context).popupMenuTheme;
  return MenuStyle(
    backgroundColor: WidgetStatePropertyAll(popup.color),
    surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
    elevation: WidgetStatePropertyAll(popup.elevation ?? Elevations.popup),
    padding: WidgetStatePropertyAll(
      popup.menuPadding ?? const EdgeInsets.symmetric(vertical: Insets.xs),
    ),
    shape: WidgetStatePropertyAll(
      switch (popup.shape) {
        final OutlinedBorder shape => shape,
        _ => RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.sm),
          side: BorderSide(color: SurfaceTones.of(context).floatingLine),
        ),
      },
    ),
    // The app's theme is compact; a panel's padding must not shrink under it.
    visualDensity: VisualDensity.standard,
  );
}

/// One row of a menu panel, on `DesktopMenuItem`'s measurements: square ink
/// (a popup row's hover runs edge to edge), the theme's hover wash, no
/// density adjustment — a compact density would take 8px off [Chrome.menuRow].
ButtonStyle shellMenuRowStyle(BuildContext context) {
  final theme = Theme.of(context);
  final scheme = theme.colorScheme;
  return ButtonStyle(
    minimumSize: const WidgetStatePropertyAll(Size(0, Chrome.menuRow)),
    padding: const WidgetStatePropertyAll(
      EdgeInsets.symmetric(horizontal: _rowGutter),
    ),
    visualDensity: VisualDensity.standard,
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    backgroundColor: const WidgetStatePropertyAll(Colors.transparent),
    overlayColor: WidgetStateProperty.resolveWith(
      (states) => states.contains(WidgetState.pressed)
          ? StateLayers.pressed(scheme)
          : states.contains(WidgetState.hovered) ||
                states.contains(WidgetState.focused)
          ? theme.hoverColor
          : Colors.transparent,
    ),
    foregroundColor: WidgetStateProperty.resolveWith(
      (states) => states.contains(WidgetState.disabled)
          ? scheme.onSurface.withValues(alpha: _disabledAlpha)
          : scheme.onSurface,
    ),
    iconColor: WidgetStatePropertyAll(scheme.onSurfaceVariant),
    iconSize: const WidgetStatePropertyAll(Chrome.icon),
    textStyle: WidgetStatePropertyAll(theme.textTheme.bodySmall),
    shape: const WidgetStatePropertyAll(RoundedRectangleBorder()),
  );
}

/// Material's disabled-content opacity, which a disabled popup row uses too.
const double _disabledAlpha = 0.38;

/// A menu row: a glyph, the label, and the chord right-aligned — the
/// `DesktopMenuItem` of a `MenuAnchor`. [checked] makes it a toggle: the
/// check takes the glyph's place while it is on, as `DesktopMenuItem`'s
/// `selected` does, so a toggle and a plain row keep their labels in line.
class ShellMenuItem extends StatelessWidget {
  const ShellMenuItem({
    required this.label,
    required this.icon,
    required this.onPressed,
    this.shortcut,
    this.checked,
    super.key,
  });

  final String label;
  final IconData icon;

  /// Null disables the row.
  final VoidCallback? onPressed;

  /// How the chord is written — `shellCommandLabel`'s answer, so the menu
  /// shows the key the user's keymap actually binds. A label only: a menu
  /// registers nothing it draws (`shellShortcutMap` does the binding).
  final String? shortcut;

  /// Non-null for a toggle; whether it is on.
  final bool? checked;

  @override
  Widget build(BuildContext context) {
    final on = checked ?? false;
    final row = MenuItemButton(
      style: shellMenuRowStyle(context),
      onPressed: onPressed,
      trailingIcon: shortcut == null ? null : _ChordLabel(shortcut!),
      child: ShellMenuRowLabel(
        icon: on ? AppIcons.check : icon,
        label: label,
        enabled: onPressed != null,
      ),
    );
    if (checked == null) return row;
    return Semantics(checked: on, child: row);
  }
}

/// A row in a show-or-hide list — `DesktopMenuCheckItem`'s shape: a check
/// slot, then the thing's own glyph and name. Several can be on at once, so a
/// checked row is not emphasised; the check alone says it. The menu stays
/// open, so a list of them can be run down in one visit.
class ShellMenuCheckItem extends StatelessWidget {
  const ShellMenuCheckItem({
    required this.label,
    required this.icon,
    required this.checked,
    required this.onChanged,
    super.key,
  });

  final String label;
  final IconData icon;
  final bool checked;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final enabled = onChanged != null;
    final color = enabled
        ? scheme.onSurface
        : scheme.onSurface.withValues(alpha: _disabledAlpha);
    return Semantics(
      checked: checked,
      child: MenuItemButton(
        style: shellMenuRowStyle(context),
        closeOnActivate: false,
        onPressed: enabled ? () => onChanged!(!checked) : null,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: Chrome.icon,
              child: checked
                  ? Icon(AppIcons.check, size: Chrome.icon, color: color)
                  : null,
            ),
            const SizedBox(width: _glyphGap),
            Icon(icon, size: Chrome.icon, color: scheme.onSurfaceVariant),
            const SizedBox(width: _glyphGap),
            Flexible(child: _Label(label, color: color)),
          ],
        ),
      ),
    );
  }
}

/// A row that opens a submenu: the glyph and label of a [ShellMenuItem], a
/// small caret where the chord would be, and a panel in the same style.
class ShellSubmenu extends StatelessWidget {
  const ShellSubmenu({
    required this.label,
    required this.icon,
    required this.menuChildren,
    super.key,
  });

  final String label;
  final IconData icon;
  final List<Widget> menuChildren;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return SubmenuButton(
      style: shellMenuRowStyle(context),
      menuStyle: shellMenuPanelStyle(context),
      // Material's is a 24px arrow: louder than the 16px glyph it sits across
      // from. The small caret is what the rest of the chrome points with.
      submenuIcon: WidgetStatePropertyAll(
        Icon(AppIcons.caretRight, size: Chrome.iconSmall, color: muted),
      ),
      menuChildren: menuChildren,
      child: ShellMenuRowLabel(icon: icon, label: label),
    );
  }
}

/// `DesktopMenuDivider`: the popup divider's 7px band, not a bare hairline.
class ShellMenuDivider extends StatelessWidget {
  const ShellMenuDivider({super.key});

  @override
  Widget build(BuildContext context) => const Divider(height: 7);
}

/// A section heading inside a menu — `DesktopMenuHeader`'s look. Not
/// focusable, so arrow keys pass straight over it.
class ShellMenuHeader extends StatelessWidget {
  const ShellMenuHeader(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      height: Chrome.menuRow,
      padding: const EdgeInsets.symmetric(horizontal: _rowGutter),
      alignment: AlignmentDirectional.centerStart,
      child: Text(
        label.toUpperCase(),
        maxLines: 1,
        style: theme.textTheme.labelSmall
            ?.merge(Chrome.groupLabel)
            .copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
    );
  }
}

/// A row's glyph and label, in the label's colour as `DesktopMenuItem` draws
/// them. Public so a test can find a row by its label's widget.
class ShellMenuRowLabel extends StatelessWidget {
  const ShellMenuRowLabel({
    required this.icon,
    required this.label,
    this.enabled = true,
    super.key,
  });

  final IconData icon;
  final String label;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = enabled
        ? scheme.onSurface
        : scheme.onSurface.withValues(alpha: _disabledAlpha);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: Chrome.icon, color: color),
        const SizedBox(width: _glyphGap),
        Flexible(child: _Label(label, color: color)),
      ],
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text, {required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Text(
    text,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: color),
  );
}

/// The chord at a row's right edge, in `DesktopMenuItem`'s shortcut style.
class _ChordLabel extends StatelessWidget {
  const _ChordLabel(this.chord);

  final String chord;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsetsDirectional.only(start: _chordGap),
    child: Text(
      chord,
      maxLines: 1,
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
        fontWeight: FontWeight.w400,
        letterSpacing: 0,
      ),
    ),
  );
}
