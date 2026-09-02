/// The companion's shared chrome: one app bar, one bottom sheet, one section
/// header, one readable width.
///
/// Each of these was written out by hand in three to five places, and each had
/// drifted in a way a user could see. Four app bars took Material's fixed 56px
/// while three others grew with the text scale, so at 200% the Diagnostics and
/// Pairing titles clipped and the Project and New-session titles did not. Two
/// of the three bottom sheets were not scroll-controlled, which caps a sheet at
/// half the viewport — the host switcher put a bare [Column] in that half and
/// overflowed as soon as a phone had four desktops. Five section headings
/// repeated the same `labelSmall` line and the same 8px gap.
///
/// The tokens here are the app's own — [Insets], [Radii], the [TextTheme]
/// roles. The **geometry** is the phone's: heights come from [Touch] and
/// [UiDensity], never from [Chrome], because a pointer's 30px row is not a
/// target. Where a companion widget can also be hosted at pointer density —
/// a fold-out, a landscape tablet — the density is asked rather than assumed.
///
/// Width is the same kind of decision, taken here for the same reason: past
/// the compact breakpoint every companion list would otherwise run its rows
/// the full width of a tablet. [companionReadableWidth] is the one answer, and
/// [companionListInsets] and [CompanionReadable] are the two shapes of content
/// that need it.
library;

import 'package:flutter/material.dart';

import '../../../app/theme/design_tokens.dart';

/// The room a scrolling list leaves under its last row when a floating action
/// button hovers over it.
///
/// A [Touch.target]-tall button plus a gutter above and below it. The Projects
/// tab was leaving [Insets.xl], which is less than the button is tall, so the
/// last project's row sat behind the button offering to start another session
/// in it.
const double companionFabGutter = Touch.target + Insets.xl;

/// The widest a column of companion content is ever drawn.
///
/// Exactly [UiDensity.compactWidth] — the widest phone this app was designed
/// for — because past that point the extra pixels are gutter, not measure. A
/// session title, a checkout path or a paragraph of settings prose set across
/// 1280px of tablet is a line the eye has to track back along, and CLAUDE.md
/// §6 forbids stretching narrow list content over a wide screen. Tying the
/// cap to the breakpoint rather than picking a second number also means the
/// column below 600 is untouched: the gutter is zero on every phone.
const double companionReadableWidth = UiDensity.compactWidth;

/// The room left either side of that column on this surface, or zero on a
/// phone.
///
/// Measured from the viewport, the same question [UiDensity.wrap] asks when it
/// decides the density — one notion of "how wide is this surface", not two.
double companionGutterOf(BuildContext context) {
  final width = MediaQuery.sizeOf(context).width;
  return width <= companionReadableWidth
      ? 0
      : (width - companionReadableWidth) / 2;
}

/// [base] widened by that gutter — what a companion list passes as its own
/// `padding`.
///
/// Padding rather than a [ConstrainedBox] wrapped round the list, so a tablet's
/// empty margin still takes a fling: the content narrows, the scrollable does
/// not.
EdgeInsets companionListInsets(BuildContext context, EdgeInsets base) {
  final gutter = companionGutterOf(context);
  return gutter == 0
      ? base
      : base.copyWith(left: base.left + gutter, right: base.right + gutter);
}

/// The same cap for content that does not scroll — a header strip, a status
/// row, a transcript with its composer pinned under it.
class CompanionReadable extends StatelessWidget {
  const CompanionReadable({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final gutter = companionGutterOf(context);
    return gutter == 0
        ? child
        : Padding(
            padding: EdgeInsets.symmetric(horizontal: gutter),
            child: child,
          );
  }
}

/// The height of a companion app bar: [Touch.appBar] grown with the ambient
/// text scale, or the desktop's title-bar row when this is not a touch surface.
///
/// A screen's own name is the worst thing on it to clip, and Material's fixed
/// `toolbarHeight` clips it at any scale above about 130%.
double companionAppBarHeight(BuildContext context) =>
    UiDensity.of(context).isTouch
    ? Touch.appBarOf(context)
    : Chrome.titleBarOf(context);

/// The companion's app bar. Everything but the height comes from the theme;
/// the height is the one thing a theme cannot express, because it depends on
/// the text scaler in effect at this point in the tree.
AppBar companionAppBar(
  BuildContext context, {
  required Widget title,
  List<Widget>? actions,
}) => AppBar(
  toolbarHeight: companionAppBarHeight(context),
  title: title,
  actions: actions,
);

/// A titled bottom sheet that can always be read to the end.
///
/// Scroll-controlled and capped against the viewport rather than left at
/// Material's default half-height: a picker's job is to show every choice, and
/// a list of desktops or projects at 200% text is taller than half a phone.
/// [children] scroll under a pinned [title]; the drag handle and the sheet's
/// colour and radius come from the touch theme.
Future<T?> companionSheet<T>(
  BuildContext context, {
  required String title,
  required List<Widget> children,
}) => showModalBottomSheet<T>(
  context: context,
  isScrollControlled: true,
  constraints: BoxConstraints(
    maxHeight: MediaQuery.sizeOf(context).height * 0.85,
  ),
  builder: (context) => SafeArea(
    top: false,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            Insets.lg,
            0,
            Insets.lg,
            Insets.sm,
          ),
          child: CompanionSectionHeader(title, gap: 0),
        ),
        // Flexible, not Expanded: a two-item sheet stays two items tall.
        Flexible(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: children,
            ),
          ),
        ),
      ],
    ),
  ),
);

/// The line that names a group of settings — "DESKTOPS", "DIAGNOSTICS".
///
/// `labelSmall` is the ramp's micro step, and the app theme already gives it
/// the 0.8 letter-spacing and w600 an all-caps run needs; the widget's job is
/// to stop five screens each remembering that, and to say `header: true` so a
/// screen reader can jump between sections instead of reading every row.
class CompanionSectionHeader extends StatelessWidget {
  const CompanionSectionHeader(this.label, {this.gap = Insets.sm, super.key});

  /// Written as it is drawn — the caller keeps its own capitalisation, so the
  /// string in the source is the string on the screen.
  final String label;

  /// The space under the heading, before what it heads. [Insets.sm] by
  /// default; zero where the container already spaces its children.
  final double gap;

  @override
  Widget build(BuildContext context) {
    final text = Semantics(
      header: true,
      child: Text(label, style: Theme.of(context).textTheme.labelSmall),
    );
    return gap == 0
        ? text
        : Padding(
            padding: EdgeInsets.only(bottom: gap),
            child: text,
          );
  }
}
