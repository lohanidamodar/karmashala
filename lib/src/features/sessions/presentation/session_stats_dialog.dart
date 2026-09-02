import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../../app/widgets/desktop_dialog.dart';
import '../../agents/application/agent_providers.dart';
import '../../cli_detection/domain/session_stats.dart';
import '../application/session_providers.dart';
import '../application/session_signals.dart';
import '../application/session_stats_providers.dart';

/// What one session has cost, in counts, on demand.
///
/// **Counts only, never money.** A dollar figure needs a price table compiled
/// into the app, and a price table drifts the moment a model is repriced — the
/// known weakness of every open-source usage monitor. Real quota already lives
/// elsewhere in the app; this is the work the session did.
///
/// Every number here is **computed from the agent's own store**, and the dialog
/// says so. Nothing is typed into the user's live session to obtain it: both
/// agents that keep a readable transcript also record their usage in it, so the
/// route that would have written a slash command into a running pane turned out
/// to have nobody left to serve — see `SessionStatsService`.
class SessionStatsDialog extends ConsumerWidget {
  const SessionStatsDialog({required this.sessionId, super.key});

  final String sessionId;

  static Future<void> show(BuildContext context, String sessionId) =>
      showDialog<void>(
        context: context,
        builder: (_) => SessionStatsDialog(sessionId: sessionId),
      );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(sessionStatsProvider(sessionId));
    final view = async.asData?.value;

