import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/tokens.dart';
import '../../notifications/application/notification_providers.dart';
import '../../notifications/application/session_status_registry.dart';
import 'settings_row.dart';
import 'settings_section.dart';

/// How much of the watch set the status registry reaches, as the last cycle
/// measured it — `null` until one has run. Edge-triggered, so the row does not
/// repaint every 1.2-second cycle.
final sessionStatusCoverageProvider =
    StreamProvider.autoDispose<SessionStatusCoverage?>(
      (ref) => ref.watch(sessionStatusRegistryProvider).coverageReports,
    );

/// Settings → Diagnostics: **is anything silently not being watched?** A status
/// watcher once capped its watch set at 60 sessions and nobody could tell;
/// coverage is by construction now, but only a guarantee someone can see holds.
class WatchSetSection extends ConsumerWidget {
  const WatchSetSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    // Loading and "no cycle has run" are the same fact to a reader.
    final coverage = ref.watch(sessionStatusCoverageProvider).asData?.value;

    return SettingsSection(
      title: 'SESSION WATCHING',
      child: coverage == null
          ? Text(
              'Nothing measured yet. The status watcher starts with the app '
              'and reports here after its first pass.',
              style: theme.textTheme.bodySmall,
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SettingsRow(
                  label: 'Sessions watched',
                  help:
                      'Every session Karmashala holds a status for. Nothing '
                      'is capped by list position, so a number below the '
                      'sessions you can see is a bug worth reporting.',
                  control: _Value('${coverage.tracked}'),
                ),
                SettingsRow(
                  label: 'Answered by hooks',
                  help: _probeHelp(coverage),
                  control: _Value(
                    '${coverage.hookAnswered} of ${coverage.tracked}',
                  ),
                ),
                SettingsRow(
                  label: 'Slowest status refresh',
                  help:
                      'The longest a session with no hook installed waits for '
                      'its transcript to be read again. Hook-backed sessions '
                      'never wait for it.',
                  control: _Value(_rotation(coverage.rotationPeriod)),
                ),
                if (coverage.isBehind)
                  Padding(
                    padding: const EdgeInsets.only(top: Insets.sm),
                    child: Text(
                      'The status fallback is behind: '
                      '${coverage.probeCandidates} sessions need a transcript '
                      'read and the rotation takes '
                      '${_rotation(coverage.rotationPeriod)} to come back '
                      'round. Statuses for sessions without hooks will be '
                      'stale.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ),
              ],
            ),
    );
  }

  /// `neverProbed` is phrased as *queued*: read as a loss, someone would
  /// "fix" a healthy rotation.
  static String _probeHelp(SessionStatusCoverage coverage) {
    if (coverage.probeCandidates == 0) {
      return 'Every watched session reports its own status, so nothing has to '
          'be read from disk.';
    }
    return '${coverage.probeCandidates} need their transcript read instead; '
        '${coverage.probed} were read on the last pass and '
        '${coverage.neverProbed} are still queued for a first read'
        '${coverage.probeFailures == 0 ? '' : ', and ${coverage.probeFailures} '
                  'could not be read at all'}.';
  }

  static String _rotation(Duration? period) =>
      period == null ? 'never' : 'every ${period.inSeconds}s';
}

/// The right-hand half of a diagnostics row: a fact, not a control.
class _Value extends StatelessWidget {
  const _Value(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      text,
      textAlign: TextAlign.end,
      style: theme.textTheme.bodyMedium?.copyWith(
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}
