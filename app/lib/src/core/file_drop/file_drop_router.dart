import 'dart:io';
import 'dart:ui' show FlutterView;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_core/logging.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../capabilities/capabilities.dart';

final _log = AppLogger.named('file-drop');

/// The [FileDropZone]s alive in the window. The router hands a drop only to a
/// zone listed here, so a render object left behind by a disposed one is
/// never called.
class FileDropZones {
  final _zones = <_FileDropZoneState>{};

  int get length => _zones.length;

  void _add(_FileDropZoneState zone) => _zones.add(zone);

  void _remove(_FileDropZoneState zone) => _zones.remove(zone);

  bool _has(Object? zone) => _zones.contains(zone);
}

final fileDropZonesProvider = Provider<FileDropZones>((ref) => FileDropZones());

/// **The one listener for files dragged in from the OS.** Each event goes to
/// the single [FileDropZone] under the pointer, found by hit testing the
/// point as a click there would be.
///
/// It replaced a `DropTarget` per terminal pane. desktop_drop calls all of
/// its targets from one loop under one try/catch, so a single target that
/// threw — a pane in a hidden tab, a stale context — silently starved every
/// target after it (owner, 2026-10-01: drops on panes stopped working).
class FileDropRouter extends ConsumerStatefulWidget {
  const FileDropRouter({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<FileDropRouter> createState() => _FileDropRouterState();
}

class _FileDropRouterState extends ConsumerState<FileDropRouter> {
  late final FileDropZones _zones = ref.read(fileDropZonesProvider);
  bool _listening = false;
  FlutterView? _view;
  _FileDropZoneState? _hovered;

  @override
  void initState() {
    super.initState();
    _listen(ref.read(capabilitiesProvider).fileDrop);
    ref.listenManual(
      capabilitiesProvider.select((c) => c.fileDrop),
      (_, on) => _listen(on),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _view = View.maybeOf(context);
  }

  @override
  void dispose() {
    _listen(false);
    super.dispose();
  }

  void _listen(bool on) {
    if (on == _listening) return;
    _listening = on;
    if (on) {
      DesktopDrop.instance.init();
      DesktopDrop.instance.addRawDropEventListener(_onRawEvent);
      _log.info('Listening for files dropped from the OS.');
    } else {
      DesktopDrop.instance.removeRawDropEventListener(_onRawEvent);
      _hover(null, log: false);
    }
  }

  /// Never throws: desktop_drop's loop is shared, and anything thrown here
  /// would be swallowed there with only a debugPrint.
  void _onRawEvent(DropEvent event) {
    try {
      _route(event);
    } on Object catch (error, stack) {
      _log.warning('A file drop event could not be routed.', error, stack);
    }
  }

  void _route(DropEvent event) {
    final view = _view;
    if (!mounted || view == null) {
      _log.info('$event arrived with no window to place it in.');
      return;
    }
    // Windows reports physical pixels; macOS and Linux logical ones.
    final point = Platform.isWindows
        ? event.location / view.devicePixelRatio
        : event.location;
    final at = '(${point.dx.round()}, ${point.dy.round()})';
    if (event is DropEnterEvent) {
      _log.info(
        'Files dragged into the window at $at; '
        '${_zones.length} drop zone(s) open.',
      );
      _hover(_zoneAt(point, view));
    } else if (event is DropUpdateEvent) {
      _hover(_zoneAt(point, view));
    } else if (event is DropExitEvent) {
      _log.info('The drag left the window.');
      _hover(null, log: false);
    } else if (event is DropDoneEvent) {
      _hover(null, log: false);
      final paths = [for (final file in event.files) file.path];
      final zone = _zoneAt(point, view);
      _log.info(
        '${paths.length} item(s) dropped at $at: '
        '${zone == null ? 'no drop zone there, ignored' : 'to ${zone.widget.name}'}.',
      );
      if (zone == null || paths.isEmpty) return;
      try {
        zone.widget.onFiles(paths);
      } on Object catch (error, stack) {
        _log.warning(
          '${zone.widget.name} failed to take a drop.',
          error,
          stack,
        );
      }
    }
  }

  /// The innermost zone a click at [point] would reach. Hit testing is what
  /// leaves out every zone not actually on screen: an [Offstage] child, an
  /// [IndexedStack]'s hidden ones (it hit tests only the child it shows), and
  /// whatever a dialog's barrier covers — the overlapping panes of hidden
  /// tabs among them.
  _FileDropZoneState? _zoneAt(Offset point, FlutterView view) {
    final result = HitTestResult();
    WidgetsBinding.instance.hitTestInView(result, point, view.viewId);
    for (final entry in result.path) {
      final target = entry.target;
      if (target is! RenderMetaData) continue;
      final zone = target.metaData;
      if (zone is! _FileDropZoneState) continue;
      try {
        if (_zones._has(zone) && zone._live) return zone;
      } on Object catch (error, stack) {
        _log.warning('A drop zone could not be checked.', error, stack);
      }
    }
    return null;
  }

  void _hover(_FileDropZoneState? zone, {bool log = true}) {
    final was = _hovered;
    if (identical(was, zone)) return;
    _hovered = zone;
    for (final (target, over) in [(was, false), (zone, true)]) {
      if (target == null) continue;
      try {
        target._hover(over);
      } on Object catch (error, stack) {
        _log.warning('A drop zone could not be highlighted.', error, stack);
      }
    }
    if (log) {
      _log.info(
        zone == null ? 'Over no drop zone.' : 'Over ${zone.widget.name}.',
      );
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// A region that takes files dropped from the OS, through the
/// [FileDropRouter]. [builder] draws it, told whether a drag is over it.
class FileDropZone extends ConsumerStatefulWidget {
  const FileDropZone({
    required this.name,
    required this.onFiles,
    required this.builder,
    super.key,
  });

  /// How the log names it: "terminal pane …", "chat …".
  final String name;

  /// The dropped paths, on this machine.
  final ValueChanged<List<String>> onFiles;

  final Widget Function(BuildContext context, bool hovering) builder;

  @override
  ConsumerState<FileDropZone> createState() => _FileDropZoneState();
}

class _FileDropZoneState extends ConsumerState<FileDropZone> {
  // Held, not read in dispose: `ref` is unusable by then.
  late final FileDropZones _zones;
  final _hovering = ValueNotifier<bool>(false);

  @override
  void initState() {
    super.initState();
    _zones = ref.read(fileDropZonesProvider).._add(this);
  }

  @override
  void dispose() {
    _zones._remove(this);
    _hovering.dispose();
    super.dispose();
  }

  bool get _live {
    if (!mounted) return false;
    final box = context.findRenderObject();
    return box is RenderBox && box.attached && box.hasSize;
  }

  void _hover(bool over) {
    if (mounted) _hovering.value = over;
  }

  @override
  Widget build(BuildContext context) => MetaData(
    metaData: this,
    // Recorded wherever the point is inside it, whatever its children say.
    behavior: HitTestBehavior.translucent,
    child: ValueListenableBuilder<bool>(
      valueListenable: _hovering,
      builder: (context, over, _) => widget.builder(context, over),
    ),
  );
}

/// The highlight over a zone a drag is over: a tinted, outlined box with
/// [label] in a pill at its centre. Draws nothing when not [visible].
class FileDropHighlight extends StatelessWidget {
  const FileDropHighlight({
    required this.label,
    required this.visible,
    required this.child,
    super.key,
  });

  final String label;
  final bool visible;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Stack(
      children: [
        Positioned.fill(child: child),
        if (visible)
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: StateLayers.dropTarget(theme.colorScheme),
                  border: Border.all(
                    color: theme.colorScheme.primary,
                    width: 2,
                  ),
                ),
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: Insets.sm,
                      vertical: Insets.xs,
                    ),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary,
                      borderRadius: BorderRadius.circular(Radii.sm),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          AppIcons.file,
                          size: Chrome.iconSmall,
                          color: theme.colorScheme.onPrimary,
                        ),
                        const SizedBox(width: Insets.xs),
                        Text(
                          label,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onPrimary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
