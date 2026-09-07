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
  /// question from being selected.
  ///
  /// **Three states, not two.** Once the window holds several strips — a
  /// workspace group has one, and a region of a split tab has one — "the tab
  /// this strip is showing" and "the tab your keystrokes reach" stop being the
  /// same question. Four groups each drawing a fully selected tab say nothing
  /// about where you are typing. So:
  ///
  /// | selected | accented | reads as |
  /// | --- | --- | --- |
  /// | false | — | not the tab this strip is showing |
  /// | true | false | the tab this strip is showing |
  /// | true | true | …and this is where typing goes |
  ///
  /// Null means the two are the same question and selection carries the accent
  /// — which is what a strip that is always focused wants.
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

  /// What a **middle click** on the chip does — the reversible close, never
  /// ending the session.
  ///
  /// A wheel press is mushy on most mice and easy to fire while scrolling, so
  /// it gets the action whose cost can be undone: the tab or pane goes and the
  /// session is parked, which is exactly what this chip's own X button does
  /// and what its tooltip already promises. Ending one stays behind a menu
  /// item with a word on it.
  ///
  /// It lives here rather than at the call sites because both strips share this
  /// chip, and a gesture that worked in the workbench strip but not in a
  /// group's would be worse than not having it. `InkWell` has no tertiary
  /// callback, hence the wrapper; it fires on *up*, so sliding off the chip
  /// still cancels.
  final VoidCallback? onClose;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // The active chip takes the colour of the ground it sits over, so the tab
    // and its content read as one surface; selection is then carried by a rule
    // in the accent, because an outline alone is invisible against a neutral
    // ramp at this size. The rule sits on the edge the chip belongs to: a tab
    // points up at the window it names, a pane header points down at the pane.
    // The middle state is a rule too, in the neutral ink rather than the
    // accent: dropping it entirely would leave an unfocused group's chosen tab
    // looking like any other tab in its strip, and a group must always show
    // which tab its terminal and its status bar belong to.
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
                          // Full ink only where the keyboard is. A strip nobody
                          // is typing in keeps its tab legible and stops it
                          // competing with the one that is.
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
