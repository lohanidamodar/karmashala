import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:karmashala_ui/tokens.dart';

import 'adaptive_modal.dart';
import 'yielding_row.dart';

/// One fact or control on a [StatusStrip].
class StatusStripItem {
  const StatusStripItem({required this.id, required this.builder});

  /// Names the item's key, `status-strip:<id>`.
  final String id;

  /// Draws the item: in its short form while the strip is short of room, and
  /// whole in the strip's sheet. Nothing, and no width, when it has nothing
  /// to say.
  final Widget Function(BuildContext context, bool short) builder;
}

/// **A session's one status line**: facts and pickers in priority order, on
/// one line that never scrolls or clips. Labels shorten before anything goes;
/// past that the last items fold, whole, into **+N**, which opens [sheet] —
/// a list of every item with its picker, and the verbs — in a popover under
/// it, or a bottom sheet on a phone. [pinned] never fold — the state and the
/// model.
class StatusStrip extends StatefulWidget {
  const StatusStrip({
    required this.pinned,
    required this.items,
    required this.sheetTitle,
    required this.sheet,
    this.more,
    this.shortBelow = 720,
    super.key,
  });

  static const foldKey = ValueKey('status-strip-fold');

  /// Always shown: the first at its own width, the rest ending in an ellipsis
  /// before they would push the line over.
  final List<StatusStripItem> pinned;

  /// The rest, most important first; the last folds first.
  final List<StatusStripItem> items;

  /// The sheet's title.
  final String sheetTitle;

  /// The verbs (⋯) at the end of the line while nothing folds; the [sheet]
  /// holds them once something does.
  final Widget? more;

  /// What +N opens: every item, then the verbs. It scrolls itself.
  final WidgetBuilder sheet;

  /// The width, at 1x text, below which the items draw their short labels.
  final double shortBelow;

  @override
  State<StatusStrip> createState() => _StatusStripState();
}

class _StatusStripState extends State<StatusStrip> {
  var _folded = 0;

  void _hiddenChanged(List<bool> hidden) {
    final folded = hidden.where((h) => h).length;
    if (folded != _folded) setState(() => _folded = folded);
  }

  Widget _item(BuildContext context, StatusStripItem item, bool short) =>
      KeyedSubtree(
        key: ValueKey('status-strip:${item.id}'),
        child: item.builder(context, short),
      );

  /// [context] is +N's own: the popover hangs from it.
  void _openSheet(BuildContext context) => showAdaptivePopover<void>(
    context: context,
    title: widget.sheetTitle,
    width: DialogWidth.popover,
    builder: (sheet) => KeyedSubtree(
      key: const ValueKey('status-strip-sheet'),
      child: widget.sheet(sheet),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final short =
            constraints.maxWidth <
            WidthClass.scaleBreakpoint(
              widget.shortBelow,
              MediaQuery.textScalerOf(context),
            );
        final pinned = widget.pinned;
        // A fixed slot at the end, whichever it holds: were +N wider than
        // ⋯, folding would take the room that let it unfold.
        final slot = SizedBox(
          width: Touch.target,
          child: _folded > 0
              ? Tooltip(
                  message: '$_folded more, and the session\'s verbs',
                  child: Builder(
                    builder: (button) => TextButton(
                      key: StatusStrip.foldKey,
                      style: TextButton.styleFrom(
                        minimumSize: const Size(Touch.target, Touch.target),
                        padding: EdgeInsets.zero,
                        foregroundColor: theme.colorScheme.onSurface,
                        textStyle: theme.textTheme.labelMedium,
                      ),
                      onPressed: () => _openSheet(button),
                      child: Text('+$_folded', maxLines: 1, softWrap: false),
                    ),
                  ),
                )
              : Center(child: widget.more ?? const SizedBox.shrink()),
        );
        return Row(
          children: [
            ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: math.max(
                  0,
                  constraints.maxWidth - Touch.target - Insets.xs,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < pinned.length; i++)
                    if (i == 0)
                      _item(context, pinned[i], short)
                    else
                      Flexible(
                        child: Padding(
                          padding: const EdgeInsetsDirectional.only(
                            start: Insets.xs,
                          ),
                          child: _item(context, pinned[i], short),
                        ),
                      ),
                ],
              ),
            ),
            const SizedBox(width: Insets.xs),
            Expanded(
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: YieldingRow(
                  yieldFromStart: false,
                  spacing: Insets.xs,
                  onHiddenChanged: _hiddenChanged,
                  children: [
                    for (final item in widget.items)
                      _item(context, item, short),
                  ],
                ),
              ),
            ),
            slot,
          ],
        );
      },
    );
  }
}
