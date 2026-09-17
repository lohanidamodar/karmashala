import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/logs.dart';
import 'package:karmashala_ui/tokens.dart';
import '../application/device_ports.dart';
import '../application/device_logcat_session.dart';
import '../application/device_logcat_view.dart';
import '../../devices.dart';
import 'device_logcat_toolbar.dart';

/// Whether the logcat view under the picture is open. Outside the widget, so
/// closing it disposes the session and a surface switch finds it as left.
class DeviceLogcatOpen extends Notifier<bool> {
  @override
  bool build() => false;

  void toggle() => state = !state;
}

final deviceLogcatOpenProvider = NotifierProvider<DeviceLogcatOpen, bool>(
  DeviceLogcatOpen.new,
);

/// **The device's log, under its picture.** Collapsed it is one strip that
/// costs nothing: the session is `autoDispose`, so no view, no `logcat`.
class DeviceLogcatSection extends ConsumerWidget {
  const DeviceLogcatSection({
    required this.device,
    this.logHeight = defaultLogHeight,
    super.key,
  });

  /// The device the pane is showing. Null while there is none, which is when
  /// the strip disables itself rather than disappearing.
  final AndroidDevice? device;

  /// How tall the open log is. The pane sizes it to itself: a fixed 220px in a
  /// 478px side panel left the picture above it a sliver.
  final double logHeight;

  static const defaultLogHeight = 220.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final open = ref.watch(deviceLogcatOpenProvider);
    final serial = device?.serial;
    return LayoutBuilder(
      builder: (context, constraints) {
        final log = open && serial != null
            ? SizedBox(
                height: logHeight,
                // Keyed: another device is another stream and another view,
                // never this state handed a new serial.
                child: _Logcat(key: ValueKey(serial), serial: serial),
              )
            : null;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Divider(height: 1),
            _Strip(device: device, open: open),
            // Nothing below the strip until it is opened, and nothing watching
            // the session provider either — that is what keeps a closed view
            // free. Given less room than [logHeight], the log gives way first.
            if (log != null)
              constraints.hasBoundedHeight ? Flexible(child: log) : log,
          ],
        );
      },
    );
  }
}

class _Strip extends ConsumerWidget {
  const _Strip({required this.device, required this.open});

