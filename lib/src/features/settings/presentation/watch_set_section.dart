import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/design_tokens.dart';
import '../../notifications/application/notification_providers.dart';
import '../../notifications/application/session_status_registry.dart';
import 'settings_row.dart';
import 'settings_section.dart';

/// How much of the watch set the status registry is reaching, as the last cycle
/// measured it — `null` until a cycle has run.
///
/// A `StreamProvider` over the registry's own edge-triggered report, so the row
/// repaints when the measurement moves and not once every 1.2-second cycle.
final sessionStatusCoverageProvider =
    StreamProvider.autoDispose<SessionStatusCoverage?>(
      (ref) => ref.watch(sessionStatusRegistryProvider).coverageReports,
    );

/// Settings → Diagnostics: **is anything silently not being watched?**
///
/// The P0 behind this was a status watcher that capped its watch set at 60
/// sessions, and the reason it survived to production is that nobody could
/// tell. Membership is uncapped now and the probe rotation reserves a share
/// priority traffic cannot take, so coverage is guaranteed by construction —
/// but a guarantee nobody can observe fails the same way the next time somebody
/// adds a limit for a good reason. This is where a person can see it without a
/// debugger or a log file.
///
/// The modern shape of the same bug is not "we stopped watching", it is "we are
/// watching and never getting round to it", which is why the rotation period is
/// a row of its own rather than a detail.
class WatchSetSection extends ConsumerWidget {
  const WatchSetSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    // Loading and "no cycle has run" are the same fact to a reader: nothing has
    // been measured that this could show.
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
                      'Every session Chitragupta holds a status for. Nothing '
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

  /// What the other half of the watch set costs, and whether it is keeping up.
  ///
  /// `neverProbed` is deliberately phrased as *queued*: a session waiting its
  /// turn has an entry, a status and a place in the rotation, and reading that
  /// number as a loss is how someone "fixes" a healthy rotation.
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
