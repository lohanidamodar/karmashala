import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../domain/timeline_model.dart';
import 'timeline_painters.dart';

/// The desktop timeline: time across, projects as rows, each session a bar.
/// Lanes are built lazily, so a row off screen costs nothing per frame.
class TimelineChart extends StatefulWidget {
  const TimelineChart({
    required this.model,
    required this.now,
    required this.onOpen,
    this.controller,
    super.key,
  });

  final TimelineModel model;
  final DateTime now;
  final void Function(TimelineSession session) onOpen;

  /// Zoom from outside (the toolbar's buttons).
  final TimelineZoomController? controller;

  /// The session-name column; no chart token says it yet.
  static const double labelWidth = 240;

  /// The axis band's least height; the band grows with the text scale
  /// (`TimelineAxisPainter.heightFor`).
  static const double axisHeight = Chrome.paneStrip;
  static const double headerHeight = Chrome.tabStrip;
  static const double laneHeight = Insets.xl + Insets.xs;

  @override
  State<TimelineChart> createState() => _TimelineChartState();
}

/// The toolbar's handle on the chart's zoom.
class TimelineZoomController extends ChangeNotifier {
  double _factor = 1;
  int _fit = 0;

  double get pendingFactor => _factor;

  void zoomIn() {
    _factor = 0.5;
    notifyListeners();
  }

  void zoomOut() {
    _factor = 2;
    notifyListeners();
  }

  void fit() {
    _fit++;
    _factor = 1;
    notifyListeners();
  }
}

sealed class _Item {
  const _Item();
}

class _Header extends _Item {
  const _Header(this.project);
  final TimelineProject project;
}

class _Lane extends _Item {
  const _Lane(this.session, {required this.hasChildren});
  final TimelineSession session;
  final bool hasChildren;
}

class _Hover {
  const _Hover(this.text, this.position);
  final String text;
  final Offset position;
}

class _TimelineChartState extends State<TimelineChart> {
  final _scroll = ScrollController();
  final _folded = <String>{};
  final _hover = ValueNotifier<_Hover?>(null);
  final _stack = GlobalKey();
  late TimelineViewport _viewport;
  int _fits = 0;

  @override
  void initState() {
    super.initState();
    _viewport = _whole;
    widget.controller?.addListener(_onZoom);
  }

  TimelineViewport get _whole =>
      TimelineViewport(start: widget.model.from, end: widget.model.to);

  @override
  void didUpdateWidget(TimelineChart old) {
    super.didUpdateWidget(old);
    if (old.model.from != widget.model.from ||
        old.model.to != widget.model.to) {
      _viewport = _whole;
    }
    if (old.controller != widget.controller) {
      old.controller?.removeListener(_onZoom);
      widget.controller?.addListener(_onZoom);
    }
  }

  @override
  void dispose() {
    widget.controller?.removeListener(_onZoom);
    _scroll.dispose();
    _hover.dispose();
    super.dispose();
  }

  void _onZoom() {
    final controller = widget.controller!;
    if (controller._fit != _fits) {
      _fits = controller._fit;
      setState(() => _viewport = _whole);
      return;
    }
    _zoom(controller.pendingFactor, 0.5);
  }

  void _zoom(double factor, double anchor) {
    final whole = widget.model.to.difference(widget.model.from);
    final span = _viewport.end.difference(_viewport.start);
    final next = Duration(
      microseconds: (span.inMicroseconds * factor)
          .clamp(
            const Duration(minutes: 10).inMicroseconds,
            whole.inMicroseconds,
          )
          .round(),
    );
    final pivot = _viewport.start.add(
      Duration(microseconds: (span.inMicroseconds * anchor).round()),
    );
    final start = pivot.subtract(
      Duration(microseconds: (next.inMicroseconds * anchor).round()),
    );
    setState(() => _viewport = _clamped(start, next));
  }

  void _pan(double dx, double width) {
    if (width <= 0) return;
    final span = _viewport.end.difference(_viewport.start);
    final shift = Duration(
      microseconds: (dx / width * span.inMicroseconds).round(),
    );
    setState(() => _viewport = _clamped(_viewport.start.add(shift), span));
  }

  TimelineViewport _clamped(DateTime start, Duration span) {
    var from = start;
    if (from.isBefore(widget.model.from)) from = widget.model.from;
    if (from.add(span).isAfter(widget.model.to)) {
      from = widget.model.to.subtract(span);
    }
    return TimelineViewport(start: from, end: from.add(span));
  }

  List<_Item> _items() {
    final items = <_Item>[];
    for (final project in widget.model.projects) {
      items.add(_Header(project));
      final parents = {for (final s in project.sessions) s.parentId};
      final hidden = <String>{};
      for (final session in project.sessions) {
        final parent = session.parentId;
        if (parent != null &&
            (hidden.contains(parent) || _folded.contains(parent))) {
          hidden.add(session.id);
          continue;
        }
        items.add(_Lane(session, hasChildren: parents.contains(session.id)));
      }
    }
    return items;
  }