  final AndroidDevice? device;
  final bool open;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final enabled = device?.isReady ?? false;
    return InkWell(
      onTap: enabled
          ? () => ref.read(deviceLogcatOpenProvider.notifier).toggle()
          : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Insets.md,
          vertical: Insets.sm,
        ),
        child: Row(
          children: [
            Icon(
              AppIcons.article,
              size: Chrome.iconSmall,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: Insets.sm),
            Expanded(
              child: Text(
                device == null
                    ? 'Logcat — no device'
                    : 'Logcat — ${device!.displayName}',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: enabled
                      ? theme.colorScheme.onSurface
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            Icon(
              open ? AppIcons.caretDown : AppIcons.caretUp,
              size: Chrome.iconSmall,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}

class _Logcat extends ConsumerStatefulWidget {
  const _Logcat({required this.serial, super.key});

  final String serial;

  @override
  ConsumerState<_Logcat> createState() => _LogcatState();
}

class _LogcatState extends ConsumerState<_Logcat> {
  /// What one scroll view holds. A second bound above the tail's own: this is
  /// what the drawing isolate pays for on a device that logs in a loop. The
  /// search and the filters run over the whole tail; only drawing is capped.
  static const int visibleLines = 400;

  /// How close to the newest line still counts as "at the bottom".
  static const double _pinSlop = 4;

  final _package = TextEditingController();
  final _search = TextEditingController();
  final _searchFocus = FocusNode(debugLabel: 'logcat search');
  final _paneFocus = FocusNode(debugLabel: 'logcat', skipTraversal: true);
  final _scroll = ScrollController();

  /// The newest line the view is frozen on; null while following new lines.
  final _anchor = ValueNotifier<int?>(null);

  GlobalKey _currentKey = GlobalKey();
  List<LogcatLine> _window = const [];
  bool _revealing = false;

  String get _serial => widget.serial;

  @override
  void initState() {
    super.initState();
    _search.text = ref.read(deviceLogcatViewProvider(_serial)).query.text;
    // Opening the view is the act that starts the stream. Nothing starts it
    // behind a closed strip, and nothing restarts it on a tick.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(deviceLogcatSessionProvider(_serial)).start();
    });
  }

  @override
  void dispose() {
    _package.dispose();
    _search.dispose();
    _searchFocus.dispose();
    _paneFocus.dispose();
    _scroll.dispose();
    _anchor.dispose();
    super.dispose();
  }

  void _focusSearch() {
    _searchFocus.requestFocus();
    _search.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _search.text.length,
    );
  }

  void _escape() {
    if (_search.text.isEmpty) {
      _paneFocus.requestFocus();
      return;
    }
    _search.clear();
    final views = ref.read(deviceLogcatViewsProvider.notifier);
    views.setQuery(_serial, views.of(_serial).query.copyWith(text: ''));
  }

  /// Anchors outside a frame's build: scroll notifications can land mid-layout.
  void _setAnchor(int? value) {
    if (_anchor.value == value) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _anchor.value = value;
      });
    } else {
      _anchor.value = value;
    }
  }

  bool _onScroll(ScrollUpdateNotification notification) {
    if (notification.depth != 0 || _revealing) return false;
    final metrics = notification.metrics;
    final atNewest = metrics.pixels <= metrics.minScrollExtent + _pinSlop;
    if (!atNewest && _anchor.value == null && _window.isNotEmpty) {
      _setAnchor(_window.last.sequence);
    } else if (atNewest && _anchor.value != null) {
      _setAnchor(null);
    }
    return false;
  }

  void _jumpToLatest() {
    _anchor.value = null;
    if (!_scroll.hasClients) return;
    _revealing = true;
    _scroll.jumpTo(_scroll.position.minScrollExtent);
    _revealing = false;
  }

  /// +1 newer, -1 older, wrapping. With nothing selected either lands on the
  /// newest match on screen.
  void _step(int direction) {
    final result = ref.read(deviceLogcatFilterProvider(_serial));
    if (result.matches.isEmpty) return;
    final views = ref.read(deviceLogcatViewsProvider.notifier);
    final selected = views.of(_serial).currentMatch;
    final at = selected == null ? -1 : result.indexOfMatch(selected);
    final matches = result.matches;
    int next;
    if (at < 0) {
      next = matches.length - 1;
      final end = _anchor.value;
      if (end != null) {
        while (next > 0 && matches[next] > end) {
          next--;
        }
      }
    } else {
      next = (at + direction) % matches.length;
    }
    final sequence = matches[next];
    views.selectMatch(_serial, sequence);

    // Navigating freezes the tail, and moves the rendered window only when the
    // match is outside it.
    final end = _anchor.value ?? result.lines.last.sequence;
    final window = result.window(endSequence: end, limit: visibleLines);
    if (window.isEmpty || sequence > end || sequence < window.first.sequence) {
      final index = result.indexOfLine(sequence);
      final endIndex = math.min(
        index + visibleLines ~/ 2,
        result.lines.length - 1,
      );
      _anchor.value = result.lines[endIndex].sequence;
    } else {
      _anchor.value = end;
    }
    setState(() => _currentKey = GlobalKey());
    _reveal(sequence);
  }

  Future<void> _reveal(int sequence) async {
    _revealing = true;
    try {
      for (var attempt = 0; attempt < 12; attempt++) {
        await SchedulerBinding.instance.endOfFrame;
        if (!mounted) return;
        final target = _currentKey.currentContext;
        if (target != null && target.mounted) {
          await Scrollable.ensureVisible(
            target,
            alignment: 0.5,
            duration: Motion.of(context).fast,
            curve: Motion.standard,
          );
          return;
        }
        if (!_scroll.hasClients) return;
        // Not built yet: jump to where it should be and look again.
        final index = _indexIn(_window, sequence);
        if (index < 0) continue;
        final position = _scroll.position;
        final perLine =
            (position.maxScrollExtent + position.viewportDimension) /
            _window.length;
        final fromNewest = _window.length - 1 - index;
        _scroll.jumpTo(
          (fromNewest * perLine - position.viewportDimension / 2).clamp(
            position.minScrollExtent,
            position.maxScrollExtent,
          ),
        );
        SchedulerBinding.instance.scheduleFrame();
      }
    } finally {
      _revealing = false;
    }
  }

  void _clear() {
    ref
        .read(deviceLogcatViewsProvider.notifier)
        .clear(_serial, ref.read(deviceLogcatSessionProvider(_serial)));
    _anchor.value = null;
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(deviceLogcatSessionProvider(_serial));
    final meta = defaultTargetPlatform == TargetPlatform.macOS;
    return CallbackShortcuts(
      bindings: {
        SingleActivator(LogicalKeyboardKey.keyF, meta: meta, control: !meta):
            _focusSearch,
      },
      child: Focus(
        focusNode: _paneFocus,
        child: Listener(
          onPointerDown: (_) {
            if (!_paneFocus.hasFocus) _paneFocus.requestFocus();
          },
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DeviceLogcatToolbar(
                serial: _serial,
                session: session,
                controller: _search,
                focusNode: _searchFocus,
                package: _package,
                onNext: () => _step(1),
                onPrevious: () => _step(-1),
                onEscape: _escape,
              ),
              Expanded(child: _body(session)),
              // The session too: attaching, a problem or a package pin changes
              // the words without changing a single line.
              ListenableBuilder(
                listenable: Listenable.merge([_anchor, session]),
                builder: (context, _) => _Status(
                  serial: _serial,
                  session: session,
                  anchor: _anchor.value,
                  onClear: _clear,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body(DeviceLogcatSession session) => Consumer(
    builder: (context, ref, _) {
      final result = ref.watch(deviceLogcatFilterProvider(_serial));
      final current = ref.watch(
        deviceLogcatViewProvider(_serial).select((view) => view.currentMatch),
      );
      return ValueListenableBuilder<int?>(
        valueListenable: _anchor,
        builder: (context, anchor, _) {
          final window = result.window(
            endSequence: anchor,
            limit: visibleLines,
          );
          _window = window;
          if (window.isEmpty) {
            return ListenableBuilder(
              listenable: session,
              builder: (context, _) =>
                  _BodyMessage(_emptyWords(session, result)),
            );
          }
          return Stack(
            children: [
              NotificationListener<ScrollUpdateNotification>(
                onNotification: _onScroll,
                child: ListView.builder(
                  controller: _scroll,
                  // Newest at the bottom, and cheap: the list is built from the
                  // end so a chatty device does not re-lay-out everything
                  // above the fold.
                  reverse: true,
                  padding: const EdgeInsets.symmetric(horizontal: Insets.md),
                  itemCount: window.length,
                  findChildIndexCallback: (key) {
                    final sequence = key is ValueKey<int>
                        ? key.value
                        : key == _currentKey
                        ? current
                        : null;
                    if (sequence == null) return null;
                    final index = _indexIn(window, sequence);
                    return index < 0 ? null : window.length - 1 - index;
                  },
                  itemBuilder: (context, index) {
                    final line = window[window.length - 1 - index];
                    final isCurrent = line.sequence == current;
                    return _Line(
                      key: isCurrent
                          ? _currentKey
                          : ValueKey<int>(line.sequence),
                      line: line,
                      pattern: result.pattern,
                      current: isCurrent,
                    );
                  },
                ),
              ),
              if (anchor != null)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: Insets.sm,
                  child: Center(
                    child: _JumpToLatest(
                      newer: result.newerThan(anchor),
                      onPressed: _jumpToLatest,
                    ),
                  ),
                ),
            ],
          );
        },
      );
    },
  );

  /// Different nothings, never one word for all: a stream that could not
  /// start, one nobody started, a quiet device, a cleared view, and filters
  /// that match nothing.
  static String _emptyWords(
    DeviceLogcatSession session,
    LogcatFilterResult result,
  ) {
    if (result.total > 0) return 'No lines match the filters.';
    final problem = session.problem;
    if (problem != null) return problem;
    if (session.kept > 0) return 'Cleared. New lines will appear here.';
    if (session.starting) return 'Attaching to the log…';
    if (session.streaming) return 'Attached — nothing has been logged yet.';
    return 'Not reading. Start to attach to this device’s log.';
  }
}

int _indexIn(List<LogcatLine> lines, int sequence) {
  var lo = 0;
  var hi = lines.length;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (lines[mid].sequence < sequence) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  return lo < lines.length && lines[lo].sequence == sequence ? lo : -1;
}

class _BodyMessage extends StatelessWidget {
  const _BodyMessage(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(Insets.md),
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

class _JumpToLatest extends StatelessWidget {
  const _JumpToLatest({required this.newer, required this.onPressed});

  final int newer;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => FilledButton.tonalIcon(
    onPressed: onPressed,
    icon: const Icon(AppIcons.arrowDown, size: Chrome.iconAction),
    label: Text(newer == 0 ? 'Jump to latest' : 'Jump to latest ($newer new)'),
    style: FilledButton.styleFrom(
      visualDensity: VisualDensity.compact,
      textStyle: Theme.of(context).textTheme.labelSmall,
    ),
  );
}

class _Line extends StatelessWidget {
  const _Line({
    required this.line,
    required this.pattern,
    required this.current,
    super.key,
  });

  final LogcatLine line;
  final LogcatPattern pattern;
  final bool current;

  @override
  Widget build(BuildContext context) {
    final entry = line.entry;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final semantic = SemanticColors.of(context);
    // The Flutter console's colours: an error is a failure, a warning asks
    // for attention.
    final colour = switch (entry.level) {
      LogLevel.error || LogLevel.fatal => semantic.failure,
      LogLevel.warning => semantic.attention,
      LogLevel.verbose || LogLevel.debug => scheme.onSurfaceVariant,
      LogLevel.info => scheme.onSurface,
    };
    final style = theme.textTheme.bodySmall?.copyWith(
      fontFamily: kMonoFamily,
      fontFamilyFallback: kMonoFallback,
      color: colour,
    );
    final text = logcatSearchText(entry);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: current ? StateLayers.subtle(scheme) : null,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              entry.level.code,
              style: style?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(width: Insets.sm),
            // No `maxLines`: on a SelectableText it is a fixed height, so every
            // one-line entry stood three lines tall, and a match past the third
            // line was scrolled out of sight inside its own line.
            Expanded(
              child: line.isMatch
                  ? SelectableText.rich(
                      highlightLogMatches(
                        text,
                        pattern.ranges(text),
                        scheme: scheme,
                        style: style,
                        current: current,
                      ),
                    )
                  : SelectableText(text, style: style),
            ),
          ],
        ),
      ),
    );
  }
}

/// §19 at the line the reading is on: how old this tail is, what the view
/// holds, and what the tail lost — with what can be done with the lines.
class _Status extends ConsumerWidget {
  const _Status({
    required this.serial,
    required this.session,
    required this.anchor,
    required this.onClear,
  });

  final String serial;
  final DeviceLogcatSession session;
  final int? anchor;
  final VoidCallback onClear;

  static String describe(
    DeviceLogcatSession session,
    LogcatFilterResult result, {
    required DateTime now,
    int? anchor,
  }) {
    final parts = <String>[];
    final startedAt = session.startedAt;
    parts.add(
      startedAt == null
          ? 'Not attached'
          : 'Attached ${describeDriveAge(now.difference(startedAt))}',
    );
    final lastAt = session.lastLineAt;
    // Never "no lines yet" as a time: a stream that has produced nothing has no
    // last line, and a zero there would read as a line that just arrived.
    parts.add(
      lastAt == null
          ? 'no line yet'
          : 'last line ${describeDriveAge(now.difference(lastAt))}',
    );
    parts.add(_summary(result, anchor: anchor));
    // Counted, and shown whenever it is not zero — a tail that quietly dropped
    // its oldest lines looks exactly like one that never saw them.
    if (session.dropped > 0) parts.add('${session.dropped} dropped');
    if (session.packageFilter != null) parts.add('only ${session.packageFilter}');
    return parts.join(' · ');
  }

  static String _summary(LogcatFilterResult result, {int? anchor}) {
    const limit = _LogcatState.visibleLines;
    final query = result.query;
    final narrowed =
        query.isFiltered || (query.onlyMatching && !result.pattern.isEmpty);
    final shown = result.lines.length;
    if (shown > limit) {
      return '${anchor == null ? 'showing newest' : 'showing'} $limit of '
          '$shown ${narrowed ? 'matching lines' : 'lines'}';
    }
    if (narrowed) return '$shown of ${_lines(result.total)}';
    return _lines(shown);
  }

  static String _lines(int count) => count == 1 ? '1 line' : '$count lines';

  void _copy(BuildContext context, LogcatFilterResult result) {
    // The device's own line, timestamp and pids included: what is pasted into
    // a bug report should read like `adb logcat` did.
    final text = [for (final line in result.lines) '${line.entry}'].join('\n');
    Clipboard.setData(ClipboardData(text: text));
    final count = result.lines.length;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text('Copied $count ${count == 1 ? 'line' : 'lines'}.'),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final result = ref.watch(deviceLogcatFilterProvider(serial));
    final now = ref.watch(deviceClockProvider).nowUtc();
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, box) {
        final wide = logcatToolbarIsWide(context, box.maxWidth);
        return Padding(
          padding: const EdgeInsets.fromLTRB(Insets.md, 0, Insets.xs, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  describe(session, result, now: now, anchor: anchor),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              if (!wide)
                Flexible(child: DeviceLogcatMatchCount(serial: serial)),
              IconButton(
                tooltip: 'Copy the lines shown',
                visualDensity: VisualDensity.compact,
                icon: const Icon(AppIcons.copy, size: Chrome.iconAction),
                onPressed: result.lines.isEmpty
                    ? null
                    : () => _copy(context, result),
              ),
              IconButton(
                tooltip: 'Clear the view (the device keeps its log)',
                visualDensity: VisualDensity.compact,
                // A broom, not a bin: nothing on the device is deleted.
                icon: const Icon(AppIcons.broom, size: Chrome.iconAction),
                onPressed: result.total == 0 ? null : onClear,
              ),
            ],
          ),
        );
      },
    );
  }
}
