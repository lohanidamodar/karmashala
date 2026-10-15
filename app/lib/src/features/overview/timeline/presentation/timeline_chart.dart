import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:karmashala_ui/tokens.dart';

import '../domain/timeline_model.dart';
import 'timeline_avatar.dart';
import 'timeline_painters.dart';

/// Narrower than this, the lanes open on the last few hours rather than
/// the whole day's activity.
const double kTimelinePhoneWidth = 600;

/// How much a narrow Timeline shows when it opens on now.
const Duration kTimelineNarrowSpan = Duration(hours: 3);

/// What a Timeline [width] wide opens on: the hours up to now on a phone
/// when the range holds now, otherwise everything that happened, padded.
TimelineViewport timelineOpeningViewport(
  TimelineModel model, {
  required DateTime now,
  required double width,
}) {
  if (width < kTimelinePhoneWidth &&
      !now.isBefore(model.from) &&
      now.isBefore(model.to)) {
    const after = Duration(minutes: 15);
    return clampTimelineViewport(
      model,
      now.add(after).subtract(kTimelineNarrowSpan),
      kTimelineNarrowSpan,
    );
  }
  final active = model.activity();
  return TimelineViewport(start: active.from, end: active.to);
}

/// [start] for [span], kept inside the model's range.
TimelineViewport clampTimelineViewport(
  TimelineModel model,
  DateTime start,
  Duration span,
) {
  final whole = model.to.difference(model.from);
  final length = span > whole ? whole : span;
  var from = start;
  if (from.isBefore(model.from)) from = model.from;
  if (from.add(length).isAfter(model.to)) from = model.to.subtract(length);
  return TimelineViewport(start: from, end: from.add(length));
}

/// The toolbar's handle on the lanes: zoom, fit to what happened, jump to now.
class TimelineZoomController extends ChangeNotifier {
  double _factor = 1;
  int _fits = 0;
  int _nows = 0;

  void zoomIn() {
    _factor = 0.5;
    notifyListeners();
  }

  void zoomOut() {
    _factor = 2;
    notifyListeners();
  }

  void fit() {
    _fits++;
    _factor = 1;
    notifyListeners();
  }

  void now() {
    _nows++;
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
  const _Lane(this.session, {required this.children, required this.folded});
  final TimelineSession session;

  /// How many it started that are in the range, and how many of those are
  /// folded away.
  final int children;
  final int folded;
}

class _Hover {
  const _Hover(this.text, this.position);
  final String text;
  final Offset position;
}

/// **The Timeline's lanes**: time across the whole width, one lane per
/// session with its title on its bar and its avatar at its start, the
/// sub-sessions hanging off their parent on stems as on the dashboard's
/// tree. Lanes are built lazily, so a row off screen costs nothing per frame.
class TimelineChart extends StatefulWidget {
  const TimelineChart({
    required this.model,
    required this.now,
    required this.onSelect,
    this.selectedId,
    this.waitsOnly = false,
    this.agentName,
    this.controller,
    super.key,
  });

  final TimelineModel model;
  final DateTime now;

  /// A lane was tapped: show what it did.
  final void Function(TimelineSession session) onSelect;
  final String? selectedId;

  /// Fade everything but the waits on the owner.
  final bool waitsOnly;

  /// The agent's name for an agent id, as the app says it.
  final String Function(String agentId)? agentName;

  /// Zoom from outside (the toolbar's buttons).
  final TimelineZoomController? controller;

  /// The axis band's least height; it grows with the text scale.
  static const double axisHeight = Chrome.paneStrip;

  @override
  State<TimelineChart> createState() => _TimelineChartState();
}

class _TimelineChartState extends State<TimelineChart> {
  final _scroll = ScrollController();
  final _folded = <String>{};
  final _hover = ValueNotifier<_Hover?>(null);
  final _stack = GlobalKey();
  TimelineViewport? _viewport;
  double _width = 0;
  int _fits = 0;
  int _nows = 0;

