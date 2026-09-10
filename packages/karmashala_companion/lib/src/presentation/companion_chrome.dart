/// The companion's shared chrome: app bar, bottom sheet, section header,
/// readable width. Heights from [Touch]/[UiDensity], never [Chrome]'s 30px row.
library;

import 'package:flutter/material.dart';

import 'package:karmashala_ui/tokens.dart';

/// The room a scrolling list leaves under its last row when a floating action
/// button hovers over it: a [Touch.target]-tall button plus a gutter each side.
const double companionFabGutter = Touch.target + Insets.xl;

/// The widest a column of companion content is ever drawn: the compact
/// breakpoint itself, so the gutter is zero on every phone and a tablet does
/// not run a line of prose across 1280px (CLAUDE.md §6).
const double companionReadableWidth = UiDensity.compactWidth;

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
