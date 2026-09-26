import 'package:flutter/material.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:karmashala_ui/tokens.dart';

/// What an item's colour says. Only state is coloured; the accent is never
/// used, because nothing on this bar is a selection.
enum StatusBarTone { neutral, attention, failure }

/// One item on the status bar: a glyph, an optional label, and a tooltip that
/// says what it is and what clicking it does. A button only when [onPressed]
/// is given — a count with nowhere to go is not a focus stop.
class StatusBarItem extends StatefulWidget {
  const StatusBarItem({
    required this.tooltip,
    this.icon,
    this.glyph,
    this.label,
    this.richTooltip,
    this.trailing,
    this.onPressed,
    this.tone = StatusBarTone.neutral,
    this.flexible = false,
    this.enabled = true,
    super.key,
  }) : assert(icon != null || glyph != null);

  /// Builds of any item, counted so a cost test can prove what a change reaches.
  /// Read through `ShellStatusBar.debugItemBuildCount`.
  static int debugBuildCount = 0;

  final IconData? icon;

  /// Drawn instead of [icon] — a status glyph that animates, say.
  final Widget? glyph;

  /// Null for a glyph-only item; its words are then [tooltip]'s alone.
  final String? label;

  /// Plain words, and the semantics name when there is no [label].
  final String tooltip;

  /// Shown instead of [tooltip] where part of it wants its own style — a path.
  final InlineSpan? richTooltip;

  /// Small facts after the label, such as a branch's dirty count.
  final Widget? trailing;

  final VoidCallback? onPressed;
  final StatusBarTone tone;

  /// Whether the label ends rather than pushes its neighbours off the bar.
  final bool flexible;

  /// False draws the item muted: it describes something that cannot happen now.
  final bool enabled;

  @override
  State<StatusBarItem> createState() => _StatusBarItemState();
}

class _StatusBarItemState extends State<StatusBarItem> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    StatusBarItem.debugBuildCount++;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final semantic = SemanticColors.of(context);
    final colour = !widget.enabled
        ? scheme.outline
        : switch (widget.tone) {
            StatusBarTone.neutral => scheme.onSurfaceVariant,
            StatusBarTone.attention => semantic.attention,
            StatusBarTone.failure => semantic.failure,
          };
    final label = widget.label;
    final trailing = widget.trailing;

    Widget text(String value) => Text(
      value,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      softWrap: false,
      style: TextStyle(
        color: colour,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );

    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: Insets.sm),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          widget.glyph ??
              Icon(widget.icon, size: Chrome.iconSmall, color: colour),
          if (label != null) ...[
            const SizedBox(width: Insets.xs),
            if (widget.flexible) Flexible(child: text(label)) else text(label),
          ],
          if (trailing != null) ...[
            const SizedBox(width: Insets.xs),
            IconTheme.merge(
              data: IconThemeData(color: colour, size: Chrome.iconSmall),
              child: DefaultTextStyle.merge(
                style: TextStyle(color: colour),
                child: trailing,
              ),
            ),
          ],
        ],
      ),
    );

    final onPressed = widget.onPressed;
    final Widget body;
    if (onPressed == null) {
      body = Semantics(
        container: true,
        // The sentence, not the word on the bar: "Checkpoints" alone would
        // name the rail button that opens it, not this toggle.
        label: widget.tooltip,
        excludeSemantics: true,
        child: content,
      );
    } else {
      body = Semantics(
        button: true,
        // The sentence, not the word on the bar: "Checkpoints" alone would
        // name the rail button that opens it, not this toggle.
        label: widget.tooltip,
        excludeSemantics: true,
        // Excluding the InkWell's semantics drops its tap; give it back.
        onTap: onPressed,
        child: InkWell(
          onTap: onPressed,
          onFocusChange: (value) => setState(() => _focused = value),
          hoverColor: StateLayers.hover(scheme),
          highlightColor: StateLayers.pressed(scheme),
          focusColor: Colors.transparent,
          splashFactory: NoSplash.splashFactory,
          hoverDuration: Motion.instant,
          child: DecoratedBox(
            position: DecorationPosition.foreground,
            decoration: BoxDecoration(
              border: _focused
                  ? Border.all(
                      color: StateLayers.focusRing(scheme),
                      width: StateLayers.focusRingWidth,
                    )
                  : null,
            ),
            child: content,
          ),
        ),
      );
    }
    return Tooltip(
      message: widget.richTooltip == null ? widget.tooltip : null,
      richMessage: widget.richTooltip,
      child: SizedBox(
        height: double.infinity,
        // Width factor 1: a flexible item is as wide as its words, not its share.
        child: Center(widthFactor: 1, child: body),
      ),
    );
  }
}

/// Items that belong together, drawn with no gap between them: each item's own
/// padding is the spacing.
class StatusBarGroup extends StatelessWidget {
  const StatusBarGroup({required this.children, super.key});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) =>
      Row(mainAxisSize: MainAxisSize.min, children: children);
}

/// The rule between two groups: a short hairline, not a text dot.
class StatusBarDivider extends StatelessWidget {
  const StatusBarDivider({super.key});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: Insets.xs),
    child: SizedBox(
      width: 1,
      height: Chrome.iconSmall,
      child: ColoredBox(color: Theme.of(context).colorScheme.outlineVariant),
    ),
  );
}

/// One row of the overflow menu: what an item would have said on the bar, and
/// the same action.
@immutable
class StatusBarOverflowEntry {
  const StatusBarOverflowEntry({
    required this.icon,
    required this.label,
    this.onPressed,
  });

  final IconData icon;
  final String label;

  /// Null lists the fact without offering anything to do with it.
  final VoidCallback? onPressed;
}

/// The "…" that holds the items the bar has no room for. [entries] is asked
/// when the menu opens, so this button watches nothing and never redraws for
/// a value it is not showing.
class StatusBarOverflow extends StatelessWidget {
  const StatusBarOverflow({required this.entries, super.key});

  final List<StatusBarOverflowEntry> Function() entries;

  Future<void> _open(BuildContext context) async {
    final listed = entries();
    if (listed.isEmpty) return;
    final picked = await showDesktopMenuUnder<int>(context, [
      for (final (index, entry) in listed.indexed)
        DesktopMenuItem<int>(
          value: index,
          icon: entry.icon,
          label: entry.label,
          enabled: entry.onPressed != null,
        ),
    ]);
    if (picked == null) return;
    listed[picked].onPressed?.call();
  }

  @override
  Widget build(BuildContext context) => Builder(
    builder: (context) => StatusBarItem(
      icon: AppIcons.dotsThree,
      tooltip: 'More status — click to show what the bar has no room for',
      onPressed: () => _open(context),
    ),
  );
}
