import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';

import 'package:karmashala_core/logging.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../core/logging/diagnostics_providers.dart';

/// More › Log: this app's own log, on the phone that wrote it (open question
/// 10). Copy is the feature: the log folder is unreachable on a phone. A
/// snapshot, not a live tail; pull or Refresh reads it again.
class PhoneLogPage extends ConsumerStatefulWidget {
  const PhoneLogPage({super.key});

  @override
  ConsumerState<PhoneLogPage> createState() => _PhoneLogPageState();
}

class _PhoneLogPageState extends ConsumerState<PhoneLogPage> {
  /// Held, so scrolling and copying act on the lines on screen.
  late List<LogEntry> _entries = _read();

  /// Warnings and errors by default: most of a phone's log is link chatter.
  bool _problemsOnly = true;

  List<LogEntry> _read() => ref.read(diagnosticsProvider).buffer.snapshot();

  List<LogEntry> get _visible => _problemsOnly
      ? [
          for (final entry in _entries)
            if (entry.level >= Level.WARNING) entry,
        ]
      : _entries;

  Future<void> _refresh() async => setState(() => _entries = _read());

  Future<void> _copy(List<LogEntry> lines) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    // The identity always: the buffer's own line may have been evicted.
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
    final visible = _visible;
    final dropped = ref.read(diagnosticsProvider).buffer.dropped;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            Insets.lg,
            Insets.xs,
            Insets.xs,
            0,
          ),
          child: Row(
            children: [
              FilterChip(
                label: const Text('Problems only'),
                selected: _problemsOnly,
                onSelected: (value) => setState(() => _problemsOnly = value),
              ),
              const Spacer(),
              IconButton(
                tooltip: 'Refresh',
                icon: const Icon(AppIcons.arrowClockwise),
                onPressed: _refresh,
              ),
              IconButton(
                tooltip: 'Copy',
                icon: const Icon(AppIcons.copy),
                onPressed: visible.isEmpty ? null : () => _copy(visible),
              ),
            ],
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _refresh,
            child: ListView(
              padding: const EdgeInsets.all(Insets.lg),
              children: [
                SelectableText(buildIdentity(), style: MonoStyles.label),
                if (dropped > 0)
                  Text(
                    '$dropped earlier lines have been dropped.',
                    style: theme.textTheme.bodySmall,
                  ),
                const Divider(),
                if (visible.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: Insets.xl),
                    child: Text(
                      _problemsOnly
                          ? 'No warnings or errors this run. Turn off '
                                'Problems only to see everything.'
                          : 'Nothing logged yet.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  )
                else
                  // One block: on a phone the useful gesture is "take it all".
                  SelectableText(
                    [for (final entry in visible) entry.format()].join('\n'),
                    style: MonoStyles.label,
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