  double _extent(_Item item) => switch (item) {
    _Header() => TimelineChart.headerHeight,
    _Lane() => TimelineChart.laneHeight,
  };

  List<TimelineArrowLine> _arrows(List<_Item> items) {
    final centers = <String, double>{};
    var y = 0.0;
    for (final item in items) {
      final extent = _extent(item);
      if (item is _Lane) centers[item.session.id] = y + extent / 2;
      y += extent;
    }
    return [
      for (final arrow in widget.model.arrows)
        if (centers[arrow.parentId] case final parentY?)
          if (centers[arrow.childId] case final childY?)
            TimelineArrowLine(parentY: parentY, childY: childY, at: arrow.at),
    ];
  }

  void _signal(PointerSignalEvent event, double width, double x) {
    if (event is! PointerScrollEvent) return;
    final keys = HardwareKeyboard.instance;
    if (keys.isControlPressed || keys.isMetaPressed) {
      GestureBinding.instance.pointerSignalResolver.register(event, (_) {
        _zoom(math.exp(event.scrollDelta.dy / 400), (x / width).clamp(0, 1));
      });
    } else if (keys.isShiftPressed || event.scrollDelta.dx != 0) {
      GestureBinding.instance.pointerSignalResolver.register(event, (_) {
        _pan(
          event.scrollDelta.dx != 0
              ? event.scrollDelta.dx
              : event.scrollDelta.dy,
          width,
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = TimelinePalette.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    final axisHeight = TimelineAxisPainter.heightFor(
      scaler,
      style: palette.axisDay,
      minimum: TimelineChart.axisHeight,
    );
    final items = _items();
    final arrows = _arrows(items);
    return LayoutBuilder(
      key: const ValueKey('timeline-chart'),
      builder: (context, constraints) {
        final barWidth = math.max(
          1.0,
          constraints.maxWidth - TimelineChart.labelWidth,
        );
        return Stack(
          key: _stack,
          children: [
            Column(
              children: [
                SizedBox(
                  key: const ValueKey('timeline-axis'),
                  height: axisHeight,
                  child: Row(
                    children: [
                      const SizedBox(width: TimelineChart.labelWidth),
                      Expanded(
                        child: CustomPaint(
                          painter: TimelineAxisPainter(
                            viewport: _viewport,
                            palette: palette,
                            now: widget.now,
                            textScaler: scaler,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    controller: _scroll,
                    itemCount: items.length,
                    itemExtentBuilder: (index, _) =>
                        index < items.length ? _extent(items[index]) : null,
                    itemBuilder: (context, index) => switch (items[index]) {
                      _Header(:final project) => _ProjectHeader(
                        project: project,
                      ),
                      _Lane(:final session, :final hasChildren) => _LaneRow(
                        key: ValueKey('timeline-lane-${session.id}'),
                        session: session,
                        hasChildren: hasChildren,
                        folded: _folded.contains(session.id),
                        viewport: _viewport,
                        palette: palette,
                        now: widget.now,
                        onFold: () => setState(() {
                          if (!_folded.remove(session.id)) {
                            _folded.add(session.id);
                          }
                        }),
                        onOpen: () => widget.onOpen(session),
                        onSignal: (event, x) => _signal(event, barWidth, x),
                        onPan: (dx) => _pan(dx, barWidth),
                        onPinch: (scale, x) =>
                            _zoom(1 / scale, (x / barWidth).clamp(0, 1)),
                        onHover: (text, global) {
                          final box =
                              _stack.currentContext?.findRenderObject()
                                  as RenderBox?;
                          _hover.value = text == null || box == null
                              ? null
                              : _Hover(text, box.globalToLocal(global));
                        },
                      ),
                    },
                  ),
                ),
              ],
            ),
            IgnorePointer(
              child: CustomPaint(
                size: Size(constraints.maxWidth, constraints.maxHeight),
                painter: TimelineArrowPainter(
                  arrows: arrows,
                  viewport: _viewport,
                  palette: palette,
                  scroll: _scroll,
                  left: TimelineChart.labelWidth,
                  top: axisHeight,
                ),
              ),
            ),
            ValueListenableBuilder<_Hover?>(
              valueListenable: _hover,
              builder: (context, hover, _) {
                if (hover == null) return const SizedBox.shrink();
                final left = math.min(
                  hover.position.dx + Insets.md,
                  math.max(
                    0.0,
                    constraints.maxWidth - _HoverCard.maxWidth - Insets.lg,
                  ),
                );
                return Positioned(
                  left: left,
                  top: hover.position.dy + Insets.md,
                  child: IgnorePointer(child: _HoverCard(text: hover.text)),
                );
              },
            ),
          ],
        );
      },
    );
  }
}

class _ProjectHeader extends StatelessWidget {
  const _ProjectHeader({required this.project});

  final TimelineProject project;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      header: true,
      child: Container(
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: Insets.sm),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerLow,
          border: Border(
            top: BorderSide(color: theme.colorScheme.outlineVariant),
          ),
        ),
        child: Text(
          '${project.name} · ${project.sessions.length} '
          '${project.sessions.length == 1 ? 'session' : 'sessions'}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.labelLarge,
        ),
      ),
    );
  }
}

class _HoverCard extends StatelessWidget {
  const _HoverCard({required this.text});

  final String text;

  /// The widest a hover card is drawn; no chart token says it yet.
  static const double maxWidth = 300;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: maxWidth),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colorScheme.inverseSurface,
          borderRadius: BorderRadius.circular(Radii.sm),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Insets.sm,
            vertical: Insets.xs,
          ),
          child: Text(
            text,
            key: const ValueKey('timeline-hover'),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onInverseSurface,
            ),
          ),
        ),
      ),
    );
  }
}

