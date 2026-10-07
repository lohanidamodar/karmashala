import 'dart:async';

import 'package:flutter/material.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';

import '../../core/logging/diagnostics_providers.dart';
import '../../core/logging/server_log_tail.dart';
import '../widgets/adaptive_modal.dart';
import 'package:karmashala_core/logging.dart';
import 'package:karmashala_core/util.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/tokens.dart';

/// The Logs tab: the app's live log tail, and this machine's `server.log`
/// beside it. A counter polled on a timer rather than a listener, because a
/// busy channel emits faster than the frame budget.
class LogsTabView extends ConsumerStatefulWidget {
  const LogsTabView({super.key});

  /// How often the tail is repainted while following.
  static const Duration refreshInterval = Duration(milliseconds: 100);

  /// How often `server.log` is looked at while it is the source shown.
  static const Duration serverPollInterval = Duration(seconds: 1);

  /// Builds of the tail, counted so a test can prove a flood does not become a
  /// rebuild per record.
  @visibleForTesting
  static int debugBuildCount = 0;

  @override
  ConsumerState<LogsTabView> createState() => _LogsTabViewState();
}

/// The level floors offered, coarsest question first.
const List<(String, Level)> _levelFilters = [
  ('All levels', Level.ALL),
  ('Info and up', Level.INFO),
  ('Warnings and up', Level.WARNING),
  ('Errors only', Level.SEVERE),
];

/// Which log the Logs tab shows. Kept outside the tab, so a link can open it
/// on the server's log (Settings → Server → Log).
enum LogSource { app, server }

class LogsTabSource extends Notifier<LogSource> {
  @override
  LogSource build() => LogSource.app;

  void show(LogSource source) => state = source;
}

final logsTabSourceProvider = NotifierProvider<LogsTabSource, LogSource>(
  LogsTabSource.new,
);

class _LogsTabViewState extends ConsumerState<LogsTabView> {
  Timer? _ticker;
  Timer? _serverTicker;
  int _seenRevision = -1;
  bool _follow = true;
  LogSource get _source => ref.read(logsTabSourceProvider);

  /// The tail as it was when following stopped. Empty while following.
  List<LogEntry> _frozen = const [];

  /// `server.log` as last read; null before a read or while it is not written.
  List<LogEntry>? _server;
  bool _serverRead = false;

  Level _minLevel = Level.ALL;
  String? _channel;
  String _query = '';

