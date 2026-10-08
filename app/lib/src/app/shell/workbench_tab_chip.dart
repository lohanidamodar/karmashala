import 'package:flutter/material.dart';

import 'package:karmashala_ui/tokens.dart';

import '../widgets/truncated_text.dart';
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
    this.badge,
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

  /// A count beside the title — the artifacts a session showed. Dropped with
  /// [mark] on a narrow chip.
  final Widget? badge;

  final Widget? trailing;
  final GestureTapDownCallback? onSecondaryTapDown;

  /// What a **middle click** does — the reversible close, never ending the
  /// session. `InkWell` has no tertiary callback, hence the wrapper; it fires up.
  final VoidCallback? onClose;

  /// Shown over the title: the title alone when null, and then only once the
  /// chip cuts it. One that says more — a session's agent and machine — shows
  /// whether or not the title fits.
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
                right: trailing == null ? Insets.sm : Insets.xxs,
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
                    child: Row(
                      children: [
                        if (mark case final mark?
                            when constraints.maxWidth >= kMinTabWidth)
                          Padding(
                            padding: const EdgeInsets.only(right: Insets.xs),
                            child: mark,
                          ),
                        Expanded(
                          // Over the title only, and only once it is cut:
                          // the status glyph and the close button have their
                          // own.
                          child: TruncatedText(
                            label,
                            tooltip: tooltip,
                            // A tooltip that says more than the title — the
                            // agent, the machine — is worth a hover always.
                            always: tooltip != null && tooltip != label,
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
                        if (badge case final badge?
                            when constraints.maxWidth >= kMinTabWidth)
                          Padding(
                            padding: const EdgeInsets.only(left: Insets.xs),
                            child: badge,
                          ),
                      ],
                    ),
                  ),
                  if (trailing != null) ...[
                    const SizedBox(width: Insets.xxs),
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
}

/// What hovering a cut tab title says: the title in full, and the agent and
/// where it runs when the tab holds a session.
String tabTitleTooltip(String title, String? agentName, {String? where}) =>
    [title, ?agentName, ?where].join(' · ');
