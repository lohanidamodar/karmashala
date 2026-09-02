import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../../core/logging/build_identity.dart';
import '../../../core/logging/diagnostics_providers.dart';
import '../../../core/logging/log_entry.dart';
import 'companion_chrome.dart';

/// The companion's own log, on the phone that produced it.
///
/// The desktop has had `LogsPanel` all along; the phone had nothing. Its log
/// file exists but lives in the app-support directory, which on Android is not
/// somewhere a person can reach — so the evidence for "it just says connecting"
/// was on the device and unreachable, which is the same as not existing. Copy
/// is therefore the real feature here: what a bug report needs is the text, in
/// a message, from the phone that saw the problem.
///
/// Deliberately not a live tail. A phone that cannot connect is not producing
/// lines quickly, and a screen that repaints itself while being read is worse
/// than a Refresh button — so this snapshots on open and on pull-to-refresh.
class CompanionLogScreen extends ConsumerStatefulWidget {
  const CompanionLogScreen({super.key});

  static Future<void> show(BuildContext context) => Navigator.of(
    context,
  ).push(MaterialPageRoute<void>(builder: (_) => const CompanionLogScreen()));

  @override
  ConsumerState<CompanionLogScreen> createState() => _CompanionLogScreenState();
}

class _CompanionLogScreenState extends ConsumerState<CompanionLogScreen> {
  /// Held rather than read in `build`, so scrolling and copying act on the
  /// same lines the reader is looking at rather than on a ring that has moved.
  late List<LogEntry> _entries = _read();

  /// Warnings and errors only. The default, because a phone's whole log is
  /// mostly link chatter and the lines that explain a failure are the ones
  /// nobody should have to scroll for.
  bool _problemsOnly = true;

  List<LogEntry> _read() => ref.read(diagnosticsProvider).buffer.snapshot();

  List<LogEntry> get _visible => _problemsOnly
      ? [
          for (final e in _entries)
            if (e.level >= Level.WARNING) e,
        ]
      : _entries;

  Future<void> _refresh() async => setState(() => _entries = _read());

  Future<void> _copy() async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final lines = _visible;
    // The identity line first, and always — a pasted log whose version is
    // unknown cannot answer the first question anyone asks of it, and the one
    // in the buffer may already have been evicted by a long session.
    final text = [
      buildIdentity(),
      for (final entry in lines) entry.format(withDate: true),
    ].join('\n');
    await Clipboard.setData(ClipboardData(text: text));
    messenger?.showSnackBar(
      SnackBar(content: Text('Copied ${lines.length} log lines.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final density = UiDensity.of(context);
    final visible = _visible;
    final dropped = ref.read(diagnosticsProvider).buffer.dropped;

    return Scaffold(
      appBar: companionAppBar(
        context,
        title: const Text('Diagnostics'),
        actions: [
          IconButton(
            tooltip: _problemsOnly ? 'Show everything' : 'Problems only',
            icon: Icon(
              _problemsOnly ? AppIcons.warning : AppIcons.listMagnifyingGlass,
            ),
            onPressed: () => setState(() => _problemsOnly = !_problemsOnly),
          ),
          IconButton(
            tooltip: 'Copy',
            icon: const Icon(AppIcons.copy),
            onPressed: visible.isEmpty ? null : _copy,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          padding: EdgeInsets.all(density.padX),
          children: [
            SelectableText(buildIdentity(), style: MonoStyles.label),
            if (dropped > 0)
              Text(
                '$dropped earlier lines have been dropped.',
                style: density.muted(theme),
              ),
            const Divider(),
            if (visible.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: Insets.xl),
                child: Text(
                  _problemsOnly
                      ? 'No warnings or errors this run. Show everything to '
                            'see what the link has been doing.'
                      : 'Nothing logged yet.',
                  textAlign: TextAlign.center,
                  // Prose, not a caption: this is the sentence that stops the
                  // screen looking broken, and it was set at the size the log
                  // lines beside it use for metadata.
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              )
            else
              // Selectable as one block rather than per row: the useful
              // gesture on a phone is "take all of this", and the Copy button
              // above is the shortcut for exactly that.
              SelectableText(
                [for (final entry in visible) entry.format()].join('\n'),
                style: MonoStyles.label,
              ),
          ],
        ),
      ),
    );
  }
}
