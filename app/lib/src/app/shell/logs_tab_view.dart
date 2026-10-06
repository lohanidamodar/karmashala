import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';

import '../../core/logging/diagnostics_providers.dart';
import '../../core/logging/server_log_tail.dart';
import 'package:karmashala_core/logging.dart';
import 'package:karmashala_ui/icons.dart';
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

enum _LogSource { app, server }

/// From this width the controls fit one row above the lines.
const double _oneRowWidth = 720;

class _LogsTabViewState extends ConsumerState<LogsTabView> {
  Timer? _ticker;
  Timer? _serverTicker;
  int _seenRevision = -1;
  bool _follow = true;
  _LogSource _source = _LogSource.app;

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
    if (!_follow || !mounted || _source != _LogSource.app) return;
    final revision = ref.read(diagnosticsProvider).buffer.revision;
    if (revision == _seenRevision) return;
    setState(() => _seenRevision = revision);
  }

  Future<void> _pollServer() async {
    if (!_follow || !mounted || _source != _LogSource.server) return;
    final tail = ref.read(serverLogTailProvider);
    if (tail == null) return;
    final read = await tail.read();
    if (!mounted || (_serverRead && identical(read, _server))) return;
    setState(() {
      _server = read;
      _serverRead = true;
    });
  }

  void _setSource(_LogSource source) {
    setState(() {
      _source = source;
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
          : _source == _LogSource.app
          ? ref.read(diagnosticsProvider).buffer.snapshot()
          : (_server ?? const []);
    });
    if (value && _scroll.hasClients) _scroll.jumpTo(0);
    if (value) unawaited(_pollServer());
  }

  List<LogEntry> _filter(List<LogEntry> all) {
    final query = _query.trim().toLowerCase();
    return [
      for (final entry in all)
        if (entry.level >= _minLevel &&
            (_channel == null || entry.channel == _channel) &&
            (query.isEmpty ||
                entry.channel.toLowerCase().contains(query) ||
                entry.message.toLowerCase().contains(query) ||
                (entry.error?.toLowerCase().contains(query) ?? false)))
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

  String _emptyMessage(_LogSource source, List<LogEntry> all) {
    if (all.isNotEmpty) return 'Nothing matches these filters.';
    if (source == _LogSource.app) return 'Nothing has been logged yet.';
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
    final source = hasServer ? _source : _LogSource.app;
    final all = !_follow
        ? _frozen
        : source == _LogSource.app
        ? buffer.snapshot()
        : (_server ?? const <LogEntry>[]);
    final visible = _filter(all);
    final channels = {for (final entry in all) entry.channel}.toList()..sort();
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(
          builder: (context, constraints) => _Controls(
            oneRow: constraints.maxWidth >= _oneRowWidth,
            search: _search,
            source: hasServer ? source : null,
            following: _follow,
            minLevel: _minLevel,
            channel: channels.contains(_channel) ? _channel : null,
            channels: channels,
            onSource: _setSource,
            onQuery: (value) => setState(() => _query = value),
            onLevel: (value) => setState(() => _minLevel = value),
            onChannel: (value) => setState(() => _channel = value),
            onFollow: _setFollow,
            onCopy: visible.isEmpty ? null : () => _copy(visible),
            // A file is the server's, not ours to empty.
            onClear: source == _LogSource.server
                ? null
                : () {
                    ref.read(diagnosticsProvider).clear();
                    _setFollow(true);
                  },
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
            if (source == _LogSource.app) ...[
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

/// Search, source, filters and the tail's verbs: one row in a wide tab, and
/// stacked in a narrow group.
class _Controls extends StatelessWidget {
  const _Controls({
    required this.oneRow,
    required this.search,
    required this.source,
    required this.following,
    required this.minLevel,
    required this.channel,
    required this.channels,
    required this.onSource,
    required this.onQuery,
    required this.onLevel,
    required this.onChannel,
    required this.onFollow,
    required this.onCopy,
    required this.onClear,
  });

  final bool oneRow;
  final TextEditingController search;

  /// Null where there is no server log to offer.
  final _LogSource? source;
  final bool following;
  final Level minLevel;
  final String? channel;
  final List<String> channels;
  final ValueChanged<_LogSource> onSource;
  final ValueChanged<String> onQuery;
  final ValueChanged<Level> onLevel;
  final ValueChanged<String?> onChannel;
  final ValueChanged<bool> onFollow;
  final VoidCallback? onCopy;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelSmall;
    final searchField = TextField(
      controller: search,
      onChanged: onQuery,
      decoration: const InputDecoration(
        isDense: true,
        hintText: 'Filter lines',
        prefixIcon: Icon(AppIcons.magnifyingGlass, size: Chrome.icon),
        prefixIconConstraints: BoxConstraints(minWidth: 30),
      ),
    );
    final sourcePicker = switch (source) {
      final source? => SegmentedButton<_LogSource>(
        showSelectedIcon: false,
        style: const ButtonStyle(visualDensity: VisualDensity.compact),
        segments: const [
          ButtonSegment(value: _LogSource.app, label: Text('App')),
          ButtonSegment(value: _LogSource.server, label: Text('Server')),
        ],
        selected: {source},
        onSelectionChanged: (choice) => onSource(choice.first),
      ),
      null => null,
    };
    final level = DropdownButton<Level>(
      value: minLevel,
      isExpanded: true,
      isDense: true,
      underline: const SizedBox.shrink(),
      style: style,
      // `DropdownButton` is Material 2 and `dropdownMenuTheme` reaches only
      // Material 3's `DropdownMenu`, so its chevron ignores it.
      iconSize: Chrome.icon,
      items: [
        for (final (label, level) in _levelFilters)
          DropdownMenuItem(value: level, child: Text(label)),
      ],
      onChanged: (value) => value == null ? null : onLevel(value),
    );
    final channelPicker = DropdownButton<String?>(
      value: channel,
      isExpanded: true,
      isDense: true,
      underline: const SizedBox.shrink(),
      style: style,
      iconSize: Chrome.icon,
      items: [
        const DropdownMenuItem(value: null, child: Text('All channels')),
        for (final name in channels)
          DropdownMenuItem(value: name, child: Text(name)),
      ],
      onChanged: onChannel,
    );
    final verbs = [
      IconButton(
        tooltip: following
            ? 'Following  ·  click to pause'
            : 'Paused  ·  click to follow the newest lines',
        icon: Icon(
          following ? AppIcons.pauseCircle : AppIcons.playCircle,
          size: Chrome.icon,
        ),
        onPressed: () => onFollow(!following),
      ),
      IconButton(
        tooltip: 'Copy the lines shown',
        icon: const Icon(AppIcons.copy, size: Chrome.icon),
        onPressed: onCopy,
      ),
      IconButton(
        tooltip: 'Clear the buffer',
        icon: const Icon(AppIcons.trash, size: Chrome.icon),
        onPressed: onClear,
      ),
    ];

    if (oneRow) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(
          Insets.md,
          Insets.sm,
          Insets.xs,
          Insets.sm,
        ),
        child: Row(
          children: [
            Expanded(child: searchField),
            if (sourcePicker != null) ...[
              const SizedBox(width: Insets.md),
              sourcePicker,
            ],
            const SizedBox(width: Insets.md),
            SizedBox(width: 160, child: level),
            const SizedBox(width: Insets.sm),
            SizedBox(width: 200, child: channelPicker),
            const SizedBox(width: Insets.sm),
            ...verbs,
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Insets.sm,
        Insets.sm,
        Insets.xs / 2,
        Insets.xs,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: searchField),
              ...verbs,
            ],
          ),
          if (sourcePicker != null)
            Padding(
              padding: const EdgeInsets.only(top: Insets.xs),
              child: Align(
                alignment: Alignment.centerLeft,
                child: sourcePicker,
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(right: Insets.sm, top: Insets.xs),
            child: Row(
              children: [
                Expanded(child: level),
                const SizedBox(width: Insets.sm),
                Expanded(child: channelPicker),
              ],
            ),
          ),
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
      padding: const EdgeInsets.symmetric(horizontal: Insets.md, vertical: 1),
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
