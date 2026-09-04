import 'package:flutter/material.dart';

import '../theme/design_tokens.dart';

/// The shared chip shape for everything in the workbench tab strip, so a
/// session tab and a terminal tab are visibly the same kind of thing.
class WorkbenchTabChip extends StatelessWidget {
  const WorkbenchTabChip({
    required this.selected,
    required this.onTap,
    required this.label,
    this.leading,
    this.trailing,
    this.onSecondaryTapDown,
    this.tooltip,
    this.accented,
    this.dense = false,
    super.key,
  });

  final bool selected;

  /// Whether this chip carries the accent rule, when that is a different
  /// question from being selected.
  ///
  /// A window has one workbench strip, so there "the selected tab" and "the tab
  /// you are working in" are the same tab and this stays null. A split has a
  /// header per region and each one has a selected tab, but only one of them
  /// holds the keyboard — so the ground says *this region is showing this
  /// pane* and the accent says *and this is where typing goes*.
  final bool? accented;

  /// Whether this chip belongs to a **pane** header rather than the window's
  /// tab strip.
  ///
  /// A split stacks the two rows directly on top of each other, and drawing
  /// them identically is what made the region header read as a second, inert
  /// copy of the tab above it — *"an extra tab that doesn't do anything"*. So
  /// the pane variant is shorter ([Chrome.paneStrip]), its label is a step
  /// down ([Chrome.paneLabel]), and it carries selection on its **bottom**
  /// edge, against the pane it names, where a tab carries it on its top edge
  /// against the window. Shape and size rather than colour, for the reason
  /// `session_status.dart` gives: a hue is not a category.
  final bool dense;

  final VoidCallback onTap;
  final String label;
  final Widget? leading;
  final Widget? trailing;
  final GestureTapDownCallback? onSecondaryTapDown;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // The active chip takes the colour of the ground it sits over, so the tab
    // and its content read as one surface; selection is then carried by a rule
    // in the accent, because an outline alone is invisible against a neutral
    // ramp at this size. The rule sits on the edge the chip belongs to: a tab
    // points up at the window it names, a pane header points down at the pane.
    final rule = BorderSide(
      width: 2,
      color: (accented ?? selected) ? scheme.primary : Colors.transparent,
    );
    final chip = Material(
      color: selected ? scheme.surfaceContainerLowest : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onSecondaryTapDown: onSecondaryTapDown,
        child: Container(
          height: dense ? Chrome.paneStrip : Chrome.tabStrip,
          constraints: const BoxConstraints(maxWidth: 220),
          padding: EdgeInsets.only(
            left: dense ? Insets.xs : Insets.sm,
            right: trailing == null ? Insets.sm : 2,
          ),
          decoration: BoxDecoration(
            border: Border(
              top: dense ? BorderSide.none : rule,
              bottom: dense ? rule : BorderSide.none,
              right: BorderSide(color: scheme.outlineVariant),
            ),
          ),
          // Fills the slot the strip gave it rather than hugging its title:
          // tabs are laid out at a uniform extent, so a short name left the X
          // floating in the middle of the tab with empty space after it — "the
          // tabs close button is aligned to text not to the tab pad itself".
          child: Row(
            children: [
              ?leading,
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: (dense ? Chrome.paneLabel : Chrome.tabLabel)
                      .copyWith(
                        color: selected
                            ? scheme.onSurface
                            : scheme.onSurfaceVariant,
                      ),
                ),
              ),
              if (trailing != null) ...[const SizedBox(width: 2), trailing!],
            ],
          ),
        ),
      ),
    );
    return tooltip == null ? chip : Tooltip(message: tooltip!, child: chip);
  }
}
