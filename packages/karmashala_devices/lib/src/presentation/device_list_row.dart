import 'package:flutter/material.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/rows.dart';
import 'package:karmashala_ui/tokens.dart';

/// The one column the device list is drawn in. Every heading, name and option
/// starts at [inset]; every action's ink ends [inset] short of the far side.
///
/// Before, emulators were rows with a word floating after the name, simulators
/// a picker beside a filled button, one option a switch and the other a tick,
/// over four different left edges.
class DeviceListMetrics {
  const DeviceListMetrics._();

  /// From the pane's side to where text starts and where an action's ink ends —
  /// the log strip's and the recording banner's inset.
  static const inset = Insets.md;

  /// From the pane's side to a row's hover fill.
  static const fillInset = Insets.xs;

  /// Between one section and the heading of the next.
  static const sectionGap = Insets.md;

  /// A pointer-sized switch. Material's 52×32 is a thumb's.
  static const switchWidth = 32.0;
  static const switchHeight = 20.0;

  /// The least a name keeps, at 1x text, before a short fact beside it goes
  /// under it instead.
  static const nameFloor = 176.0;

  /// The widest the list gets: a name and its actions, not a line of prose.
  static const maxWidth = 460.0;

  /// The margin a glyph keeps inside its button's square, which is how far the
  /// square may hang past [inset] for the glyph itself to end on it.
  static double glyphMargin(UiDensity density) =>
      (ExplorerRow.slotOf(density) - ExplorerRow.glyphOf(density)) / 2;
}

/// One device, emulator or simulator in the list: its name, a fact about it,
/// and what can be done to it in fixed slots at the right — the Explorer's row
/// model. The name takes whatever the actions leave.
class DeviceRow extends StatefulWidget {
  const DeviceRow({
    required this.title,
    this.meta,
    this.subtitle,
    this.actions = const [],
    super.key,
  });

  final String title;

  /// A short fact — `iOS 26.5` — beside the name while the name keeps
  /// [DeviceListMetrics.nameFloor], under it otherwise.
  final String? meta;

  /// A sentence about the device's state, always under the name.
  final String? subtitle;

  /// [DeviceRowAction]s, leftmost first. Each is one slot wide.
  final List<Widget> actions;

  @override
  State<DeviceRow> createState() => _DeviceRowState();
}

class _DeviceRowState extends State<DeviceRow> {
  bool _hovered = false;

  static const _radius = BorderRadius.all(Radius.circular(Radii.sm));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final density = UiDensity.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    final muted = density.muted(theme);
    final meta = widget.meta;
    final actions = widget.actions;

    const left = DeviceListMetrics.inset - DeviceListMetrics.fillInset;
    // A glyph's own margin stands in for part of the inset, so the glyph —
    // not its square — ends where a switch does.
    final right = actions.isEmpty
        ? left
        : left - DeviceListMetrics.glyphMargin(density);
    final taken =
        left +
        right +
        (actions.isEmpty
            ? 0
            : Insets.xs + ExplorerRow.slotOf(density) * actions.length);

    final content = LayoutBuilder(
      builder: (context, constraints) {
        final metaBeside =
            meta != null &&
            constraints.maxWidth - taken >=
                WidthClass.scaleBreakpoint(DeviceListMetrics.nameFloor, scaler);
        // A row of two lines keeps the Explorer's two-line gutter, or a column
        // of them reads as one paragraph.
        final twoLines =
            widget.subtitle != null || (meta != null && !metaBeside);
        final gutter = twoLines ? Insets.xs : Insets.hair;
        final name = Text(
          widget.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: density.rowTitle(theme),
        );
        return Padding(
          padding: EdgeInsets.fromLTRB(left, gutter, right, gutter),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (metaBeside)
                      Row(
                        children: [
                          Flexible(child: name),
                          const SizedBox(width: Insets.sm),
                          Text(
                            meta,
                            maxLines: 1,
                            softWrap: false,
                            style: muted,
                          ),
                        ],
                      )
                    else
                      name,
                    if (meta != null && !metaBeside)
                      Text(
                        meta,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: muted,
                      ),
                    if (widget.subtitle case final line?)
                      Text(
                        line,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: muted,
                      ),
                  ],
                ),
              ),
              if (actions.isNotEmpty) const SizedBox(width: Insets.xs),
              ...actions,
            ],
          ),
        );
      },
    );

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: DeviceListMetrics.fillInset,
      ),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: _hovered ? StateLayers.hover(theme.colorScheme) : null,
            borderRadius: _radius,
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: density.isTouch ? Touch.target : Chrome.row,
            ),
            child: content,
          ),
        ),
      ),
    );
  }
}