  final TextEditingController _search = TextEditingController();
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(LogsTabView.refreshInterval, (_) => _tick());
    _serverTicker = Timer.periodic(
      LogsTabView.serverPollInterval,
      (_) => unawaited(_pollServer()),
    );
    _scroll.addListener(_onScroll);
    // A link may ask for the other log while the tab is open.
    ref.listenManual(logsTabSourceProvider, (_, _) => _sourceChanged());
    if (_source == LogSource.server) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _pollServer());
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _serverTicker?.cancel();
    _scroll.dispose();
    _search.dispose();
    super.dispose();
  }

  void _tick() {
    if (!_follow || !mounted || _source != LogSource.app) return;
    final revision = ref.read(diagnosticsProvider).buffer.revision;
    if (revision == _seenRevision) return;
    setState(() => _seenRevision = revision);
  }

  Future<void> _pollServer() async {
    if (!_follow || !mounted || _source != LogSource.server) return;
    final tail = ref.read(serverLogTailProvider);
    if (tail == null) return;
    final read = await tail.read();
    if (!mounted || (_serverRead && identical(read, _server))) return;
    setState(() {
      _server = read;
      _serverRead = true;
    });
  }

  void _setSource(LogSource source) =>
      ref.read(logsTabSourceProvider.notifier).show(source);

  void _sourceChanged() {
    setState(() {
      _follow = true;
      _frozen = const [];
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    unawaited(_pollServer());
  }

  /// The list is reversed, so offset 0 is the newest line. Leaving it means the
  /// user is reading history and does not want it moving.
  void _onScroll() {
    if (_follow && _scroll.hasClients && _scroll.offset > 32) _setFollow(false);
  }

  void _setFollow(bool value) {
    setState(() {
      _follow = value;
      _frozen = value
          ? const []
          : _source == LogSource.app
          ? ref.read(diagnosticsProvider).buffer.snapshot()
          : (_server ?? const []);
    });
    if (value && _scroll.hasClients) _scroll.jumpTo(0);
    if (value) unawaited(_pollServer());
  }

  List<LogEntry> _filter(List<LogEntry> all) {
    return [
      for (final entry in all)
        if (entry.level >= _minLevel &&
            (_channel == null || entry.channel == _channel) &&
            matchesSearchAny(_query, [
              entry.channel,
              entry.message,
              entry.error,
            ]))
          entry,
    ];
  }

  Future<void> _copy(List<LogEntry> visible) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    await Clipboard.setData(
      ClipboardData(
        text: visible.map((e) => e.format(withDate: true)).join('\n'),
      ),
    );
    messenger?.showSnackBar(
      SnackBar(content: Text('Copied ${visible.length} log lines.')),
    );
  }

  String _emptyMessage(LogSource source, List<LogEntry> all) {
    if (all.isNotEmpty) return 'Nothing matches these filters.';
    if (source == LogSource.app) return 'Nothing has been logged yet.';
    if (!_serverRead) return 'Reading the server log…';
    return _server == null
        ? 'The server has not written its log yet.'
        : 'The server log is empty.';
  }

  @override
  Widget build(BuildContext context) {
    LogsTabView.debugBuildCount++;
    final buffer = ref.watch(diagnosticsProvider).buffer;
    final hasServer = ref.watch(serverLogTailProvider) != null;
    final source = hasServer ? ref.watch(logsTabSourceProvider) : LogSource.app;
    final all = !_follow
        ? _frozen
        : source == LogSource.app
        ? buffer.snapshot()
        : (_server ?? const <LogEntry>[]);
    final visible = _filter(all);
    final channels = {for (final entry in all) entry.channel}.toList()..sort();
    final theme = Theme.of(context);

    final channel = channels.contains(_channel) ? _channel : null;
    final filtersSet =
        (_minLevel == Level.ALL ? 0 : 1) + (channel == null ? 0 : 1);
    return WorkbenchTabScaffold(
      icon: AppIcons.article,
      title: 'Logs',
      controls: [
        if (hasServer)
          CompactSegmented<LogSource>(
            key: const ValueKey('logs-source'),
            segments: const [
              ButtonSegment(value: LogSource.app, label: Text('App')),
              ButtonSegment(value: LogSource.server, label: Text('Server')),
            ],
            selected: source,
            onChanged: _setSource,
          ),
      ],
      actions: [
        FilterFunnelButton(
          key: const ValueKey('logs-filters'),
          count: filtersSet,
          onPressed: () => _showFilters(channels),
        ),
        IconButton(
          tooltip: _follow
              ? 'Following  ·  click to pause'
              : 'Paused  ·  click to follow the newest lines',
          icon: Icon(_follow ? AppIcons.pauseCircle : AppIcons.playCircle),
          onPressed: () => _setFollow(!_follow),
        ),
        IconButton(
          tooltip: 'Copy the lines shown',
          icon: const Icon(AppIcons.copy),
          onPressed: visible.isEmpty ? null : () => _copy(visible),
        ),
        IconButton(
          tooltip: 'Clear the buffer',
          icon: const Icon(AppIcons.trash),
          // A file is the server's, not ours to empty.
          onPressed: source == LogSource.server
              ? null
              : () {
                  ref.read(diagnosticsProvider).clear();
                  _setFollow(true);
                },
        ),
      ],
      body: _body(source, all, visible, buffer, theme),
    );
  }

  Future<void> _showFilters(List<String> channels) => showAdaptiveModal<void>(
    context: context,
    title: 'Filters',
    builder: (_) => StatefulBuilder(
      // The modal is its own route: it keeps a copy to redraw its chips.
      builder: (context, setModal) => _LogFilters(
        minLevel: _minLevel,
        channel: channels.contains(_channel) ? _channel : null,
        channels: channels,
        onLevel: (value) {
          setState(() => _minLevel = value);
          setModal(() {});
        },
        onChannel: (value) {
          setState(() => _channel = value);
          setModal(() {});
        },
      ),
    ),
  );

  Widget _body(
    LogSource source,
    List<LogEntry> all,
    List<LogEntry> visible,
    LogRingBuffer buffer,
    ThemeData theme,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(Insets.sm),
          child: SearchField(
            controller: _search,
            onChanged: (value) => setState(() => _query = value),
            decoration: compactSearchDecoration(hintText: 'Filter lines'),
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: visible.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(Insets.lg),
                    child: Text(
                      _emptyMessage(source, all),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                )
              : SelectionArea(
                  child: ListView.builder(
                    controller: _scroll,
                    // Newest first, so following is simply "stay at the top"
                    // and arriving records never shift what is on screen.
                    reverse: true,
                    padding: const EdgeInsets.symmetric(vertical: Insets.xs),
                    itemCount: visible.length,
                    itemBuilder: (context, index) =>
                        _LogRow(entry: visible[visible.length - 1 - index]),
                  ),
                ),
        ),
        const Divider(height: 1),
        _StatusLine(
          parts: [
            '${visible.length} shown',
            if (source == LogSource.app) ...[
              '${buffer.length} held',
              if (buffer.dropped > 0) '${buffer.dropped} dropped',
            ] else
              '${all.length} read from server.log',
            if (!_follow) 'paused',
          ],
        ),
      ],
    );
  }
}

