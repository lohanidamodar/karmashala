import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/charts.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/primitives.dart';
import '../../agents/application/agent_providers.dart';
import 'package:agent_cli/usage.dart';
import '../application/session_providers.dart';
import '../application/session_signals.dart';
import '../application/session_stats_providers.dart';
import 'agent_status_badge.dart';
import 'session_stats_sections.dart';

export 'session_stats_sections.dart' show kStatNotRecorded;

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
    final title = view?.sessionTitle?.trim();

    return AlertDialog(
      title: DesktopDialogTitle(
        icon: AppIcons.listMagnifyingGlass,
        title: 'Session stats',
        subtitle: view == null
            ? (async.hasError ? 'Could not be read' : 'Reading the store…')
            : (title == null || title.isEmpty ? null : title),
      ),
      content: BoundedDialogContent(
        width: DialogWidth.wide,
        child: switch (async) {
          AsyncValue(hasError: true, :final error) => ClipRRect(
            borderRadius: BorderRadius.circular(Radii.sm),
            child: PaneNoticeBar(
              icon: AppIcons.warningCircle,
              tone: NoticeTone.danger,
              maxLines: 6,
              message: 'The store could not be read: $error',
            ),
          ),
          AsyncValue(:final value?) => SessionStatsBody(
            view: value,
            status: AgentStatusBadge(sessionId: sessionId, showLabel: true),
          ),
          _ => const Padding(
            padding: EdgeInsets.symmetric(vertical: Insets.xl),
            child: Center(
              child: InlineSpinner(
                size: InlineSpinnerSize.large,
                semanticsLabel: 'Reading the session’s own record',
              ),
            ),
          ),
        },
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

/// The dialog's body for one [view]: this session, then all time, then the
/// caveat. [status] is the live badge, a slot so the body stays a plain value.
class SessionStatsBody extends StatelessWidget {
  const SessionStatsBody({required this.view, this.status, super.key});

  final SessionStatsView view;
  final Widget? status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _MetaLine(view: view, status: status),
        // Two sections, one scroll, never a tab strip: they come from different
        // books, can honestly disagree, and each carries its own provenance.
        _SessionSection(view: view),
        _LifetimeSection(view: view),
        const SizedBox(height: Insets.lg),
        Text(
          'Counts only — no cost estimate, and not a bill: these are what '
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

/// Status · agent · models · last active, on one wrapping line.
class _MetaLine extends StatelessWidget {
  const _MetaLine({required this.view, this.status});

  final SessionStatsView view;
  final Widget? status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final stats = view.stats;
    final models = stats?.tokensByModel?.keys.toList() ?? const <String>[];
    final last = stats?.lastActivityAt;
    final facts = [
      if (view.agentName.isNotEmpty)
        Text(
          view.agentName,
          style: theme.textTheme.bodySmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
      if (models.isNotEmpty)
        Text(
          models.length == 1
              ? models.single
              : '${models.first} +${models.length - 1} more',
          style: muted,
        ),
      if (last != null)
        Text('Last active ${formatStatAge(last)}', style: muted),
    ];
    if (status == null && facts.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: Insets.lg),
      child: Wrap(
        spacing: Insets.sm,
        runSpacing: Insets.xs,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          ?status,
          for (var i = 0; i < facts.length; i++) ...[
            if (i > 0 || status != null)
              ExcludeSemantics(child: Text('·', style: muted)),
            facts[i],
          ],
        ],
      ),
    );
  }
}

class _SessionSection extends StatelessWidget {
  const _SessionSection({required this.view});

  final SessionStatsView view;

  @override
  Widget build(BuildContext context) {
    final reason = view.unavailable;
    if (reason != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          const StatsSectionHeading('This session', first: true),
          _Notice(sessionStatsExplanation(reason, view.agentName)),
        ],
      );
    }

    final stats = view.stats!;
    final tokens = stats.tokens;
    final total = tokens.total;
    final cache = cacheReadShare(tokens);
    final hasContext =
        stats.lastPromptTokens != null || stats.contextWindow != null;
    final perTurn = stats.outputTokensPerTurn;
    final byModel = stats.tokensByModel;
    final byName = stats.toolCallsByName;
    final replies = stats.replies;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        StatsSectionHeading(
          'This session',
          first: true,
          detail: sessionStatsProvenance(view),
        ),
        StatTileGrid(
          tiles: [
            StatTile(
              label: 'Total tokens',
              value: total == null ? null : formatCompactCount(total),
              caption: total == null ? null : formatStatCount(total),
              unrecorded: kStatNotRecorded,
            ),
            StatTile(
              label: 'Turns',
              value: _count(stats.turns),
              caption: replies == null
                  ? null
                  : '${formatStatCount(replies)} '
                        '${replies == 1 ? 'reply' : 'replies'}',
              unrecorded: kStatNotRecorded,
            ),
            StatTile(
              label: 'Tool calls',
              value: _count(stats.toolCalls),
              unrecorded: kStatNotRecorded,
            ),
            StatTile(
              label: 'Elapsed',
              value: stats.span == null ? null : formatStatSpan(stats.span),
              caption: 'first to last record',
              tooltip:
                  'Elapsed is first record to last, not time spent '
                  'working.',
              unrecorded: kStatNotRecorded,
            ),
          ],
        ),
        StatsNote(
          'First record ${formatStatMoment(stats.firstActivityAt)} · '
          'last ${formatStatMoment(stats.lastActivityAt)}',
        ),
        const StatsBlockLabel('Tokens'),
        if (tokens.isUnknown)
          const StatsNote('Token counts are $kStatNotRecorded.')
        else ...[
          TokenSplit(tally: tokens),
          if (cache != null) ...[
            const SizedBox(height: Insets.sm),
            CacheReadMeter(share: cache),
          ],
        ],
        if (hasContext) ...[
          const StatsBlockLabel('Context'),
          ContextUsage(stats: stats, agentName: view.agentName),
        ],
        if (perTurn != null && perTurn.length >= 2) ...[
          const StatsBlockLabel('Output per turn'),
          OutputPerTurn(perTurn: perTurn),
        ],
        if (byModel != null && byModel.length >= 2) ...[
          const StatsBlockLabel('By model'),
          TokensByModel(byModel: byModel),
        ],
        if (byName != null && byName.isNotEmpty) ...[
          const StatsBlockLabel('Tool calls by name'),
          ToolCallsByName(byName: byName, total: stats.toolCalls),
        ],
      ],
    );
  }
}

