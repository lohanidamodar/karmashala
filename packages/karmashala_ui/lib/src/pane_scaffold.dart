import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'app_icons.dart';
import 'design_tokens.dart';
import 'eyebrow_label.dart';

/// The close button every [PaneHeader] in this subtree wears. Handed *down*, so
/// a surface that draws its own header still gets one.
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

/// The header a shell pane wears — a [Chrome.tabStripOf] row, a glyph, the
/// title, the surface's own actions, and the hairline a site could otherwise
/// forget.
class PaneHeader extends StatelessWidget {
  const PaneHeader({
    required this.title,
    this.icon,
    this.actions = const [],
    this.focused = false,
    super.key,
  });

  /// The surface's own glyph at [Chrome.iconSmall], or null where it would only
  /// repeat one already on screen — the Explorer's is its title-bar toggle's.
  final IconData? icon;

  /// Written in any case; drawn uppercase, like every other chrome eyebrow.
  final String title;

  /// Drawn after the title, in the same row. A widget that has to give way with
  /// the title — a branch name, a commit — belongs in a [Flexible] here.
  final List<Widget> actions;

  /// Whether the keyboard is in this pane. It shows in the ink of the glyph and
  /// the title alone: enough to answer "which pane am I typing into".
  final bool focused;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final ink = focused ? scheme.onSurface : scheme.onSurfaceVariant;
    // A thumb's header is as tall as its close button's target, or the button
    // is squeezed to the row and a 30px target is a miss.
    final height = UiDensity.of(context).isTouch
        ? math.max(Chrome.tabStripOf(context), Touch.target)
        : Chrome.tabStripOf(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: height,
          color: scheme.surfaceContainerLow,
          padding: const EdgeInsets.only(left: Insets.md, right: 2),
          child: Row(
            children: [
              if (icon case final glyph?) ...[
                Icon(glyph, size: Chrome.iconSmall, color: ink),
                const SizedBox(width: Insets.sm),
              ],
              // Expanded rather than a Spacer: the title is the only thing in
              // this row that can give way, and at 200px the actions are wider.
              Expanded(child: EyebrowLabel(title, maxLines: 1, color: ink)),
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

/// The strip under a [PaneHeader] for a level inside the pane — a list's count,
/// or a back button and the item's title — with the surface's own [trailing]
/// actions and a hairline. Never a close button: the header above owns that.
class PaneSubToolbar extends StatelessWidget {
  const PaneSubToolbar({
    required this.title,
    this.leading,
    this.trailing,
    super.key,
  });

  final String title;

  /// Before the title, typically a back button. Null insets the title instead.
  final Widget? leading;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: Chrome.tabStripOf(context),
          child: Row(
            children: [
              leading ?? const SizedBox(width: Insets.md),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
              ?trailing,
              const SizedBox(width: Insets.xs),
            ],
          ),
        ),
        const Divider(height: 1),
      ],
    );
  }
}

/// A consistent frame for a shell pane: a [PaneHeader] over a body. Flat, not a
/// card — a desktop shell is one surface divided by hairlines.
class PaneScaffold extends StatelessWidget {
  const PaneScaffold({
    required this.title,
    required this.body,
    this.icon,
    this.actions = const [],
    this.focused = false,
    super.key,
  });

  final String title;

  /// Optional, and for the reason [PaneHeader.icon] gives.
  final IconData? icon;
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

/// Centered empty-state placeholder used inside panes. The [icon] and [action]
/// slots exist because their absence bred three hand-written rivals.
class PanePlaceholder extends StatelessWidget {
  const PanePlaceholder({
    required this.message,
    this.icon,
    this.iconColor,
    this.action,
    this.fillHeight = true,
    super.key,
  }) : inline = false;

  /// The same glyph and the same muted voice as one line *above* content: a
  /// pane with nothing connected that still has a list to offer. The glyph
  /// sits beside the sentence at [Chrome.icon], and the sentence starts a
  /// column rather than being centred over one.
  const PanePlaceholder.inline({
    required this.message,
    this.icon,
    this.iconColor,
    super.key,
  }) : action = null,
       fillHeight = false,
       inline = true;

  final String message;

  /// Whether this is the one-line form; see [PanePlaceholder.inline].
  final bool inline;

  /// The one picture on a surface with nothing on it, at [Chrome.iconHero].
  final IconData? icon;

  /// Only where the glyph itself means something — a green tick for "nothing is
  /// waiting". Otherwise it stays on the ramp with the text.
  final Color? iconColor;

  /// The way out of the empty state, when there is one.
  final Widget? action;

  /// False sizes it to its content instead of filling the height it is given —
  /// in a dialog, whose body would otherwise stretch to the window.
  final bool fillHeight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    if (inline) {
      return Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Insets.md,
          vertical: Insets.sm,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (icon case final glyph?) ...[
              Icon(glyph, size: Chrome.icon, color: iconColor ?? muted),
              const SizedBox(width: Insets.sm),
            ],
            Expanded(
              child: Text(
                message,
                style: theme.textTheme.bodySmall?.copyWith(color: muted),
              ),
            ),
          ],
        ),
      );
    }
    final content = Center(
      heightFactor: fillHeight ? null : 1,
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
    if (!fillHeight) return content;
    // Centred while it fits, scrollable once it does not: a 240px side panel at
    // 1.3x text is shorter than the message, and the action is the way out.
    return LayoutBuilder(
      builder: (context, constraints) {
        if (!constraints.hasBoundedHeight) return content;
        return SingleChildScrollView(
          primary: false,
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: content,
          ),
        );
      },
    );
  }
}
