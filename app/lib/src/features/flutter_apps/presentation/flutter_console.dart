import 'dart:math' as math;

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_flutter_apps/flutter_apps.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/logs.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../explorer/application/session_context.dart';
import '../../notes/application/composer_draft.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_ui_providers.dart';
import '../application/attached_apps.dart';
import '../application/flutter_console_view.dart';
import 'flutter_console_toolbar.dart';

/// One app's debug console: search, filters, and a tail that follows the
/// newest line until the reader scrolls away or steps through matches.
class FlutterConsole extends ConsumerStatefulWidget {
  const FlutterConsole({required this.app, super.key});

  /// The newest lines rendered at once — bounded separately from the buffer,
  /// which is what an MCP call pages through.
  static const int visibleLines = 500;

  final AttachedApp app;

  @override
  ConsumerState<FlutterConsole> createState() => _FlutterConsoleState();
}

class _FlutterConsoleState extends ConsumerState<FlutterConsole> {
  final _search = TextEditingController();
  final _searchFocus = FocusNode(debugLabel: 'console search');
  final _paneFocus = FocusNode(debugLabel: 'console', skipTraversal: true);
  final _scroll = ScrollController();

  /// The newest line the view is frozen on; null while following new lines.
  final _anchor = ValueNotifier<int?>(null);

  GlobalKey _currentKey = GlobalKey();
  List<AppLogLine> _window = const [];
  bool _revealing = false;

  /// How close to the newest line still counts as "at the bottom".
  static const double _pinSlop = 4;

  String get _id => widget.app.id;

  @override
  void initState() {
    super.initState();
    _search.text = ref.read(flutterConsoleViewProvider(_id)).query.text;
  }

