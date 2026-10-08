import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

/// A group's small heading in a [FactRow] list: the menus' group label.
class FactListHeader extends StatelessWidget {
  const FactListHeader(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      header: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          Insets.lg,
          Insets.md,
          Insets.lg,
          Insets.xxs,
        ),
        child: Text(
          label.toUpperCase(),
          style: theme.textTheme.labelSmall
              ?.merge(Chrome.groupLabel)
              .copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ),
    );
  }
}

/// **One fact or verb in a list**: a glyph, its label, and its [value] at the
/// row's end — or under the label, in line with it, once both do not fit
/// side by side. A picker is its own value, so it opens from the row; a verb
/// has [onTap] and no value, and a [chevron] when it opens something more.
///
/// A row whose [value] draws nothing, and takes no width, draws nothing
/// either: a fact with nothing to say is left out, not left blank. A row as
/// tall as a thumb needs under touch, as a menu row under a pointer.
class FactRow extends StatelessWidget {
  const FactRow({
    required this.icon,
    required this.label,
    this.value,
    this.leading,
    this.onTap,
    this.chevron = false,
    this.destructive = false,
    this.enabled = true,
    super.key,
  });

  final IconData icon;

  /// In [icon]'s place: an agent's logo.
  final Widget? leading;
  final String label;
  final Widget? value;
  final VoidCallback? onTap;
  final bool chevron;

  /// The label and glyph in the error colour: Stop.
  final bool destructive;

  /// False draws a verb that does not apply now in the muted tone, inert.
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final touch = UiDensity.of(context).isTouch;
    final ink = !enabled
        ? scheme.onSurfaceVariant
        : destructive
        ? scheme.error
        : scheme.onSurface;
    final value = this.value;
    Widget end = value ?? const SizedBox.shrink();
    if (chevron) {
      end = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ?value,
          if (value != null) const SizedBox(width: Insets.xs),
          Icon(
            AppIcons.caretRight,
            size: Chrome.iconSmall,
            color: scheme.onSurfaceVariant,
          ),
        ],
      );
    }
    final row = _FactRowLayout(
      collapses: value != null,
      minHeight: touch ? Touch.target : Chrome.menuRow,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: _glyph,
              child:
                  leading ??
                  Icon(
                    icon,
                    size: Chrome.icon,
                    color: destructive ? ink : scheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(width: _glyphGap),
            Flexible(
              child: Text(
                label,
                style: theme.textTheme.bodySmall?.copyWith(color: ink),
              ),
            ),
          ],
        ),
        end,
      ],
    );
    final padded = Padding(
      padding: const EdgeInsets.symmetric(horizontal: Insets.lg),
      child: row,
    );
    final onTap = enabled ? this.onTap : null;
    if (onTap == null) return padded;
    return MergeSemantics(
      child: Semantics(
        button: true,
        child: InkWell(onTap: onTap, child: padded),
      ),
    );
  }
}

const double _glyph = Chrome.icon;
const double _glyphGap = Insets.sm + Insets.xxs;

class _FactRowLayout extends MultiChildRenderObjectWidget {
  const _FactRowLayout({
    required this.collapses,
    required this.minHeight,
    required super.children,
  });

  final bool collapses;
  final double minHeight;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderFactRow(collapses, minHeight);

  @override
  void updateRenderObject(BuildContext context, RenderFactRow renderObject) =>
      renderObject
        ..collapses = collapses
        ..minHeight = minHeight;
}

class _FactParentData extends ContainerBoxParentData<RenderBox> {}

/// How a [FactRow] placed its value at the last layout.
enum FactRowArrangement { beside, under, hidden }

class RenderFactRow extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _FactParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _FactParentData> {
  RenderFactRow(this._collapses, this._minHeight);

  bool _collapses;
  set collapses(bool value) {
    if (value == _collapses) return;
    _collapses = value;
    markNeedsLayout();
  }

  double _minHeight;
  set minHeight(double value) {
    if (value == _minHeight) return;
    _minHeight = value;
    markNeedsLayout();
  }

  static const _gap = Insets.md;
  static const _indent = _glyph + _glyphGap;
  static const _pad = Insets.xs;

  /// For tests: where the value went.
  FactRowArrangement arrangement = FactRowArrangement.beside;

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _FactParentData) {
      child.parentData = _FactParentData();
    }
  }

  RenderBox get _head => firstChild!;
  RenderBox get _value => lastChild!;

  void _place(RenderBox child, double x, double y) =>
      (child.parentData! as _FactParentData).offset = Offset(x, y);

  @override
  void performLayout() {
    final width = constraints.maxWidth;
    _value.layout(BoxConstraints(maxWidth: width), parentUsesSize: true);
    if (_collapses && _value.size.width == 0) {
      arrangement = FactRowArrangement.hidden;
      _head.layout(BoxConstraints(maxWidth: width), parentUsesSize: true);
      size = constraints.constrain(Size(width, 0));
      return;
    }
    var value = _value.size;
    // A verb's chevron or spinner stays at the end; its label wraps instead.
    final room = _collapses || value.width == 0
        ? width
        : math.max(0.0, width - value.width - _gap);
    _head.layout(BoxConstraints(maxWidth: room), parentUsesSize: true);
    final head = _head.size;
    if (!_collapses || head.width + _gap + value.width <= width) {
      arrangement = FactRowArrangement.beside;
      final line = math.max(head.height, value.height);
      final height = math.max(_minHeight, line + _pad * 2);
      _place(_head, 0, (height - head.height) / 2);
      _place(_value, width - value.width, (height - value.height) / 2);
      size = constraints.constrain(Size(width, height));
      return;
    }
    arrangement = FactRowArrangement.under;
    _value.layout(
      BoxConstraints(maxWidth: math.max(0, width - _indent)),
      parentUsesSize: true,
    );
    value = _value.size;
    final text = head.height + Insets.xxs + value.height;
    final height = math.max(_minHeight, text + _pad * 2);
    final top = (height - text) / 2;
    _place(_head, 0, top);
    _place(_value, _indent, top + head.height + Insets.xxs);
    size = constraints.constrain(Size(width, height));
  }

  @override
  double computeMinIntrinsicWidth(double height) => math.max(
    _head.getMinIntrinsicWidth(height),
    _indent + _value.getMinIntrinsicWidth(height),
  );

  @override
  double computeMaxIntrinsicWidth(double height) =>
      _head.getMaxIntrinsicWidth(height) +
      _gap +
      _value.getMaxIntrinsicWidth(height);

  @override
  double computeMinIntrinsicHeight(double width) => _minHeight;

  @override
  double computeMaxIntrinsicHeight(double width) => math.max(
    _minHeight,
    _head.getMaxIntrinsicHeight(width) +
        _value.getMaxIntrinsicHeight(width) +
        _pad * 2,
  );

  @override
  void paint(PaintingContext context, Offset offset) {
    if (arrangement == FactRowArrangement.hidden) return;
    defaultPaint(context, offset);
  }

  /// A shown row is one target, gap and all: a tap between the label and its
  /// value lands on the row, not on what is under the list.
  @override
  bool hitTestSelf(Offset position) => arrangement != FactRowArrangement.hidden;

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    if (arrangement == FactRowArrangement.hidden) return false;
    return defaultHitTestChildren(result, position: position);
  }

  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {
    if (arrangement == FactRowArrangement.hidden) return;
    super.visitChildrenForSemantics(visitor);
  }
}
