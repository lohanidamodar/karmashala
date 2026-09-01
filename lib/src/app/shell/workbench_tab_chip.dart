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
    // and its content read as one surface; selection is then carried by a top
    // rule in the accent, because an outline alone is invisible against a
    // neutral ramp at this size.
    final chip = Material(
      color: selected ? scheme.surfaceContainerLowest : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onSecondaryTapDown: onSecondaryTapDown,
        child: Container(
          height: Chrome.tabStrip,
          constraints: const BoxConstraints(maxWidth: 220),
          padding: EdgeInsets.only(
            left: Insets.sm,
            right: trailing == null ? Insets.sm : 2,
          ),
          decoration: BoxDecoration(
            border: Border(
              top: BorderSide(
                width: 2,
                color: (accented ?? selected)
                    ? scheme.primary
                    : Colors.transparent,
              ),
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
                  style: Chrome.tabLabel.copyWith(
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
