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
    this.onClose,
    this.tooltip,
    this.accented,
    this.dense = false,
    super.key,
  });

  final bool selected;

  /// Whether this chip carries the accent rule, when that is a different
  /// question from being selected. Null means it is not, and selection carries it.
  final bool? accented;

  /// Whether this chip belongs to a **pane** header rather than the window's tab
  /// strip: shorter, and selected on its *bottom* edge, so it reads as a header.
  final bool dense;

  final VoidCallback onTap;
  final String label;
  final Widget? leading;
  final Widget? trailing;
  final GestureTapDownCallback? onSecondaryTapDown;

  /// What a **middle click** does — the reversible close, never ending the
  /// session. `InkWell` has no tertiary callback, hence the wrapper; it fires up.
  final VoidCallback? onClose;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // The active chip takes the colour of the ground it sits over, and selection
    // is then a rule on its edge; the middle state is neutral, not unselected.
    final rule = BorderSide(
      width: 2,
      color: switch ((selected, accented)) {
        (false, _) => Colors.transparent,
        (true, false) => scheme.outlineVariant,
        _ => scheme.primary,
      },
    );
    final chip = Material(
      color: selected ? scheme.surfaceContainerLowest : Colors.transparent,
      child: GestureDetector(
        onTertiaryTapUp: onClose == null ? null : (_) => onClose!(),
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
            // at a uniform extent, a short name left the X floating mid-tab.
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
                          // Full ink only where the keyboard is: a strip nobody
                          // types in must not compete with the one that is.
                          color: selected && (accented ?? true)
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
      ),
    );
    return tooltip == null ? chip : Tooltip(message: tooltip!, child: chip);
  }
}
