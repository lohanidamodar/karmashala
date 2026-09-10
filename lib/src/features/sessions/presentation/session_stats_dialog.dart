import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/dialogs.dart';
import '../../agents/application/agent_providers.dart';
import 'package:agent_cli/usage.dart';
import '../application/session_providers.dart';
import '../application/session_signals.dart';
import '../application/session_stats_providers.dart';

/// What one session has cost, in counts, on demand. **Counts only, never
/// money**: a price table drifts the moment a model is repriced.
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
            : (view.agentName.isEmpty ? null : view.agentName),
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Two sections, one scroll, never a tab strip: they come from different
        // books, can honestly disagree, and each carries its own provenance.
        _SessionSection(view: view),
        _LifetimeSection(view: view),
        const SizedBox(height: Insets.md),
        Text(
          'Counts only \u2014 no cost estimate, and not a bill: these are what '
          'the agents wrote down, which can differ from what a vendor charges. '
          'Live quota is in the status bar.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _SessionSection extends StatelessWidget {
  const _SessionSection({required this.view});

  final SessionStatsView view;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final reason = view.unavailable;
    if (reason != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const _Section('This session', first: true),
          Text(
            sessionStatsExplanation(reason, view.agentName),
            style: theme.textTheme.bodySmall,
          ),
        ],
      );
    }

    final stats = view.stats!;
    final tokens = stats.tokens;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _Section(
          'This session',
          first: true,
          provenance: sessionStatsProvenance(view),
        ),
        _StatRow('Turns', formatStatCount(stats.turns)),
        _StatRow('Replies', formatStatCount(stats.replies)),
        _StatRow('Tool calls', formatStatCount(stats.toolCalls)),
        _StatRow('Input tokens', formatStatCount(tokens.input)),
        _StatRow('Output tokens', formatStatCount(tokens.output)),
        _StatRow('Cache created', formatStatCount(tokens.cacheCreated)),
        _StatRow('Cache read', formatStatCount(tokens.cacheRead)),
        // Only where the agent breaks it out — Claude Code folds thinking into
        // its output count and there is no honest number to print.
        if (tokens.reasoning != null)
          _StatRow('of which reasoning', formatStatCount(tokens.reasoning)),
        _StatRow(
          'Total tokens',
          formatStatCount(tokens.total),
          emphasise: true,
        ),
        if (stats.contextWindow != null)
          _StatRow('Context window', formatStatCount(stats.contextWindow)),
        _StatRow('First activity', formatStatMoment(stats.firstActivityAt)),
        _StatRow('Last activity', formatStatMoment(stats.lastActivityAt)),
        _StatRow('Elapsed', formatStatSpan(stats.span)),
        const SizedBox(height: Insets.xs),
        Text(
          'Elapsed is first record to last, not time spent working.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _LifetimeSection extends StatelessWidget {
  const _LifetimeSection({required this.view});

  final SessionStatsView view;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lifetime = view.lifetime;
    if (lifetime == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const _Section('All time'),
          Text(
            lifetimeStatsExplanation(
              view.lifetimeUnavailable ??
                  LifetimeStatsUnavailable.agentKeepsNoAggregate,
              view.agentName,
            ),
            style: theme.textTheme.bodySmall,
          ),
        ],
      );
    }

    final tokens = lifetime.tokens;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _Section(
          'All time',
          provenance: lifetimeStatsProvenance(lifetime, view.agentName),
        ),
        _StatRow(
          lifetime.source == LifetimeStatsSource.agentIndex
              ? 'Threads'
              : 'Sessions',
          formatStatCount(lifetime.sessions),
        ),
        if (lifetime.messages != null)
          _StatRow('Messages', formatStatCount(lifetime.messages)),
        _StatRow('Input tokens', formatStatCount(tokens.input)),
        _StatRow('Output tokens', formatStatCount(tokens.output)),
        _StatRow('Cache created', formatStatCount(tokens.cacheCreated)),
        _StatRow('Cache read', formatStatCount(tokens.cacheRead)),
        _StatRow(
          'Total tokens',
          formatStatCount(lifetime.totalTokens),
          emphasise: true,
        ),
        _StatRow('First activity', formatStatMoment(lifetime.firstActivityAt)),
        _StatRow('Last activity', formatStatMoment(lifetime.lastActivityAt)),
        // The source's own caveat, in its own words: these numbers do not count
        // what the section above counts.
        if (lifetime.note case final note?) ...[
          const SizedBox(height: Insets.xs),
          Text(
            note,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.label, {this.provenance, this.first = false});

  final String label;

  /// Where this section's numbers came from. Per section, never once: two books
  /// under one unlabelled heading read as a bug.
  final String? provenance;

  final bool first;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(top: first ? 0 : Insets.lg, bottom: Insets.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label.toUpperCase(),
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              letterSpacing: 0.8,
            ),
          ),
          if (provenance case final line?)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                line,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
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