  @override
  void dispose() {
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
    final views = ref.read(flutterConsoleViewsProvider.notifier);
    views.setQuery(_id, views.of(_id).query.copyWith(text: ''));
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
    final result = ref.read(flutterConsoleFilterProvider(_id));
    if (result == null || result.matches.isEmpty) return;
    final views = ref.read(flutterConsoleViewsProvider.notifier);
    final selected = views.of(_id).currentMatch;
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
    views.selectMatch(_id, sequence);

    // Navigating freezes the tail, and moves the rendered window only when the
    // match is outside it.
    final end = _anchor.value ?? result.lines.last.sequence;
    final window = result.window(
      endSequence: end,
      limit: FlutterConsole.visibleLines,
    );
    if (window.isEmpty || sequence > end || sequence < window.first.sequence) {
      final index = result.indexOfLine(sequence);
      final endIndex = math.min(
        index + FlutterConsole.visibleLines ~/ 2,
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
    final link = ref.read(attachedAppsProvider.notifier).linkFor(_id);
    if (link == null) return;
    ref.read(flutterConsoleViewsProvider.notifier).clear(_id, link);
    _anchor.value = null;
  }

  @override
  Widget build(BuildContext context) {
    final empty = ref.watch(
      flutterConsoleFilterProvider(_id).select(
        (result) =>
            result == null ||
            (result.total == 0 &&
                (ref
                            .read(attachedAppsProvider.notifier)
                            .linkFor(_id)
                            ?.consoleAppended ??
                        0) ==
                    0),
      ),
    );
    if (empty) {
      return PanePlaceholder(
        icon: AppIcons.article,
        message: widget.app.isAttached
            // Deliberately not "no output": what the app said before we
            // attached is not ours to report (§19).
            ? 'Nothing since Karmashala attached. Whatever the app said before '
                  'that is not in this console.'
            : 'Not attached, so there is nothing to show.',
      );
    }

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
              FlutterConsoleToolbar(
                appId: _id,
                controller: _search,
                focusNode: _searchFocus,
                onNext: () => _step(1),
                onPrevious: () => _step(-1),
                onEscape: _escape,
              ),
              const Divider(height: 1),
              ValueListenableBuilder<int?>(
                valueListenable: _anchor,
                builder: (context, anchor, _) => _ConsoleStatus(
                  app: widget.app,
                  anchor: anchor,
                  onClear: _clear,
                ),
              ),
              const Divider(height: 1),
              Expanded(child: _body()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body() => Consumer(
    builder: (context, ref, _) {
      final result = ref.watch(flutterConsoleFilterProvider(_id));
      final current = ref.watch(
        flutterConsoleViewProvider(_id).select((view) => view.currentMatch),
      );
      return ValueListenableBuilder<int?>(
        valueListenable: _anchor,
        builder: (context, anchor, _) {
          if (result == null) return const SizedBox.shrink();
          final window = result.window(
            endSequence: anchor,
            limit: FlutterConsole.visibleLines,
          );
          _window = window;
          if (window.isEmpty) {
            return _BodyMessage(
              result.total == 0
                  ? 'Cleared. New lines will appear here.'
                  : 'No lines match the filters.',
            );
          }
          return Stack(
            children: [
              NotificationListener<ScrollUpdateNotification>(
                onNotification: _onScroll,
                child: ListView.builder(
                  controller: _scroll,
                  reverse: true,
                  padding: const EdgeInsets.symmetric(
                    horizontal: Insets.sm,
                    vertical: Insets.xs,
                  ),
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
                    return _ConsoleLine(
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
}

int _indexIn(List<AppLogLine> lines, int sequence) {
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
      child: Padding(
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

/// What the view holds, the newest error, and what can be done with the lines.
class _ConsoleStatus extends ConsumerWidget {
  const _ConsoleStatus({
    required this.app,
    required this.anchor,
    required this.onClear,
  });

  final AttachedApp app;
  final int? anchor;
  final VoidCallback onClear;

  static String describe(AppLogFilterResult result, {int? anchor}) {
    const limit = FlutterConsole.visibleLines;
    final query = result.query;
    final narrowed =
        query.isFiltered || (query.onlyMatching && !result.pattern.isEmpty);
    final shown = result.lines.length;
    final noun = narrowed ? 'matching lines' : 'lines';
    final summary = shown > limit
        ? '${anchor == null ? 'showing newest' : 'showing'} $limit of $shown '
              '$noun'
        : narrowed
        ? '$shown of ${result.total} lines'
        : '$shown lines';
    final error = result.newestError;
    return error == null
        ? summary
        : '$summary · newest error: ${error.message}';
  }

  /// Puts the error in the session's message box — offered, not sent, and
  /// nothing notifies: an exception pushed mid-turn is Karmashala deciding.
  void _offer(BuildContext context, WidgetRef ref, AppLogRecord error) {
    final sessionId = ref.read(focusedSessionIdProvider);
    final text = <String>[
      'The running Flutter app (${app.label ?? app.id}) reported this:',
      '',
      error.message,
      if (error.detail != null) error.detail!,
    ].join('\n');
    if (sessionId == null) {
      Clipboard.setData(ClipboardData(text: text));
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(
          content: Text('No session is focused — copied to the clipboard.'),
        ),
      );
      return;
    }
    ref.read(composerDraftProvider.notifier).queue(sessionId, text);
    ref.read(selectedSessionIdProvider.notifier).select(sessionId);
    final title =
        ref.read(sessionsDataProvider).getById(sessionId)?.title ?? 'the session';
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text('Waiting in $title\'s message box.')),
    );
  }

  void _copy(BuildContext context, AppLogFilterResult result) {
    final text = [
      for (final line in result.lines) appLogSearchText(line.record),
    ].join('\n');
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
    final result = ref.watch(flutterConsoleFilterProvider(app.id));
    if (result == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final error = result.newestError;
    return LayoutBuilder(
      builder: (context, box) {
        final wide = consoleToolbarIsWide(context, box.maxWidth);
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: Insets.xs),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  describe(result, anchor: anchor),
                  style: theme.textTheme.labelSmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (!wide)
                Flexible(child: FlutterConsoleMatchCount(appId: app.id)),
              IconButton(
                tooltip: 'Copy the lines shown',
                visualDensity: VisualDensity.compact,
                icon: const Icon(AppIcons.copy, size: Chrome.iconAction),
                onPressed: result.lines.isEmpty
                    ? null
                    : () => _copy(context, result),
              ),
              IconButton(
                tooltip: 'Clear the console (the app keeps running)',
                visualDensity: VisualDensity.compact,
                icon: const Icon(AppIcons.trash, size: Chrome.iconAction),
                onPressed: result.total == 0 ? null : onClear,
              ),
              if (error != null)
                wide
                    ? Tooltip(
                        message: 'Offer error to session',
                        child: TextButton.icon(
                          onPressed: () => _offer(context, ref, error),
                          icon: const Icon(
                            AppIcons.paperPlaneRight,
                            size: Chrome.iconAction,
                          ),
                          label: const Text('Offer error to session'),
                          style: TextButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            textStyle: theme.textTheme.labelSmall,
                          ),
                        ),
                      )
                    : IconButton(
                        tooltip: 'Offer error to session',
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(
                          AppIcons.paperPlaneRight,
                          size: Chrome.iconAction,
                        ),
                        onPressed: () => _offer(context, ref, error),
                      ),
            ],
          ),
        );
      },
    );
  }
}

class _ConsoleLine extends StatelessWidget {
  const _ConsoleLine({
    required this.line,
    required this.pattern,
    required this.current,
    super.key,
  });

  final AppLogLine line;
  final AppLogPattern pattern;
  final bool current;

  @override
  Widget build(BuildContext context) {
    final record = line.record;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final semantic = SemanticColors.of(context);
    final colour = switch (record.source) {
      AppLogSource.flutterError || AppLogSource.stderr => semantic.failure,
      AppLogSource.lifecycle => scheme.onSurfaceVariant,
      AppLogSource.developerLog => scheme.tertiary,
      AppLogSource.stdout => scheme.onSurface,
    };
    final origin = switch (record.source) {
      AppLogSource.stdout => 'out',
      AppLogSource.stderr => 'err',
      AppLogSource.developerLog =>
        record.loggerName?.isNotEmpty == true ? record.loggerName! : 'log',
      AppLogSource.flutterError => 'error',
      AppLogSource.lifecycle => '·',
    };
    final style = theme.textTheme.bodySmall?.copyWith(
      color: colour,
      fontFamily: kMonoFamily,
      fontFamilyFallback: kMonoFallback,
    );
    final text = appLogSearchText(record);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: current ? StateLayers.subtle(scheme) : null,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 54,
              child: Text(
                origin,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
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
            // History, marked: the VM service replays its buffer to every new
            // subscriber, so the top of this console is the app's past.
            if (record.beforeAttach)
              Padding(
                padding: const EdgeInsets.only(left: Insets.xs),
                child: Text(
                  'before attach',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