String? _count(int? value) => value == null ? null : formatStatCount(value);

class _LifetimeSection extends StatelessWidget {
  const _LifetimeSection({required this.view});

  final SessionStatsView view;

  @override
  Widget build(BuildContext context) {
    final lifetime = view.lifetime;
    if (lifetime == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          const StatsSectionHeading('All time'),
          _Notice(
            lifetimeStatsExplanation(
              view.lifetimeUnavailable ??
                  LifetimeStatsUnavailable.agentKeepsNoAggregate,
              view.agentName,
            ),
          ),
        ],
      );
    }

    final tokens = lifetime.tokens;
    final total = lifetime.totalTokens;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        StatsSectionHeading(
          'All time',
          detail: lifetimeStatsProvenance(lifetime, view.agentName),
        ),
        StatTileGrid(
          tiles: [
            StatTile(
              label: lifetime.source == LifetimeStatsSource.agentIndex
                  ? 'Threads'
                  : 'Sessions',
              value: _count(lifetime.sessions),
              unrecorded: kStatNotRecorded,
            ),
            if (lifetime.messages != null)
              StatTile(
                label: 'Messages',
                value: _count(lifetime.messages),
                unrecorded: kStatNotRecorded,
              ),
            StatTile(
              label: 'Total tokens',
              value: total == null ? null : formatCompactCount(total),
              caption: total == null ? null : formatStatCount(total),
              unrecorded: kStatNotRecorded,
            ),
          ],
        ),
        StatsNote(
          'First activity ${formatStatMoment(lifetime.firstActivityAt)} · '
          'last ${formatStatMoment(lifetime.lastActivityAt)}',
        ),
        if (!tokens.isUnknown) ...[
          const StatsBlockLabel('Tokens'),
          TokenSplit(tally: tokens),
        ],
        // The source's own caveat, in its own words: these numbers do not count
        // what the section above counts.
        if (lifetime.note case final note?) StatsNote(note),
      ],
    );
  }
}

/// Why a section has nothing to show, as a notice rather than a bare paragraph.
class _Notice extends StatelessWidget {
  const _Notice(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(Radii.sm),
      child: PaneNoticeBar(icon: AppIcons.info, message: message, maxLines: 8),
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
    final session = ref.read(sessionsDataProvider).getById(sessionId);
    if (session == null) return false;
    final agentId = ref
        .read(agentInstallationDaoProvider)
        .getById(session.agentInstallationId)
        ?.agentId;
    if (agentId == null) return false;
    return agentStoreRecordsStats(
      ref.read(agentRegistryProvider).adapterFor(agentId),
    );
  }
}

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
