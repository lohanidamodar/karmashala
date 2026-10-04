import 'package:flutter/material.dart';

import 'package:karmashala_ui/tokens.dart';

import 'tab_strip_metrics.dart';

/// The shared chip shape for everything in the workbench tab strip, so a
/// session tab and a terminal tab are visibly the same kind of thing.
class WorkbenchTabChip extends StatelessWidget {
  const WorkbenchTabChip({
    required this.selected,
    required this.onTap,
    required this.label,
    this.leading,
    this.mark,
    this.trailing,
    this.onSecondaryTapDown,
    this.onClose,
    this.tooltip,
    this.accented,
    this.dense = false,
    this.needsYou = false,
    super.key,
  });

  final bool selected;

  /// Whether this chip carries the accent rule, when that is a different
  /// question from being selected. Null means it is not, and selection carries it.
  final bool? accented;

  /// Whether this chip belongs to a **pane** header rather than the window's tab
  /// strip: shorter, and selected on its *bottom* edge, so it reads as a header.
  final bool dense;

  /// Whether the tab's session is waiting on the user (spec §5, board N1's
  /// `.wt.ask`): the chip takes the attention tone in place of the selected
  /// one, with full ink and no accent rule — the amber, not the keyboard's
  /// accent, is what the eye must find — so a blocked session is seen from
  /// any strip, focused or not.
  final bool needsYou;

  final VoidCallback onTap;
  final String label;
  final Widget? leading;

  /// The tab's session's agent, between [leading] and the title. Dropped on a
  /// chip narrower than [kMinTabWidth], where the title needs the room more.
  final Widget? mark;

  final Widget? trailing;
  final GestureTapDownCallback? onSecondaryTapDown;

  /// What a **middle click** does — the reversible close, never ending the
  /// session. `InkWell` has no tertiary callback, hence the wrapper; it fires up.
  final VoidCallback? onClose;

  /// Shown over the title: its full text, which the chip cuts to fit.
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tones = SurfaceTones.of(context);
    // The active chip takes the tone of the pane it heads — the terminal's —
    // and the accent on its edge says where the keyboard is. The middle state
    // (selected in a group without focus) keeps the tone and drops the accent.
    final rule = BorderSide(
      width: 2,
      color: needsYou
          ? Colors.transparent
          : switch ((selected, accented)) {
              (true, null) || (true, true) => scheme.primary,
              _ => Colors.transparent,
            },
    );
    return Material(
      color: needsYou
          ? tones.attentionSurface
          : selected
          ? tones.term
          : Colors.transparent,
      child: GestureDetector(
        onTertiaryTapUp: onClose == null ? null : (_) => onClose!(),
        child: InkWell(
          onTap: onTap,
          onSecondaryTapDown: onSecondaryTapDown,
          child: LayoutBuilder(
            builder: (context, constraints) => Container(
              height: dense ? Chrome.paneStrip : Chrome.tabStrip,
              constraints: const BoxConstraints(maxWidth: kMaxTabWidth),
              padding: EdgeInsets.only(
                left: dense ? Insets.xs : Insets.sm,
                right: trailing == null ? Insets.sm : 2,
              ),
              decoration: BoxDecoration(
                border: Border(
                  top: dense ? BorderSide.none : rule,
                  bottom: dense ? rule : BorderSide.none,
                  // A hairline only when the user asked for lines between
                  // regions; otherwise the tones part the tabs.
                  right: BorderSide(color: tones.line),
                ),
              ),
              // Fills the slot the strip gave it rather than hugging its title:
              // at a uniform extent, a short name left the X floating mid-tab.
              child: Row(
                children: [
                  ?leading,
                  Expanded(
                    child: _titleTooltip(
                      Row(
                        children: [
                          if (mark case final mark?
                              when constraints.maxWidth >= kMinTabWidth)
                            Padding(
                              padding: const EdgeInsets.only(right: Insets.xs),
                              child: mark,
                            ),
                          Expanded(
                            child: Text(
                              label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: (dense ? Chrome.paneLabel : Chrome.tabLabel)
                                  .copyWith(
                                    // Full ink only where the keyboard is: a
                                    // strip nobody types in must not compete
                                    // with the one that is.
                                    color:
                                        needsYou ||
                                            (selected && (accented ?? true))
                                        ? scheme.onSurface
                                        : scheme.onSurfaceVariant,
                                  ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (trailing != null) ...[
                    const SizedBox(width: 2),
                    trailing!,
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // Over the title only: the status glyph and the close button have their own.
  Widget _titleTooltip(Widget title) =>
      tooltip == null ? title : Tooltip(message: tooltip!, child: title);
}

/// What hovering a tab's title says: the title in full, which the chip cuts to
/// fit, and the agent when the tab holds a session.
String tabTitleTooltip(String title, String? agentName) =>
    agentName == null ? title : '$title · $agentName';