/// One thing to do to a device, as a glyph in a fixed slot — named by its
/// tooltip, which is also what a screen reader hears. A spinner takes the
/// glyph's place while it runs: with a headless emulator nothing else moves.
class DeviceRowAction extends StatelessWidget {
  const DeviceRowAction({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.busy = false,
    this.primary = false,
    super.key,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool busy;

  /// The row's reason for being there — Start. Drawn in the accent.
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final slot = ExplorerRow.slotOf(UiDensity.of(context));
    if (busy) {
      return SizedBox.square(
        dimension: slot,
        child: Center(
          child: InlineSpinner(
            size: InlineSpinnerSize.medium,
            semanticsLabel: tooltip,
          ),
        ),
      );
    }
    return ExplorerRowAction(
      tooltip: tooltip,
      icon: icon,
      color: primary ? Theme.of(context).colorScheme.primary : null,
      onPressed: onPressed,
    );
  }
}

/// A switch at a pointer's size, whose box is its track — so its right edge is
/// where its ink ends. Full size under a thumb.
class DeviceSwitch extends StatelessWidget {
  const DeviceSwitch({required this.value, required this.onChanged, super.key});

  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final toggle = Switch(
      value: value,
      onChanged: onChanged,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      // Material pads the track 4px a side; without it the box is the track.
      padding: EdgeInsets.zero,
    );
    if (UiDensity.of(context).isTouch) return toggle;
    return SizedBox(
      width: DeviceListMetrics.switchWidth,
      height: DeviceListMetrics.switchHeight,
      child: FittedBox(fit: BoxFit.fill, child: toggle),
    );
  }
}

/// One yes-or-no about how devices start: the label where names start, the
/// switch where actions end, and the whole row the target.
class DeviceSwitchRow extends StatelessWidget {
  const DeviceSwitchRow({
    required this.label,
    required this.value,
    required this.onChanged,
    this.help,
    super.key,
  });

  final String label;

  /// One quiet sentence: what the switch will do, in the state it is in.
  final String? help;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final density = UiDensity.of(context);
    final onChanged = this.onChanged;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: DeviceListMetrics.fillInset,
      ),
      child: MergeSemantics(
        child: InkWell(
          borderRadius: BorderRadius.circular(Radii.sm),
          hoverColor: StateLayers.hover(theme.colorScheme),
          onTap: onChanged == null ? null : () => onChanged(!value),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: density.isTouch ? Touch.target : Chrome.row,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal:
                    DeviceListMetrics.inset - DeviceListMetrics.fillInset,
                vertical: Insets.xs,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(label, style: density.rowTitle(theme)),
                        if (help case final line?)
                          Text(line, style: density.muted(theme)),
                      ],
                    ),
                  ),
                  const SizedBox(width: Insets.sm),
                  // Not a second focus stop: the row is the control.
                  ExcludeFocus(
                    child: DeviceSwitch(value: value, onChanged: onChanged),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A muted sentence in the list's column — why a section has no rows.
class DeviceListNote extends StatelessWidget {
  const DeviceListNote(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(
      horizontal: DeviceListMetrics.inset,
      vertical: Insets.xs,
    ),
    child: Align(
      alignment: Alignment.centerLeft,
      child: Text(text, style: UiDensity.of(context).muted(Theme.of(context))),
    ),
  );
}

/// The row that unfolds a list cut short — `Show all (170)` — or folds it
/// again. A row like the ones above it, so it sits in their column.
class DeviceListExpander extends StatelessWidget {
  const DeviceListExpander({
    required this.label,
    required this.expanded,
    required this.onPressed,
    super.key,
  });

  final String label;
  final bool expanded;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final density = UiDensity.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: DeviceListMetrics.fillInset,
      ),
      child: Semantics(
        button: true,
        expanded: expanded,
        child: InkWell(
          borderRadius: BorderRadius.circular(Radii.sm),
          hoverColor: StateLayers.hover(theme.colorScheme),
          onTap: onPressed,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: density.isTouch ? Touch.target : Chrome.row,
            ),
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                DeviceListMetrics.inset - DeviceListMetrics.fillInset,
                Insets.hair,
                DeviceListMetrics.inset -
                    DeviceListMetrics.fillInset -
                    DeviceListMetrics.glyphMargin(density),
                Insets.hair,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: density.muted(theme),
                    ),
                  ),
                  SizedBox.square(
                    dimension: ExplorerRow.slotOf(density),
                    child: Icon(
                      expanded ? AppIcons.caretUp : AppIcons.caretDown,
                      size: ExplorerRow.disclosureSize,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
