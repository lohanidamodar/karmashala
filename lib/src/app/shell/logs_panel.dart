import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';

import '../../core/logging/diagnostics_providers.dart';
import 'package:karmashala_core/logging.dart';
import '../theme/app_icons.dart';
import '../theme/design_tokens.dart';

/// The live log tail: what the app is actually saying, inside the app.
///
/// **Why this reads a counter instead of listening.** A busy channel —
/// `device-stream`, `terminal` — emits far faster than the frame budget, and a
/// listener that called `setState` per record would be a rebuild storm of
/// exactly the kind Loop 87 just removed. So the ring buffer notifies nobody:
/// it bumps an integer, and this panel compares that integer on a
/// [LogsPanel.refreshInterval] timer, repainting at most ten times a second no
/// matter how many thousands of records arrived in between. Logging stays a
/// synchronous array store, and the UI cost is bounded by the clock rather than
/// by the log rate.
///
/// **Paused means frozen.** Following renders the live tail; pausing keeps the
/// snapshot taken at that moment, so reading an older line is not a fight with
/// the list moving underneath. Scrolling away from the newest end pauses on its
/// own, which is what every log viewer has taught people to expect.
///
/// Everything here is already redacted: the buffer is the only source, and
/// nothing reaches it unredacted.
class LogsPanel extends ConsumerStatefulWidget {
  const LogsPanel({super.key});

  /// How often the tail is repainted while following.
  static const Duration refreshInterval = Duration(milliseconds: 100);

  /// Builds of the tail, counted so a test can prove a flood does not become a
  /// rebuild per record.
  @visibleForTesting
  static int debugBuildCount = 0;

  @override
  ConsumerState<LogsPanel> createState() => _LogsPanelState();
}

/// The level floors offered, coarsest question first.
const List<(String, Level)> _levelFilters = [
  ('All levels', Level.ALL),
  ('Info and up', Level.INFO),
  ('Warnings and up', Level.WARNING),
  ('Errors only', Level.SEVERE),
];

class _LogsPanelState extends ConsumerState<LogsPanel> {
  Timer? _ticker;
  int _seenRevision = -1;
  bool _follow = true;

  /// The tail as it was when following stopped. Empty while following.
  List<LogEntry> _frozen = const [];

  Level _minLevel = Level.ALL;
  String? _channel;
  String _query = '';

  final TextEditingController _search = TextEditingController();
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(LogsPanel.refreshInterval, (_) => _tick());
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _scroll.dispose();
    _search.dispose();
    super.dispose();
  }

  void _tick() {
    if (!_follow || !mounted) return;
    final revision = ref.read(diagnosticsProvider).buffer.revision;
    if (revision == _seenRevision) return;
    setState(() => _seenRevision = revision);
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
          : ref.read(diagnosticsProvider).buffer.snapshot();
    });
    if (value && _scroll.hasClients) _scroll.jumpTo(0);
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

  @override
  Widget build(BuildContext context) {
    LogsPanel.debugBuildCount++;
    final buffer = ref.watch(diagnosticsProvider).buffer;
    final all = _follow ? buffer.snapshot() : _frozen;
    final visible = _filter(all);
    final channels = {for (final entry in all) entry.channel}.toList()..sort();
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Toolbar(
          search: _search,
          following: _follow,
          onQuery: (value) => setState(() => _query = value),
          onFollow: _setFollow,
          onCopy: visible.isEmpty ? null : () => _copy(visible),
          onClear: () {
            ref.read(diagnosticsProvider).clear();
            _setFollow(true);
          },
        ),
        _Filters(
          minLevel: _minLevel,
          channel: channels.contains(_channel) ? _channel : null,
          channels: channels,
          onLevel: (value) => setState(() => _minLevel = value),
          onChannel: (value) => setState(() => _channel = value),
        ),
        const Divider(height: 1),
        Expanded(
          child: visible.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(Insets.lg),
                    child: Text(
                      all.isEmpty
                          ? 'Nothing has been logged yet.'
                          : 'Nothing matches these filters.',
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
          shown: visible.length,
          held: buffer.length,
          dropped: buffer.dropped,
          following: _follow,
        ),
      ],
    );
  }
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.search,
    required this.following,
    required this.onQuery,
    required this.onFollow,
    required this.onCopy,
    required this.onClear,
  });

  final TextEditingController search;
  final bool following;
  final ValueChanged<String> onQuery;
  final ValueChanged<bool> onFollow;
  final VoidCallback? onCopy;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Insets.sm, Insets.sm, 2, Insets.xs),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: search,
              onChanged: onQuery,
              decoration: const InputDecoration(
                isDense: true,
                hintText: 'Filter lines',
                prefixIcon: Icon(AppIcons.magnifyingGlass, size: Chrome.icon),
                prefixIconConstraints: BoxConstraints(minWidth: 30),
              ),
            ),
          ),
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
        ],
      ),
    );
  }
}

class _Filters extends StatelessWidget {
  const _Filters({
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
    final style = Theme.of(context).textTheme.labelSmall;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Insets.sm, 0, Insets.sm, Insets.xs),
      child: Row(
        children: [
          Expanded(
            child: DropdownButton<Level>(
              value: minLevel,
              isExpanded: true,
              isDense: true,
              underline: const SizedBox.shrink(),
              style: style,
              // `DropdownButton` is Material 2 and the app's
              // `dropdownMenuTheme` reaches only Material 3's `DropdownMenu`,
              // so its chevron ignored the theme and came out at Material's
              // 24 px beside a `Chrome.icon` toolbar one row above it. The
              // text style was already the panel's; the glyph was not.
              iconSize: Chrome.icon,
              items: [
                for (final (label, level) in _levelFilters)
                  DropdownMenuItem(value: level, child: Text(label)),
              ],
              onChanged: (value) => value == null ? null : onLevel(value),
            ),
          ),
          const SizedBox(width: Insets.sm),
          Expanded(
            child: DropdownButton<String?>(
              value: channel,
              isExpanded: true,
              isDense: true,
              underline: const SizedBox.shrink(),
              style: style,
              iconSize: Chrome.icon,
              items: [
                const DropdownMenuItem(
                  value: null,
                  child: Text('All channels'),
                ),
                for (final name in channels)
                  DropdownMenuItem(value: name, child: Text(name)),
              ],
              onChanged: onChannel,
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
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(entry.timestamp, style: dim),
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
      ),
    );
  }
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({
    required this.shown,
    required this.held,
    required this.dropped,
    required this.following,
  });

  final int shown;
  final int held;
  final int dropped;
  final bool following;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final parts = [
      '$shown shown',
      '$held held',
      if (dropped > 0) '$dropped dropped',
      if (!following) 'paused',
    ];
    return Container(
      // The panel's own footer is a status bar, and the window already has a
      // token for how tall one of those is; 22 was that number, unnamed.
      height: Chrome.statusBar,
      padding: const EdgeInsets.symmetric(horizontal: Insets.md),
      color: theme.colorScheme.surfaceContainerLowest,
      alignment: Alignment.centerLeft,
      child: Text(parts.join('  ·  '), style: theme.textTheme.labelSmall),
    );
  }
}
