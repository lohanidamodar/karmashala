import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:karmashala_ui/tokens.dart';

/// How many of a title's characters stay readable before a card gives its
/// title the row to itself.
const int kOverviewTitleKeeps = 16;

/// The width [title]'s first [kOverviewTitleKeeps] characters take in
/// [style] at the ambient text scale: what a card's title is never squeezed
/// below.
double overviewTitleFloor(
  BuildContext context,
  String title,
  TextStyle? style,
) {
  final kept = title.characters.take(kOverviewTitleKeeps).toString();
  final painter = TextPainter(
    text: TextSpan(text: kept, style: style),
    maxLines: 1,
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
  )..layout();
  final width = painter.width;
  painter.dispose();
  return width;
}

/// **A card's title line**, shared by every card and row: [title] with
/// [meta] under it, and [trailing] — the state chip, End and ⋯ — at the end.
/// When the trailing controls would squeeze the title below [titleFloor],
/// the title takes the row and they move to the next line, beside [meta] or,
/// with no room beside it, under it.
class OverviewTitleBlock extends MultiChildRenderObjectWidget {
  OverviewTitleBlock({
    required Widget title,
    required Widget trailing,
    required this.titleFloor,
    Widget? meta,
    super.key,
  }) : super(children: [title, meta ?? const SizedBox.shrink(), trailing]);

  final double titleFloor;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderOverviewTitleBlock(titleFloor);

  @override
  void updateRenderObject(
    BuildContext context,
    RenderOverviewTitleBlock renderObject,
  ) => renderObject.titleFloor = titleFloor;
}

class _BlockParentData extends ContainerBoxParentData<RenderBox> {}

/// How [OverviewTitleBlock] places its three parts at a width.
enum OverviewTitleLayout {
  /// Title and meta on the left, trailing beside them.
  oneRow,

  /// Title alone, then meta with trailing beside it.
  besideMeta,

  /// Title, meta, then trailing on a line of its own.
  underMeta,
}

class RenderOverviewTitleBlock extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _BlockParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _BlockParentData> {
  RenderOverviewTitleBlock(this._titleFloor);

  double _titleFloor;
  set titleFloor(double value) {
    if (value == _titleFloor) return;
    _titleFloor = value;
    markNeedsLayout();
  }

  static const _gap = Insets.sm;

  /// The least room meta keeps beside the trailing controls on line two.
  static const _metaKeeps = Insets.xxl * 2;

