// The peek row's layout and its Chat / Terminal / Files switch.
part of '../overview_peek.dart';

/// The width, at 1x text, from which Stop and Open carry their words.
const double _peekLabelsFrom = 560;

/// The title, the views and the controls on one line: the title keeps
/// [titleFloor] — or its whole width, when shorter — before the controls
/// take the rest; the views are never left out, and the title gives up what
/// they need below that. The title is left; the views and the controls end
/// the line.
class _PeekLine extends MultiChildRenderObjectWidget {
  const _PeekLine({required this.titleFloor, required super.children});

  final double titleFloor;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderPeekLine(titleFloor);

  @override
  void updateRenderObject(BuildContext context, _RenderPeekLine renderObject) =>
      renderObject.titleFloor = titleFloor;
}

class _PeekLineParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderPeekLine extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _PeekLineParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _PeekLineParentData> {
  _RenderPeekLine(this._titleFloor);

  double _titleFloor;
  set titleFloor(double value) {
    if (value == _titleFloor) return;
    _titleFloor = value;
    markNeedsLayout();
  }

  static const _gap = Insets.sm;

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _PeekLineParentData) {
      child.parentData = _PeekLineParentData();
    }
  }

  RenderBox get _title => firstChild!;
  RenderBox get _views => childAfter(_title)!;
  RenderBox get _controls => lastChild!;

  @override
  void performLayout() {
    final width = constraints.maxWidth;
    _views.layout(BoxConstraints(maxWidth: width), parentUsesSize: true);
    final views = _views.size.width;
    final keep = math.min(
      _title.getMaxIntrinsicWidth(double.infinity),
      _titleFloor,
    );
    final room = math.max(0.0, width - views - _gap);
    final budget = math.max(0.0, room - keep - _gap);
    _controls.layout(BoxConstraints(maxWidth: budget), parentUsesSize: true);
    final controls = _controls.size.width;
    final ends = views + (controls > 0 ? _gap + controls : 0);
    final titleWidth = math.max(0.0, width - ends - _gap);
    _title.layout(BoxConstraints(maxWidth: titleWidth), parentUsesSize: true);
    final height = math.max(
      _title.size.height,
      math.max(_views.size.height, _controls.size.height),
    );
    void place(RenderBox child, double x) =>
        (child.parentData! as _PeekLineParentData).offset = Offset(
          x,
          (height - child.size.height) / 2,
        );
    place(_title, 0);
    place(_views, width - ends);
    place(_controls, width - controls);
    size = constraints.constrain(Size(width, height));
  }

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}

/// **Chat / Terminal / Files** — and, on a desktop, the sub-sessions — as
/// round 59's compact switch: glyphs, the changed files and the sub-sessions
/// counted beside theirs. Each keeps its name as tooltip and semantics label.
/// A view the session lacks is not offered.
class _PeekViewSwitch extends StatelessWidget {
  const _PeekViewSwitch({
    required this.tabs,
    required this.selected,
    required this.files,
    required this.subSessions,
    required this.touch,
    required this.onChanged,
  });

  final List<OverviewPeekTab> tabs;
  final OverviewPeekTab selected;
  final int files;
  final int subSessions;
  final bool touch;
  final ValueChanged<OverviewPeekTab> onChanged;

  @override
  Widget build(BuildContext context) => ViewSwitch<OverviewPeekTab>(
    key: const ValueKey('overview-peek-tabs'),
    touch: touch,
    selected: selected,
    onChanged: onChanged,
    segments: [
      for (final t in tabs)
        switch (t) {
          OverviewPeekTab.chat => const ViewSwitchSegment(
            key: ValueKey('overview-peek-tab:chat'),
            value: OverviewPeekTab.chat,
            icon: AppIcons.chatCircle,
            label: 'Chat',
            tooltip: 'Chat',
          ),
          OverviewPeekTab.terminal => const ViewSwitchSegment(
            key: ValueKey('overview-peek-tab:terminal'),
            value: OverviewPeekTab.terminal,
            icon: AppIcons.terminal,
            label: 'Terminal',
            tooltip: 'Terminal',
          ),
          OverviewPeekTab.files => ViewSwitchSegment(
            key: const ValueKey('overview-peek-tab:files'),
            value: OverviewPeekTab.files,
            icon: AppIcons.folderOpen,
            label: 'Files',
            tooltip: files == 0 ? 'Files' : 'Files · $files changed',
            badge: files == 0 ? null : '$files',
          ),
          OverviewPeekTab.subSessions => ViewSwitchSegment(
            key: const ValueKey('overview-peek-tab:subSessions'),
            value: OverviewPeekTab.subSessions,
            icon: AppIcons.treeStructure,
            label: 'Sub-sessions',
            tooltip: 'Sub-sessions · $subSessions',
            badge: subSessions == 0 ? null : '$subSessions',
          ),
        },
    ],
  );
}
