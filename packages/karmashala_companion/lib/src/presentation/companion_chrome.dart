/// The companion's shared chrome: app bar, bottom sheet, section header,
/// readable width. Heights from [Touch]/[UiDensity], never [Chrome]'s 30px row.
library;

import 'package:flutter/material.dart';

import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';

/// The room a scrolling list leaves under its last row when a floating action
/// button hovers over it: a [Touch.target]-tall button plus a gutter each side.
const double companionFabGutter = Touch.target + Insets.xl;

/// The widest a column of companion content is ever drawn: the compact
/// breakpoint itself, so the gutter is zero on every phone and a tablet does
/// not run a line of prose across 1280px (CLAUDE.md §6).
const double companionReadableWidth = UiDensity.compactWidth;

/// The width of a single focused thing on an otherwise empty screen — a notice,
/// the pairing steps: narrower than [companionReadableWidth], since it is read
/// at a glance rather than scanned.
const double companionFocusedWidth = companionReadableWidth * 0.7;

/// The room left either side of that column, or zero on a phone. Measured from
/// the viewport, not the density: a tablet is wide and still held in a hand, so
/// it gets the gutter and keeps the 48dp rows.
double companionGutterOf(BuildContext context) {
  final width = MediaQuery.sizeOf(context).width;
  return width <= companionReadableWidth
      ? 0
      : (width - companionReadableWidth) / 2;
}

/// [base] widened by that gutter — padding rather than a [ConstrainedBox] round
/// the list, so a tablet's empty margin still takes a fling.
EdgeInsets companionListInsets(BuildContext context, EdgeInsets base) {
  final gutter = companionGutterOf(context);
  return gutter == 0
      ? base
      : base.copyWith(left: base.left + gutter, right: base.right + gutter);
}

/// The height left above an open keyboard under which a screen drops its
/// secondary chrome, so the field being typed into keeps the room.
const double companionSqueezedHeight = 520;

/// Whether the keyboard is open and has left less than
/// [companionSqueezedHeight] of the screen.
bool companionKeyboardSqueezed(BuildContext context) {
  final keyboard = MediaQuery.viewInsetsOf(context).bottom;
  return keyboard > 0 &&
      MediaQuery.sizeOf(context).height - keyboard < companionSqueezedHeight;
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
/// text scale, or the desktop's title-bar row off a touch surface. Material's
/// fixed `toolbarHeight` clips a title above about 130%.
double companionAppBarHeight(BuildContext context) =>
    UiDensity.of(context).isTouch
    ? Touch.appBarOf(context)
    : Chrome.titleBarOf(context);

/// The companion's app bar. Only the height is set here: a theme cannot express
/// it, because it depends on the text scaler at this point in the tree.
AppBar companionAppBar(
  BuildContext context, {
  required Widget title,
  List<Widget>? actions,
}) => AppBar(
  toolbarHeight: companionAppBarHeight(context),
  title: title,
  actions: actions,
);

/// The most of the screen a companion sheet covers: enough to scroll a long
/// list, short of hiding what the sheet was opened from.
const double companionSheetMaxShare = 0.85;

/// A thin band of ground above and below a badge's word, under the 4-pt scale
/// so a badge does not grow the line it sits in.
const double companionBadgeHairline = 1;

/// A titled bottom sheet that can always be read to the end: scroll-controlled
/// and capped against the viewport, because Material's default half-height is
/// shorter than a list of desktops at 200% text.
Future<T?> companionSheet<T>(
  BuildContext context, {
  required String title,
  required List<Widget> children,
}) => showModalBottomSheet<T>(
  context: context,
  isScrollControlled: true,
  constraints: BoxConstraints(
    maxHeight: MediaQuery.sizeOf(context).height * companionSheetMaxShare,
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

/// The line that names a group of settings — "DESKTOPS", "DIAGNOSTICS". Says
/// `header: true`, so a screen reader can jump between sections.
class CompanionSectionHeader extends StatelessWidget {
  const CompanionSectionHeader(this.label, {this.gap = Insets.sm, super.key});

  /// Written as it is drawn: the caller keeps its own capitalisation.
  final String label;

  /// The space under the heading; zero where the container already spaces its
  /// children.
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

/// A form's one full-width action: its icon, or the house spinner while the
/// work it started is in flight.
class CompanionPrimaryButton extends StatelessWidget {
  const CompanionPrimaryButton({
    required this.label,
    required this.icon,
    required this.onPressed,
    this.busy = false,
    super.key,
  });

  final String label;
  final IconData icon;

  /// Null disables the button; it is also disabled while [busy].
  final VoidCallback? onPressed;
  final bool busy;

  @override
  Widget build(BuildContext context) => FilledButton.icon(
    onPressed: busy ? null : onPressed,
    icon: busy ? const InlineSpinner() : Icon(icon),
    label: Text(label),
    style: FilledButton.styleFrom(
      minimumSize: const Size.fromHeight(Touch.target),
    ),
  );
}

/// The companion's one tappable row: a leading glyph, a title that takes the
/// free width, and an optional trailing part that gives way before it
/// overflows. [Touch.target] tall at least on a touch surface.
class CompanionTouchRow extends StatelessWidget {
  const CompanionTouchRow({
    required this.leading,
    required this.title,
    this.trailing,
    this.onTap,
    this.padding,
    this.alignTop = false,
    super.key,
  });

  final Widget leading;
  final Widget title;
  final Widget? trailing;

  /// Null draws the row as a statement, not a control.
  final VoidCallback? onTap;

  /// The density's own padding unless a row needs its edge elsewhere — a
  /// tablet gutter, or a trailing button that brings its own box.
  final EdgeInsetsGeometry? padding;

  /// Top-align a multi-line title with its glyph instead of centring.
  final bool alignTop;

  @override
  Widget build(BuildContext context) {
    final density = UiDensity.of(context);
    final trailing = this.trailing;
    return InkWell(
      onTap: onTap,
      child: Container(
        constraints: BoxConstraints(minHeight: density.minRow),
        padding:
            padding ??
            EdgeInsets.symmetric(
              horizontal: density.padX,
              vertical: density.padY,
            ),
        child: LayoutBuilder(
          builder: (context, constraints) => Row(
            crossAxisAlignment: alignTop
                ? CrossAxisAlignment.start
                : CrossAxisAlignment.center,
            children: [
              leading,
              SizedBox(width: density.isTouch ? Insets.md : Insets.sm),
              Expanded(child: title),
              if (trailing != null) ...[
                SizedBox(width: density.glyphGap),
                // Its own width, but never more than half the row: a count
                // or a label at 200% text gives way instead of overflowing.
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: constraints.maxWidth / 2,
                  ),
                  child: trailing,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The hairline between two rows of a companion list.
class CompanionRowDivider extends StatelessWidget {
  const CompanionRowDivider({this.indent = Insets.lg, super.key});

  /// From the leading edge; zero for a full-width rule between cards.
  final double indent;

  @override
  Widget build(BuildContext context) => Divider(
    height: 1,
    thickness: 1,
    indent: indent,
    color: Theme.of(context).colorScheme.outlineVariant,
  );
}