    return AlertDialog(
      title: DesktopDialogTitle(
        icon: AppIcons.listMagnifyingGlass,
        title: 'Session stats',
        subtitle: view == null
            ? (async.hasError ? 'Could not be read' : 'Reading the store…')
            : sessionStatsProvenance(view),
      ),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: switch (async) {
            AsyncValue(hasError: true, :final error) => DesktopErrorBanner(
              'The store could not be read: $error',
            ),
            AsyncValue(:final value?) => _Body(view: value),
            _ => const Padding(
              padding: EdgeInsets.symmetric(vertical: Insets.xl),
              child: Center(child: CircularProgressIndicator()),
            ),
          },
        ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(
        Insets.lg,
        0,
        Insets.lg,
        Insets.md,
      ),
      actions: [
        TextButton(
          autofocus: true,
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.view});

  final SessionStatsView view;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final reason = view.unavailable;
    if (reason != null) {
      return Padding(
        padding: const EdgeInsets.only(bottom: Insets.sm),
        child: Text(
          sessionStatsExplanation(reason, view.agentName),
          style: theme.textTheme.bodySmall,
        ),
      );
    }

    final stats = view.stats!;
    final tokens = stats.tokens;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const _Section('Conversation'),
        _StatRow('Turns', formatStatCount(stats.turns)),
        _StatRow('Replies', formatStatCount(stats.replies)),
        _StatRow('Tool calls', formatStatCount(stats.toolCalls)),
        const _Section('Tokens'),
        _StatRow('Input', formatStatCount(tokens.input)),
        _StatRow('Output', formatStatCount(tokens.output)),
        _StatRow('Cache created', formatStatCount(tokens.cacheCreated)),
        _StatRow('Cache read', formatStatCount(tokens.cacheRead)),
        // Only where the agent breaks it out — Claude Code folds thinking into
        // its output count and there is no honest number to print.
        if (tokens.reasoning != null)
          _StatRow('of which reasoning', formatStatCount(tokens.reasoning)),
        _StatRow('Total', formatStatCount(tokens.total), emphasise: true),
        if (stats.contextWindow != null)
          _StatRow('Context window', formatStatCount(stats.contextWindow)),
        const _Section('Timing'),
        _StatRow('First activity', formatStatMoment(stats.firstActivityAt)),
        _StatRow('Last activity', formatStatMoment(stats.lastActivityAt)),
        _StatRow('Elapsed', formatStatSpan(stats.span)),
        const SizedBox(height: Insets.md),
        Text(
          'Counts only — no cost estimate. Elapsed is first record to last, '
          'not time spent working.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: Insets.md, bottom: Insets.xs),
      child: Text(
        label.toUpperCase(),
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}

class _StatRow extends StatelessWidget {
  const _StatRow(this.label, this.value, {this.emphasise = false});

  final String label;
  final String value;
  final bool emphasise;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final unknown = value == kStatNotRecorded;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: Text(label, style: theme.textTheme.bodySmall)),
          const SizedBox(width: Insets.sm),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: MonoStyles.body.copyWith(
                color: unknown
                    ? theme.colorScheme.onSurfaceVariant
                    : theme.colorScheme.onSurface,
                fontWeight: emphasise ? FontWeight.w600 : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The composer's stats control.
///
/// Lives in [MessageComposer]'s `chips` slot rather than the status bar: the
/// question is about *this* session, and the composer is the one row on screen
/// that is already about this session and nothing else. It hides itself for an
/// agent whose store records nothing — an affordance that can only ever say
/// "there is nothing here" is worse than no affordance.
class SessionStatsButton extends ConsumerWidget {
  const SessionStatsButton({required this.sessionId, super.key});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The row is what names the agent, and moving a session onto a different
    // CLI conversation is a write to this row.
    ref.watchSession(sessionId);
    if (!_recordsStats(ref)) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Tooltip(
      message: 'Turns, tokens and tool calls for this session, counted from '
          'the agent\u2019s own record',
      child: InkWell(
        onTap: () => SessionStatsDialog.show(context, sessionId),
        borderRadius: BorderRadius.circular(Radii.sm),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: Insets.sm,
            vertical: 3,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Radii.sm),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                AppIcons.listMagnifyingGlass,
                size: Chrome.iconSmall,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: Insets.xs),
              Text(
                'Stats',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Whether this session's agent keeps a store with counts in it.
  ///
  /// Read here rather than awaited, so an agent that has nothing to show never
  /// draws a control that opens onto an apology. The dialog still explains the
  /// case, for anyone who reaches it another way.
  bool _recordsStats(WidgetRef ref) {
    final session = ref.read(sessionDaoProvider).getById(sessionId);
    if (session == null) return false;
    final agentId = ref
        .read(agentInstallationDaoProvider)
        .getById(session.agentInstallationId)
        ?.agentId;
    if (agentId == null) return false;
    return agentStoreRecordsStats(ref.read(agentRegistryProvider).byId(agentId));
  }
}

/// What is printed where a route could not supply a number.
///
/// A word, not a zero: "0 tool calls" and "we were never told" are different
/// claims and only one of them is true.
const String kStatNotRecorded = 'not recorded';

/// Where the numbers came from, in the dialog's own words.
String sessionStatsProvenance(SessionStatsView view) {
  final agent = view.agentName.isEmpty ? 'the agent' : view.agentName;
  if (view.unavailable != null) return 'Nothing to count';
  return switch (view.stats!.source) {
    SessionStatsSource.localStore => 'Computed from $agent\u2019s own record '
        'on this machine',
    SessionStatsSource.agentOutput => 'Asked $agent directly',
  };
}

/// Why there is nothing to show, in full sentences.
String sessionStatsExplanation(
  SessionStatsUnavailable reason,
  String agentName,
) {
  final agent = agentName.isEmpty ? 'This agent' : agentName;
  return switch (reason) {
    SessionStatsUnavailable.unknownSession =>
      'This session is no longer in the workspace, so there is nothing left '
          'to count.',
    SessionStatsUnavailable.agentRecordsNoCounts =>
      '$agent records no counts. Its store keeps identity, a working '
          'directory and a name; the messages themselves are in a format this '
          'app cannot read, and the CLI publishes no command that would print '
          'the numbers instead. Nothing is being withheld — there is nothing '
          'on disk to add up.',
    SessionStatsUnavailable.transcriptNotFound =>
      '$agent has not written a file for this session yet. A CLI creates one '
          'when it starts its first turn, so a session that has been opened '
          'and not yet spoken to has nothing to count.',
  };
}

/// A count, grouped, or [kStatNotRecorded] when the route did not supply one.
String formatStatCount(int? value) {
  if (value == null) return kStatNotRecorded;
  final digits = value.abs().toString();
  final buffer = StringBuffer(value.isNegative ? '-' : '');
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
    buffer.write(digits[i]);
  }
  return buffer.toString();
}

/// A moment, to the minute and in local time, or [kStatNotRecorded].
String formatStatMoment(DateTime? value) {
  if (value == null) return kStatNotRecorded;
  final at = value.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${at.year}-${two(at.month)}-${two(at.day)} '
      '${two(at.hour)}:${two(at.minute)}';
}

/// An elapsed span at two units of precision, or [kStatNotRecorded].
String formatStatSpan(Duration? value) {
  if (value == null) return kStatNotRecorded;
  if (value.inSeconds < 60) return '${value.inSeconds}s';
  if (value.inMinutes < 60) return '${value.inMinutes}m';
  if (value.inHours < 24) {
    return '${value.inHours}h ${value.inMinutes % 60}m';
  }
  return '${value.inDays}d ${value.inHours % 24}h';
}