  /// The layout chosen at the last layout, for tests.
  OverviewTitleLayout arrangement = OverviewTitleLayout.oneRow;

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _BlockParentData) {
      child.parentData = _BlockParentData();
    }
  }

  RenderBox get _title => firstChild!;
  RenderBox get _meta => childAfter(_title)!;
  RenderBox get _trailing => lastChild!;

  OverviewTitleLayout _layoutAt(double width) {
    final trailing = _trailing.getMaxIntrinsicWidth(double.infinity);
    final title = _title.getMaxIntrinsicWidth(double.infinity);
    final need = math.min(title, _titleFloor);
    if (width - trailing - _gap >= need) return OverviewTitleLayout.oneRow;
    final meta = _meta.getMaxIntrinsicWidth(double.infinity);
    if (meta == 0 || width - trailing - _gap >= _metaKeeps) {
      return OverviewTitleLayout.besideMeta;
    }
    return OverviewTitleLayout.underMeta;
  }

  @override
  double computeMinIntrinsicWidth(double height) => math.max(
    _trailing.getMinIntrinsicWidth(height),
    _title.getMinIntrinsicWidth(height),
  );

  @override
  double computeMaxIntrinsicWidth(double height) =>
      math.max(
        _title.getMaxIntrinsicWidth(height),
        _meta.getMaxIntrinsicWidth(height),
      ) +
      _gap +
      _trailing.getMaxIntrinsicWidth(height);

  double _heightAt(double width, double Function(RenderBox, double) of) {
    final trailingWidth = math.min(
      width,
      _trailing.getMaxIntrinsicWidth(double.infinity),
    );
    final side = math.max(0.0, width - trailingWidth - _gap);
    return switch (_layoutAt(width)) {
      OverviewTitleLayout.oneRow => math.max(
        of(_title, side) + of(_meta, side),
        of(_trailing, trailingWidth),
      ),
      OverviewTitleLayout.besideMeta =>
        of(_title, width) +
            math.max(of(_meta, side), of(_trailing, trailingWidth)),
      OverviewTitleLayout.underMeta =>
        of(_title, width) + of(_meta, width) + of(_trailing, width),
    };
  }

  @override
  double computeMinIntrinsicHeight(double width) =>
      _heightAt(width, (child, w) => child.getMinIntrinsicHeight(w));

  @override
  double computeMaxIntrinsicHeight(double width) =>
      _heightAt(width, (child, w) => child.getMaxIntrinsicHeight(w));

  @override
  Size computeDryLayout(covariant BoxConstraints constraints) {
    final width = constraints.maxWidth;
    return constraints.constrain(
      Size(
        width,
        _heightAt(width, (child, w) => child.getMaxIntrinsicHeight(w)),
      ),
    );
  }

  @override
  void performLayout() {
    final width = constraints.maxWidth;
    arrangement = _layoutAt(width);
    void place(RenderBox child, double x, double y) =>
        (child.parentData! as _BlockParentData).offset = Offset(x, y);
    _trailing.layout(BoxConstraints(maxWidth: width), parentUsesSize: true);
    final trailing = _trailing.size;
    final side = math.max(0.0, width - trailing.width - _gap);
    switch (arrangement) {
      case OverviewTitleLayout.oneRow:
        _title.layout(BoxConstraints(maxWidth: side), parentUsesSize: true);
        _meta.layout(BoxConstraints(maxWidth: side), parentUsesSize: true);
        final text = _title.size.height + _meta.size.height;
        final height = math.max(text, trailing.height);
        place(_title, 0, (height - text) / 2);
        place(_meta, 0, (height - text) / 2 + _title.size.height);
        place(
          _trailing,
          width - trailing.width,
          (height - trailing.height) / 2,
        );
        size = constraints.constrain(Size(width, height));
      case OverviewTitleLayout.besideMeta:
        _title.layout(BoxConstraints(maxWidth: width), parentUsesSize: true);
        _meta.layout(BoxConstraints(maxWidth: side), parentUsesSize: true);
        final top = _title.size.height;
        final line = math.max(_meta.size.height, trailing.height);
        place(_title, 0, 0);
        place(_meta, 0, top + (line - _meta.size.height) / 2);
        place(
          _trailing,
          width - trailing.width,
          top + (line - trailing.height) / 2,
        );
        size = constraints.constrain(Size(width, top + line));
      case OverviewTitleLayout.underMeta:
        _title.layout(BoxConstraints(maxWidth: width), parentUsesSize: true);
        _meta.layout(BoxConstraints(maxWidth: width), parentUsesSize: true);
        place(_title, 0, 0);
        place(_meta, 0, _title.size.height);
        final top = _title.size.height + _meta.size.height;
        place(_trailing, width - trailing.width, top);
        size = constraints.constrain(Size(width, top + trailing.height));
    }
  }

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}

/// A state chip's words, or — where they would not fit whole — its short
/// form with the colour's dot: never cut off mid-word.
class OverviewChipFit extends MultiChildRenderObjectWidget {
  OverviewChipFit({required Widget full, required Widget short, super.key})
    : super(children: [full, short]);

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderOverviewChipFit();
}

class RenderOverviewChipFit extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _BlockParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _BlockParentData> {
  /// Whether the short form is drawn, as of the last layout.
  bool short = false;

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _BlockParentData) {
      child.parentData = _BlockParentData();
    }
  }

  RenderBox get _full => firstChild!;
  RenderBox get _short => lastChild!;
  RenderBox get _shown => short ? _short : _full;

  bool _shortAt(double width) =>
      _full.getMaxIntrinsicWidth(double.infinity) > width;

  @override
  double computeMinIntrinsicWidth(double height) =>
      _short.getMaxIntrinsicWidth(height);

  @override
  double computeMaxIntrinsicWidth(double height) =>
      _full.getMaxIntrinsicWidth(height);

  @override
  double computeMinIntrinsicHeight(double width) =>
      (_shortAt(width) ? _short : _full).getMinIntrinsicHeight(width);

  @override
  double computeMaxIntrinsicHeight(double width) =>
      (_shortAt(width) ? _short : _full).getMaxIntrinsicHeight(width);

  @override
  Size computeDryLayout(covariant BoxConstraints constraints) =>
      (_shortAt(constraints.maxWidth) ? _short : _full).getDryLayout(
        constraints.loosen(),
      );

  @override
  void performLayout() {
    short = _shortAt(constraints.maxWidth);
    final loose = constraints.loosen();
    _full.layout(loose, parentUsesSize: true);
    _short.layout(loose, parentUsesSize: true);
    size = constraints.constrain(_shown.size);
  }

  @override
  void paint(PaintingContext context, Offset offset) =>
      context.paintChild(_shown, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      _shown.hitTest(result, position: position);

  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) =>
      visitor(_shown);
}