/// What a screen reader hears for a session's bar.
String describeSession(TimelineSession session) {
  String clock(DateTime at) {
    final local = at.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }

  final parts = <String>[
    session.title,
    session.projectName,
    if (session.startOnly)
      'started ${clock(session.start)}, nothing more recorded'
    else
      '${clock(session.start)} to '
          '${session.live ? 'now' : clock(session.end)}',
    if (session.workingTotal > Duration.zero)
      'working ${describeDuration(session.workingTotal)}',
    if (session.waitingTotal > Duration.zero)
      'waiting on you ${describeDuration(session.waitingTotal)}',
    if (session.ticks.isNotEmpty)
      '${session.ticks.length} ${session.ticks.length == 1 ? 'turn' : 'turns'}',
    if (session.deleted) 'deleted',
    if (session.backfilled) 'recovered from earlier records',
  ];
  return parts.join(', ');
}

class _LaneRow extends StatelessWidget {
  const _LaneRow({
    required this.session,
    required this.hasChildren,
    required this.folded,
    required this.viewport,
    required this.palette,
    required this.now,
    required this.onFold,
    required this.onOpen,
    required this.onSignal,
    required this.onPan,
    required this.onPinch,
    required this.onHover,
    super.key,
  });

  final TimelineSession session;
  final bool hasChildren;
  final bool folded;
  final TimelineViewport viewport;
  final TimelinePalette palette;
  final DateTime now;
  final VoidCallback onFold;
  final VoidCallback onOpen;
  final void Function(PointerSignalEvent event, double x) onSignal;
  final void Function(double dx) onPan;
  final void Function(double scale, double x) onPinch;
  final void Function(String? text, Offset global) onHover;

  String? _hoverText(double x, double width) {
    final at = viewport.timeAt(x, width);
    for (final span in session.spans) {
      if (!at.isBefore(span.from) && at.isBefore(span.to)) {
        return '${session.title}: ${describeSpan(span)}';
      }
    }
    if (session.startOnly) {
      return '${session.title}: started, nothing more recorded';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    final opens = !session.deleted;
    return Row(
      children: [
        SizedBox(
          width: TimelineChart.labelWidth,
          child: Padding(
            padding: EdgeInsets.only(
              left: Insets.sm + session.depth * Insets.lg,
              right: Insets.xs,
            ),
            child: Row(
              children: [
                if (hasChildren)
                  InkWell(
                    onTap: onFold,
                    child: Semantics(
                      button: true,
                      label: folded
                          ? 'Show what ${session.title} started'
                          : 'Hide what ${session.title} started',
                      child: Icon(
                        folded ? AppIcons.caretRight : AppIcons.caretDown,
                        size: Chrome.iconAction,
                      ),
                    ),
                  )
                else
                  const SizedBox(width: Chrome.iconAction),
                const SizedBox(width: Insets.xs),
                Expanded(
                  child: Text(
                    session.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontStyle: session.backfilled ? FontStyle.italic : null,
                      decoration: session.deleted
                          ? TextDecoration.lineThrough
                          : null,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              return Semantics(
                button: opens,
                label: describeSession(session),
                onTap: opens ? onOpen : null,
                excludeSemantics: true,
                child: MouseRegion(
                  cursor: opens
                      ? SystemMouseCursors.click
                      : SystemMouseCursors.basic,
                  onHover: (event) => onHover(
                    _hoverText(event.localPosition.dx, width),
                    event.position,
                  ),
                  onExit: (event) => onHover(null, event.position),
                  child: Listener(
                    onPointerSignal: (event) =>
                        onSignal(event, event.localPosition.dx),
                    onPointerPanZoomUpdate: (event) {
                      if (event.scale != 1) {
                        onPinch(event.scale, event.localPosition.dx);
                      } else if (event.panDelta.dx != 0) {
                        onPan(-event.panDelta.dx);
                      }
                    },
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: opens ? onOpen : null,
                      onHorizontalDragUpdate: (details) =>
                          onPan(-details.delta.dx),
                      child: CustomPaint(
                        size: Size(width, TimelineChart.laneHeight),
                        painter: TimelineLanePainter(
                          session: session,
                          viewport: viewport,
                          palette: palette,
                          now: now,
                          textScaler: scaler,
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