/// The level floor and the channel, as chips, behind the tab's funnel.
class _LogFilters extends StatelessWidget {
  const _LogFilters({
    required this.minLevel,
    required this.channel,
    required this.channels,
    required this.onLevel,
    required this.onChannel,
  });

  final Level minLevel;
  final String? channel;
  final List<String> channels;
  final ValueChanged<Level> onLevel;
  final ValueChanged<String?> onChannel;

  @override
  Widget build(BuildContext context) {
    Widget section(String label, List<Widget> chips) => Padding(
      padding: const EdgeInsets.fromLTRB(Insets.lg, Insets.md, Insets.lg, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          EyebrowLabel(label),
          const SizedBox(height: Insets.sm),
          Wrap(spacing: Insets.sm, runSpacing: Insets.sm, children: chips),
        ],
      ),
    );
    return SingleChildScrollView(
      key: const ValueKey('logs-filter-panel'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          section('Level', [
            for (final (label, level) in _levelFilters)
              ChoiceChip(
                label: Text(label),
                selected: level == minLevel,
                onSelected: (_) => onLevel(level),
              ),
          ]),
          section('Channel', [
            ChoiceChip(
              label: const Text('All channels'),
              selected: channel == null,
              onSelected: (_) => onChannel(null),
            ),
            for (final name in channels)
              ChoiceChip(
                label: Text(name),
                selected: name == channel,
                onSelected: (_) => onChannel(name),
              ),
          ]),
          const SizedBox(height: Insets.md),
        ],
      ),
    );
  }
}

class _LogRow extends StatelessWidget {
  const _LogRow({required this.entry});

  final LogEntry entry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final semantic = SemanticColors.of(context);
    final color = switch (entry.level) {
      Level.SEVERE || Level.SHOUT => semantic.failure,
      Level.WARNING => semantic.attention,
      Level.FINE || Level.FINER || Level.FINEST => scheme.onSurfaceVariant,
      _ => scheme.onSurface,
    };
    final dim = MonoStyles.small.copyWith(color: scheme.onSurfaceVariant);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Insets.md,
        vertical: Insets.hair,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) =>
            _cells(constraints.maxWidth, dim, color, semantic),
      ),
    );
  }

  Widget _cells(
    double width,
    TextStyle dim,
    Color color,
    SemanticColors semantic,
  ) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      // At most half the row: a narrow group at a large text size ends
      // the timestamp rather than pushing the row out of the group.
      ConstrainedBox(
        constraints: BoxConstraints(maxWidth: width / 2),
        child: Text(
          entry.timestamp,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: dim,
        ),
      ),
      const SizedBox(width: Insets.sm),
      Expanded(
        child: Text.rich(
          TextSpan(
            children: [
              TextSpan(text: '${entry.channel}  ', style: dim),
              TextSpan(
                text: entry.message,
                style: MonoStyles.small.copyWith(color: color),
              ),
              if (entry.error != null)
                TextSpan(
                  text: '  ${entry.error}',
                  style: MonoStyles.small.copyWith(color: semantic.failure),
                ),
            ],
          ),
        ),
      ),
    ],
  );
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.parts});

  final List<String> parts;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      // The tab's footer is a status bar, and the window already has a token
      // for how tall one of those is.
      height: Chrome.statusBarOf(context),
      padding: const EdgeInsets.symmetric(horizontal: Insets.md),
      color: theme.colorScheme.surfaceContainerLowest,
      alignment: Alignment.centerLeft,
      child: Text(
        parts.join('  ·  '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.labelSmall,
      ),
    );
  }
}