  @override
  void initState() {
    super.initState();
    widget.controller?.addListener(_onZoom);
  }

  @override
  void didUpdateWidget(TimelineChart old) {
    super.didUpdateWidget(old);
    if (old.model.from != widget.model.from ||
        old.model.to != widget.model.to) {
      _viewport = null;
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

  TimelineViewport get _shown => _viewport ??= timelineOpeningViewport(
    widget.model,
    now: widget.now,
    width: _width,
  );

  void _onZoom() {
    final controller = widget.controller!;
    if (controller._fits != _fits) {
      _fits = controller._fits;
      final active = widget.model.activity();
      setState(
        () => _viewport = TimelineViewport(start: active.from, end: active.to),
      );
      return;
    }
    if (controller._nows != _nows) {
      _nows = controller._nows;
      // Now near the right edge, keeping the zoom.
      final span = _shown.span;
      setState(
        () => _viewport = clampTimelineViewport(
          widget.model,
          widget.now.subtract(span * 0.85),
          span,
        ),
      );
      return;
    }
    _zoom(controller._factor, 0.5);
  }

  void _zoom(double factor, double anchor) {
    final whole = widget.model.to.difference(widget.model.from);
    final span = _shown.span;
    final next = Duration(
      microseconds: (span.inMicroseconds * factor)
          .clamp(
            const Duration(minutes: 10).inMicroseconds,
            whole.inMicroseconds,
          )
          .round(),
    );
    final pivot = _shown.start.add(
      Duration(microseconds: (span.inMicroseconds * anchor).round()),
    );
    final start = pivot.subtract(
      Duration(microseconds: (next.inMicroseconds * anchor).round()),
    );
    setState(
      () => _viewport = clampTimelineViewport(widget.model, start, next),
    );
  }

  void _pan(double dx, double width) {
    if (width <= 0) return;
    final span = _shown.span;
    final shift = Duration(
      microseconds: (dx / width * span.inMicroseconds).round(),
    );
    setState(
      () => _viewport = clampTimelineViewport(
        widget.model,
        _shown.start.add(shift),
        span,
      ),
    );
  }

  List<_Item> _items() {
    final items = <_Item>[];
    for (final project in widget.model.projects) {
      items.add(_Header(project));
      final kids = <String, int>{};
      for (final session in project.sessions) {
        if (session.parentId case final parent?) {
          kids[parent] = (kids[parent] ?? 0) + 1;
        }
      }
      final hidden = <String>{};
      for (final session in project.sessions) {
        final parent = session.parentId;
        if (parent != null &&
            (hidden.contains(parent) || _folded.contains(parent))) {
          hidden.add(session.id);
          continue;
        }
        final children = kids[session.id] ?? 0;
        items.add(
          _Lane(
            session,
            children: children,
            folded: _folded.contains(session.id) ? children : 0,
          ),
        );
      }
    }
    return items;
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
    final title = TextPainter(
      text: TextSpan(text: 'Ag', style: palette.title),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
    )..layout();
    final titleHeight = title.height;
    title.dispose();
    final headerHeight = Chrome.tabStripOf(context);
    final items = _items();
    double extent(_Item item) => switch (item) {
      _Header() => headerHeight,
      _Lane(:final session) => TimelineRowLayout.heightFor(
        session,
        titleHeight,
      ),
    };
    return LayoutBuilder(
      key: const ValueKey('timeline-chart'),
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        _width = width;
        final viewport = _shown;
        final laneWidth = math.max(
          1.0,
          width - Chrome.timelineGutter - Insets.lg,
        );
        final stems = _stems(items, extent, viewport, width);
        return Stack(
          key: _stack,
          children: [
            Column(
              children: [
                SizedBox(
                  key: const ValueKey('timeline-axis'),
                  height: axisHeight,
                  width: width,
                  child: CustomPaint(
                    painter: TimelineAxisPainter(
                      viewport: viewport,
                      palette: palette,
                      now: widget.now,
                      left: Chrome.timelineGutter,
                      right: Insets.lg,
                      textScaler: scaler,
                    ),
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    controller: _scroll,
                    itemCount: items.length,
                    itemExtentBuilder: (index, _) =>
                        index < items.length ? extent(items[index]) : null,
                    itemBuilder: (context, index) => switch (items[index]) {
                      _Header(:final project) => _ProjectHeader(
                        project: project,
                      ),
                      _Lane(:final session, :final children, :final folded) =>
                        _LaneRow(
                          key: ValueKey('timeline-lane-${session.id}'),
                          session: session,
                          children: children,
                          folded: folded,
                          selected: session.id == widget.selectedId,
                          waitsOnly: widget.waitsOnly,
                          agentName: switch ((
                            session.agent,
                            widget.agentName,
                          )) {
                            (final id?, final name?) => name(id),
                            _ => null,
                          },
                          viewport: viewport,
                          palette: palette,
                          now: widget.now,
                          onFold: () => setState(() {
                            if (!_folded.remove(session.id)) {
                              _folded.add(session.id);
                            }
                          }),
                          onSelect: () => widget.onSelect(session),
                          onSignal: (event, x) => _signal(event, laneWidth, x),
                          onPan: (dx) => _pan(dx, laneWidth),
                          onPinch: (scale, x) =>
                              _zoom(1 / scale, (x / laneWidth).clamp(0, 1)),
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
                size: Size(width, constraints.maxHeight),
                painter: TimelineStemPainter(
                  stems: stems,
                  palette: palette,
                  scroll: _scroll,
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
                  math.max(0.0, width - DialogWidth.popover - Insets.lg),
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

  /// Each shown sub-session's stem, from its parent's bar (or its avatar,
  /// when both sit stuck at the left edge) down to its own avatar.
  List<TimelineStem> _stems(
    List<_Item> items,
    double Function(_Item item) extent,
    TimelineViewport viewport,
    double width,
  ) {
    final rows = <String, ({double y, TimelineRowLayout layout})>{};
    final stems = <TimelineStem>[];
    var y = 0.0;
    for (final item in items) {
      final height = extent(item);
      if (item is _Lane) {
        final session = item.session;
        final layout = TimelineRowLayout.of(
          session,
          viewport,
          width: width,
          height: height,
        );
        rows[session.id] = (y: y, layout: layout);
        if (rows[session.parentId] case final parent?) {
          final x = layout.avatar.center.dx;
          final fromAvatar =
              x < parent.layout.laneLeft || x <= parent.layout.avatar.right;
          stems.add(
            TimelineStem(
              x: x,
              top:
                  parent.y +
                  (fromAvatar
                      ? parent.layout.avatar.bottom
                      : parent.layout.barBottom),
              bottom: y + layout.avatar.top,
            ),
          );
        }
      }
      y += height;
    }
    return stems;
  }
}

class _ProjectHeader extends StatelessWidget {
  const _ProjectHeader({required this.project});

  final TimelineProject project;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sessions = project.sessions;
    final live = sessions.where((s) => s.live).length;
    final waiting = sessions
        .where((s) => s.stateNow == TimelineState.waiting)
        .length;
    final facts = [
      '${sessions.length} ${sessions.length == 1 ? 'session' : 'sessions'}',
      if (live > 0) '$live live',
      if (waiting > 0) '$waiting waiting on you',
    ].join(' · ');
    return Semantics(
      header: true,
      child: Container(
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: Insets.lg),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerLow,
          border: Border(
            top: BorderSide(color: theme.colorScheme.outlineVariant),
          ),
        ),
        child: Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: project.name,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              TextSpan(
                text: ' · $facts',
                style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ),
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: DialogWidth.popover),
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

String _clock(DateTime at) {
  final local = at.toLocal();
  return '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}';
}

/// What a screen reader hears for a session's lane.
String describeSession(TimelineSession session) {
  final parts = <String>[
    session.title,
    session.projectName,
    if (session.startOnly)
      'started ${_clock(session.start)}, nothing more recorded'
    else
      '${_clock(session.start)} to '
          '${session.live ? 'now' : _clock(session.end)}',
    if (session.stateNow == TimelineState.waiting) 'waiting on you now',
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
    required this.children,
    required this.folded,
    required this.selected,
    required this.waitsOnly,
    required this.agentName,
    required this.viewport,
    required this.palette,
    required this.now,
    required this.onFold,
    required this.onSelect,
    required this.onSignal,
    required this.onPan,
    required this.onPinch,
    required this.onHover,
    super.key,
  });

  final TimelineSession session;
  final int children;
  final int folded;
  final bool selected;
  final bool waitsOnly;
  final String? agentName;
  final TimelineViewport viewport;
  final TimelinePalette palette;
  final DateTime now;
  final VoidCallback onFold;
  final VoidCallback onSelect;
  final void Function(PointerSignalEvent event, double x) onSignal;
  final void Function(double dx) onPan;
  final void Function(double scale, double x) onPinch;
  final void Function(String? text, Offset global) onHover;

  String? _hoverText(TimelineRowLayout layout, double x) {
    if (x < layout.laneLeft || x > layout.laneRight) return null;
    final at = viewport.timeAt(
      x - layout.laneLeft,
      layout.laneRight - layout.laneLeft,
    );
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
    final scaler = MediaQuery.textScalerOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        final layout = TimelineRowLayout.of(
          session,
          viewport,
          width: size.width,
          height: size.height,
        );
        final avatar = TimelineAvatar(
          session: session,
          size: layout.avatar.width,
        );
        return Stack(
          children: [
            Positioned.fill(
              child: Semantics(
                container: true,
                button: true,
                selected: selected,
                label: describeSession(session),
                onTap: onSelect,
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  onHover: (event) => onHover(
                    _hoverText(layout, event.localPosition.dx),
                    event.position,
                  ),
                  onExit: (event) => onHover(null, event.position),
                  child: Listener(
                    onPointerSignal: (event) => onSignal(
                      event,
                      event.localPosition.dx - layout.laneLeft,
                    ),
                    onPointerPanZoomUpdate: (event) {
                      if (event.scale != 1) {
                        onPinch(
                          event.scale,
                          event.localPosition.dx - layout.laneLeft,
                        );
                      } else if (event.panDelta.dx != 0) {
                        onPan(-event.panDelta.dx);
                      }
                    },
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: onSelect,
                      onHorizontalDragUpdate: (details) =>
                          onPan(-details.delta.dx),
                      child: CustomPaint(
                        size: size,
                        painter: TimelineRowPainter(
                          session: session,
                          viewport: viewport,
                          palette: palette,
                          now: now,
                          selected: selected,
                          waitsOnly: waitsOnly,
                          folded: folded,
                          agentName: agentName,
                          textScaler: scaler,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Positioned.fromRect(
              rect: layout.avatar,
              child: children == 0
                  ? IgnorePointer(child: avatar)
                  : Semantics(
                      container: true,
                      button: true,
                      onTap: onFold,
                      label: folded > 0
                          ? 'Show what ${session.title} started'
                          : 'Hide what ${session.title} started',
                      child: Tooltip(
                        message: folded > 0
                            ? 'Show $children sub-sessions'
                            : 'Fold $children sub-sessions',
                        child: InkResponse(
                          key: ValueKey('timeline-fold-${session.id}'),
                          onTap: onFold,
                          radius: layout.avatar.width,
                          child: avatar,
                        ),
                      ),
                    ),
            ),
          ],
        );
      },
    );
  }
}
