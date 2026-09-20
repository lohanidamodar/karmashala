import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_core/logging.dart';
import '../application/companion_runtime.dart';
import 'companion_chrome.dart';
import 'companion_route.dart';

/// The companion's own log, on the phone that produced it — Copy is the real
/// feature, since app-support is unreachable on Android. Not a live tail.
class CompanionLogScreen extends ConsumerStatefulWidget {
  const CompanionLogScreen({super.key});

  static Future<void> show(BuildContext context) => Navigator.of(
    context,
  ).push(companionRoute<void>(context, (_) => const CompanionLogScreen()));

  @override
  ConsumerState<CompanionLogScreen> createState() => _CompanionLogScreenState();
}

class _CompanionLogScreenState extends ConsumerState<CompanionLogScreen> {
  /// Held rather than read in `build`, so scrolling and copying act on the
  /// lines the reader is looking at and not on a ring that has moved.
  late List<LogEntry> _entries = _read();

  /// Warnings and errors only — the default, because a phone's whole log is
  /// mostly link chatter.
  bool _problemsOnly = true;

  List<LogEntry> _read() =>
      ref.read(companionDiagnosticsProvider).buffer.snapshot();

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
    // The identity line always: the one in the buffer may already have been
    // evicted, and a pasted log with no version answers nothing.
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
    final dropped = ref.read(companionDiagnosticsProvider).buffer.dropped;

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
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _refresh,
          child: ListView(
            padding: companionListInsets(context, EdgeInsets.all(density.padX)),
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
                    // screen looking broken.
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                )
              else
                // Selectable as one block: the useful gesture on a phone is
                // "take all of this".
                SelectableText(
                  [for (final entry in visible) entry.format()].join('\n'),
                  style: MonoStyles.label,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