/// The composer's stats control, in [MessageComposer]'s `chips` slot because
/// the question is about *this* session. Hidden where a store records nothing.
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
      message:
          'Turns, tokens and tool calls for this session, counted from '
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

  /// Whether this session's agent keeps a store with counts in it. Read rather
  /// than awaited, so nothing draws a control that opens onto an apology.
  bool _recordsStats(WidgetRef ref) {
    final session = ref.read(sessionDaoProvider).getById(sessionId);
    if (session == null) return false;
    final agentId = ref
        .read(agentInstallationDaoProvider)
        .getById(session.agentInstallationId)
        ?.agentId;
    if (agentId == null) return false;
    return agentStoreRecordsStats(
      ref.read(agentRegistryProvider).byId(agentId),
    );
  }
}

/// What is printed where a route could not supply a number. A word, not a zero:
/// "0 tool calls" and "we were never told" are different claims.
const String kStatNotRecorded = 'not recorded';

/// Where the numbers came from, in the dialog's own words.
String sessionStatsProvenance(SessionStatsView view) {
  final agent = view.agentName.isEmpty ? 'the agent' : view.agentName;
  if (view.unavailable != null) return 'Nothing to count';
  return switch (view.stats!.source) {
    SessionStatsSource.localStore =>
      'Computed from $agent\u2019s own record '
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

/// Where the lifetime numbers came from, and how far behind they can be: the
/// cache can report fewer sessions than the store beside it holds.
String lifetimeStatsProvenance(LifetimeStats lifetime, String agentName) {
  final agent = agentName.isEmpty ? 'The agent' : agentName;
  switch (lifetime.source) {
    case LifetimeStatsSource.agentIndex:
      return '$agent\u2019s own thread index, kept current as it runs.';
    case LifetimeStatsSource.agentCache:
      final written = lifetime.computedAt;
      final when = written == null
          ? ''
          : ', last written ${formatStatDay(written)} '
                '(${formatStatAge(written)})';
      return '$agent\u2019s own /stats cache$when. It is rewritten only when '
          'that screen is run, so it can be older \u2014 and smaller \u2014 '
          'than the session above.';
  }
}

/// Why there are no lifetime totals, in full sentences.
String lifetimeStatsExplanation(
  LifetimeStatsUnavailable reason,
  String agentName,
) {
  final agent = agentName.isEmpty ? 'This agent' : agentName;
  return switch (reason) {
    LifetimeStatsUnavailable.agentKeepsNoAggregate =>
      '$agent keeps no lifetime totals of its own, and this app does not add '
          'sessions together to invent them \u2014 a store where one session '
          'can replay another\u2019s history is exactly where that goes wrong.',
    LifetimeStatsUnavailable.sourceNotFound =>
      '$agent keeps lifetime totals, but none could be read on this machine. '
          'Its own stats have probably never been computed here.',
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

/// A whole day, in local time. Used where the source records a date and not an
/// instant — printing 00:00 beside it would be a precision it does not have.
String formatStatDay(DateTime value) {
  final at = value.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${at.year}-${two(at.month)}-${two(at.day)}';
}

/// How long ago, at one unit. [now] is injectable so the wording is testable
/// without the clock moving under the assertion.
String formatStatAge(DateTime at, {DateTime? now}) {
  final elapsed = (now ?? DateTime.now()).difference(at);
  if (elapsed.isNegative || elapsed.inMinutes < 1) return 'just now';
  if (elapsed.inHours < 1) {
    return '${elapsed.inMinutes} minute${elapsed.inMinutes == 1 ? '' : 's'} ago';
  }
  if (elapsed.inDays < 1) {
    return '${elapsed.inHours} hour${elapsed.inHours == 1 ? '' : 's'} ago';
  }
  return '${elapsed.inDays} day${elapsed.inDays == 1 ? '' : 's'} ago';
}
