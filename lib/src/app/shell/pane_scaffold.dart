import 'package:flutter/material.dart';

import '../theme/app_icons.dart';
import '../theme/design_tokens.dart';

/// The close button every [PaneHeader] in this subtree wears, after whatever
/// actions the surface itself supplies.
///
/// It exists because the side panel holds two kinds of surface: six that let
/// the panel draw their header, and five that draw their own from their own
/// state. The panel used to give a close button only to the first six, so half
/// its surfaces could be dismissed from the header and half could not.
/// Hoisting the other five's actions into the panel would have made the panel
/// watch five features to add one button; handing the button *down* costs the
/// features nothing and keeps `drawsOwnHeader` meaning exactly what it says.
class PaneCloseAction extends InheritedWidget {
  const PaneCloseAction({
    required this.tooltip,
    required this.onClose,
    required super.child,
    super.key,
  });

  final String tooltip;
  final VoidCallback onClose;

  /// Null outside a container that offers one — a workbench pane closes from
  /// its tab, not from its header.
  static PaneCloseAction? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PaneCloseAction>();

  @override
  bool updateShouldNotify(PaneCloseAction oldWidget) =>
      tooltip != oldWidget.tooltip || onClose != oldWidget.onClose;
}

/// The header a shell pane wears: a [Chrome.tabStrip] row on
/// `surfaceContainerLow`, a leading glyph, the title in the chrome eyebrow, and
/// whatever actions the surface owns — then the hairline under it.
///
/// It is a widget because six surfaces need this shape and three of them had
/// drifted: no fixed height, no ground colour, mixed-case titles at two
/// different type roles. Switching between them in the same 360px column moved
/// the divider and changed the lettering, which reads as three different apps.
/// The hairline is part of the header rather than of whatever sits under it —
/// it was the one piece of the shape a site could silently forget.
class PaneHeader extends StatelessWidget {
  const PaneHeader({
    required this.icon,
    required this.title,
    this.actions = const [],
    this.focused = false,
    super.key,
  });

  /// The surface's own glyph, drawn at [Chrome.iconSmall].
  final IconData icon;

  /// Written in any case; drawn uppercase, like every other chrome eyebrow.
  final String title;

  /// Drawn after the title, in the same row. A widget that has to give way with
  /// the title — a branch name, a commit — belongs in a [Flexible] here.
  final List<Widget> actions;

  /// Whether the keyboard is in this pane. It shows in the ink of the glyph and
  /// the title alone: enough to answer "which pane am I typing into", quiet
  /// enough not to compete with the workbench.
  final bool focused;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final ink = focused ? scheme.onSurface : scheme.onSurfaceVariant;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: Chrome.tabStrip,
          color: scheme.surfaceContainerLow,
          padding: const EdgeInsets.only(left: Insets.md, right: 2),
          child: Row(
            children: [
              Icon(icon, size: Chrome.iconSmall, color: ink),
              const SizedBox(width: Insets.sm),
              // Expanded rather than a Spacer: the title is the only thing in
              // this row that can give way, and at the Explorer's own 200px
              // minimum the actions alone are wider than the pane.
              Expanded(
                child: Text(
                  title.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(color: ink),
                ),
              ),
              ...actions,
              // Last, so a surface's own actions keep their order and the way
              // out is always in the same corner.
              if (PaneCloseAction.maybeOf(context) case final close?)
                IconButton(
                  tooltip: close.tooltip,
                  icon: const Icon(AppIcons.x, size: Chrome.iconAction),
                  onPressed: close.onClose,
                ),
            ],
          ),
        ),
        const Divider(height: 1),
      ],
    );
  }
}

/// A consistent frame for a shell pane: a [PaneHeader] over a body.
///
/// Flat, not a card. The old frame gave every pane a rounded outline and a brass
/// accent rule, which read as three floating documents on a desk; a desktop
/// shell is one surface divided by hairlines, and the rounded corners cost real
/// pixels at the top of a pane that is mostly list.
class PaneScaffold extends StatelessWidget {
  const PaneScaffold({
    required this.title,
    required this.icon,
    required this.body,
    this.actions = const [],
    this.focused = false,
    super.key,
  });

  final String title;
  final IconData icon;
  final Widget body;
  final List<Widget> actions;
  final bool focused;

  @override
  Widget build(BuildContext context) {
    // A Material (not a plain DecoratedBox) so descendant ListTiles have a
    // valid background/ink ancestor to paint on.
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PaneHeader(
            icon: icon,
            title: title,
            actions: actions,
            focused: focused,
          ),
          Expanded(child: body),
        ],
      ),
    );
  }
}

/// Centered empty-state placeholder used inside panes.
///
/// The [icon] and [action] slots exist because their absence bred rivals: three
/// other empty states were written by hand purely to put a glyph above the
/// sentence, each at its own size, and one of them forgot to mute its text.
class PanePlaceholder extends StatelessWidget {
  const PanePlaceholder({
    required this.message,
    this.icon,
    this.iconColor,
    this.action,
    super.key,
  });

  final String message;

  /// The one picture on a surface with nothing on it, at [Chrome.iconHero].
  final IconData? icon;

  /// Only where the glyph itself means something — a green tick for "nothing is
  /// waiting". Otherwise it stays on the ramp with the text.
  final Color? iconColor;

  /// The way out of the empty state, when there is one.
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Insets.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon case final glyph?) ...[
              Icon(glyph, size: Chrome.iconHero, color: iconColor ?? muted),
              const SizedBox(height: Insets.sm),
            ],
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(color: muted),
            ),
            if (action case final action?) ...[
              const SizedBox(height: Insets.md),
              action,
            ],
          ],
        ),
      ),
    );
  }
}
