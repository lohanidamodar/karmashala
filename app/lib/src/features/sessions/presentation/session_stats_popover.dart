import 'dart:math' as math;

import 'package:agent_cli/usage.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/charts.dart';
import 'package:karmashala_ui/panes.dart' show EyebrowLabel;
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../agents/presentation/usage_window_meter.dart';
import '../../agents/application/agent_providers.dart';
import '../application/project_week.dart';
import '../application/session_chat_source.dart';
import '../application/session_providers.dart';
import '../application/session_stats_providers.dart';
import 'session_stats_dialog.dart'
    show
        formatStatCount,
        formatStatSpan,
        sessionStatsExplanation,
        sessionStatsProvenance;
import 'session_stats_sections.dart';

/// The width the popover is laid out at, window permitting. Fixed rather than
/// "at most": it sits in a [MenuAnchor], which sizes its panel from intrinsic
/// widths, and a tight width answers that question without asking the charts
/// inside. 360 leaves the week chart the 320px it needs for its day labels.
const double kSessionStatsPopoverWidth = 360;

/// The popover's inner padding, which the week chart's width is worked out
/// from.
const double _pad = Insets.md;

/// The week chart's height: bars plus the day labels under them.
const double _weekChartHeight = 96;

/// How many tools "tool calls by name" lists before the rest become a line.
const int _topTools = 5;

/// How many more turns fit in the context window at this session's average
/// growth per turn, or null where that cannot be estimated.
///
/// The newest request's size over the turns so far is the average each turn
/// has added. That average includes the fixed system prompt, so it overstates
/// the growth and the estimate errs short — the safe side for a warning. Null
/// unless the prompt, the window and at least two turns were recorded: one
/// turn is all system prompt and would say almost nothing is left.
int? turnsLeftEstimate(SessionStats stats) {
  final used = stats.lastPromptTokens,
      window = stats.contextWindow,
      turns = stats.turns;
  if (used == null || window == null || turns == null) return null;
  if (window <= 0 || used <= 0 || turns < 2) return null;
  if (used >= window) return 0;
  return ((window - used) / (used / turns)).floor();
}

/// **Session stats** (spec §5), opened from the context chip on the pane's
/// status line: how full the context is and about how many turns are left;
/// turns, tool calls, tokens and elapsed; tokens by kind; tool calls by name;
/// output per turn; and this project's week. Every value the agent never
/// recorded says so in words — "not recorded" and zero are different claims.
///
/// Calm per spec §3, as the account usage card: the raised tone, the floating
/// hairline, a popover radius, 13px rows and 11px uppercase group labels.
///
/// **No LayoutBuilder anywhere under it.** The menu measures its content's
/// intrinsic size, which a LayoutBuilder refuses, and a card that fails that
/// closes as it opens. The width is fixed; the meters and bars are painters
/// that ask nothing; the one chart that does lay out by constraints, the
/// week's [BarChart], sits in [_TightChartBox], which answers for it.
/// What a switched session's counts cover, in words, or null for a session
/// one agent ran: the record they are read from is the running agent's
/// alone. Read off the chat when it is open, whose turns name their agent.
String? statsSinceSwitchNote(WidgetRef ref, String sessionId) {
  final messages =
      (ref.exists(sessionChatTranscriptProvider(sessionId))
          ? ref.read(sessionChatTranscriptProvider(sessionId)).value
          : null) ??
      const [];
  if (!messages.any((m) => m.agentInstallationId != null)) return null;
  final installation = ref
      .read(sessionsDataProvider)
      .getById(sessionId)
      ?.agentInstallationId;
  final agentId = installation == null
      ? null
      : ref.read(agentInstallationsDataProvider).getById(installation)?.agentId;
  final name = agentId == null
      ? 'the current agent'
      : ref.read(agentRegistryProvider).displayNameFor(agentId);
  return 'Since switching to $name — earlier agents of this thread are '
      'not counted.';
}

class SessionStatsPopover extends ConsumerWidget {
  const SessionStatsPopover({required this.sessionId, super.key});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tones = SurfaceTones.of(context);
    final body13 = theme.textTheme.bodyMedium?.copyWith(
      fontSize: TypeSizes.body,
    );
    final meta = theme.textTheme.bodySmall?.copyWith(
      fontSize: TypeSizes.label,
      color: scheme.onSurfaceVariant,
    );

    // The window can be narrower than the card at a large text size or a
    // small window; the card gives way rather than overflow it.
    final screen = MediaQuery.sizeOf(context);
    final width = math.max(
      200.0,
      math.min(kSessionStatsPopoverWidth, screen.width - Insets.lg * 2),
    );
    final inner = width - _pad * 2;

    final async = ref.watch(sessionStatsProvider(sessionId));
    final view = async.asData?.value;
    final title = view?.sessionTitle?.trim();
    final since = statsSinceSwitchNote(ref, sessionId);

    final header = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          header: true,
          child: Text(
            'Session stats',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: body13?.copyWith(fontWeight: FontWeight.w600),
          ),
        ),
        if (title != null && title.isNotEmpty)
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: meta,
          ),
        if (since != null)
          Text(since, key: const ValueKey('stats-since-switch'), style: meta),
      ],
    );

    final List<Widget> body = switch (async) {
      AsyncValue(hasError: true, :final error) => [
        const SizedBox(height: Insets.sm),
        Text('The agent’s record could not be read: $error', style: meta),
      ],
      AsyncValue(:final value?) => _bodyOf(context, value, inner, meta),
      _ => const [
        Padding(
          padding: EdgeInsets.symmetric(vertical: Insets.lg),
          child: Center(
            child: InlineSpinner(
              semanticsLabel: 'Reading the session’s own record',
            ),
          ),
        ),
      ],
    };

    final maxHeight = screen.height - Insets.xl * 2;
    return SizedBox(
      width: width,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: maxHeight < 160 ? 160 : maxHeight,
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: tones.raised,
            border: Border.all(color: tones.floatingLine),
            borderRadius: BorderRadius.circular(Radii.lg),
            boxShadow: Shadows.floating,
          ),
          child: DefaultTextStyle(
            style: body13 ?? const TextStyle(fontSize: TypeSizes.body),
            child: Padding(
              padding: const EdgeInsets.all(_pad),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  header,
                  // A card taller than the window scrolls its body; the
                  // header stays.
                  Flexible(
                    child: SingleChildScrollView(
                      primary: false,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: body,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _bodyOf(
    BuildContext context,
    SessionStatsView view,
    double inner,
    TextStyle? meta,
  ) {
    final reason = view.unavailable;
    final stats = view.stats;
    final notABill = stats?.reportedCost == null
        ? 'Counts only — not a bill.'
        : 'Counts, and the cost as the agent reported it — not a bill.';
    final footer = [
      const SizedBox(height: Insets.md),
      Text('${sessionStatsProvenance(view)}. $notABill', style: meta),
    ];
    if (reason != null || stats == null) {
      return [
        const SizedBox(height: Insets.sm),
        Text(
          sessionStatsExplanation(
            reason ?? SessionStatsUnavailable.transcriptNotFound,
            view.agentName,
          ),
          style: meta,
        ),
        const _GroupLabel('This project’s week'),
        _ProjectWeekSection(sessionId: sessionId, width: inner, meta: meta),
        ...footer,
      ];
    }
    final byName = stats.toolCallsByName;
    final perTurn = stats.outputTokensPerTurn;
    final contextPerTurn = stats.contextUsedPerTurn;
    final agent = view.agentName.isEmpty ? 'the agent' : view.agentName;
    return [
      const _GroupLabel('Context'),
      _ContextHeader(stats: stats, agentName: view.agentName, meta: meta),
      if (stats.reportedCost case final cost?) ...[
        const SizedBox(height: Insets.xs),
        Text(
          '${formatReportedCost(cost)} so far, as $agent reported it.',
          style: meta,
        ),
      ],
      const SizedBox(height: Insets.md),
      _FigureRow(stats: stats, meta: meta),
      const _GroupLabel('Tokens by kind'),
      if (stats.tokens.isUnknown)
        Text('Token counts are $kStatNotRecorded.', style: meta)
      else
        _TokensByKind(tally: stats.tokens, meta: meta),
      const _GroupLabel('Tool calls by name'),
      if (byName == null)
        Text('Tool names are $kStatNotRecorded.', style: meta)
      else if (byName.isEmpty)
        Text(
          stats.toolCalls == 0
              ? 'No tool calls yet.'
              : 'No tool call recorded its name.',
          style: meta,
        )
      else
        _ToolCalls(byName: byName, total: stats.toolCalls, meta: meta),
      if (perTurn == null && contextPerTurn != null) ...[
        const _GroupLabel('Context per turn'),
        if (contextPerTurn.length < 2)
          Text(
            contextPerTurn.isEmpty
                ? 'No turn has finished yet.'
                : 'One turn so far: '
                      '${formatCompactCount(contextPerTurn.single)} tokens '
                      'in context.',
            style: meta,
          )
        else
          ContextPerTurn(perTurn: contextPerTurn),
      ] else ...[
        const _GroupLabel('Output per turn'),
        if (perTurn == null)
          Text('Output per turn is $kStatNotRecorded.', style: meta)
        else if (perTurn.length < 2)
          Text(
            perTurn.isEmpty
                ? 'No turn has finished yet.'
                : 'One turn so far: ${formatCompactCount(perTurn.single)} '
                      'output tokens.',
            style: meta,
          )
        else
          _OutputPerTurn(
            perTurn: perTurn,
            reasoningPerTurn: stats.reasoningTokensPerTurn,
            meta: meta,
          ),
      ],
      const _GroupLabel('This project’s week'),
      _ProjectWeekSection(sessionId: sessionId, width: inner, meta: meta),
      ...footer,
    ];
  }
}

/// An 11px uppercase group label, with the air above it that separates one
/// group of the card from the last.
class _GroupLabel extends StatelessWidget {
  const _GroupLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Semantics(
    header: true,
    child: EyebrowLabel(
      text,
      maxLines: 1,
      padding: const EdgeInsets.only(top: Insets.md, bottom: Insets.xs),
    ),
  );
}

/// How full the context was at the newest request — the percentage, a meter in
/// the usage severity colours, and about how many turns are left — or, where
/// the prompt or the window was not recorded, a sentence saying which.
class _ContextHeader extends StatelessWidget {
  const _ContextHeader({
    required this.stats,
    required this.agentName,
    required this.meta,
  });

  final SessionStats stats;
  final String agentName;
  final TextStyle? meta;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fill = contextFill(stats);
    if (fill == null) {
      final agent = agentName.isEmpty ? 'this agent' : agentName;
      return Text(switch ((stats.lastPromptTokens, stats.contextWindow)) {
        (final u?, null) =>
          'The newest request sent ${formatCompactCount(u)} tokens. The '
              'context window is $kStatNotRecorded by $agent, so neither the '
              'share used nor the turns left can be said.',
        (null, final w?) =>
          'Context window ${formatCompactCount(w)} tokens. The size of the '
              'newest request is $kStatNotRecorded, so turns left cannot be '
              'said.',
        _ => 'Context use and turns left are $kStatNotRecorded.',
      }, style: meta);
    }
    final percent = fill * 100;
    final color = usageSeverityColor(context, usageSeverityFor(percent));
    final used = formatCompactCount(stats.lastPromptTokens!);
    final window = formatCompactCount(stats.contextWindow!);
    final left = turnsLeftEstimate(stats);
    final leftWords = switch (left) {
      null => 'turns left $kStatNotRecorded — too few turns to estimate',
      0 => 'no turns left',
      1 => 'about 1 turn left',
      final n => 'about ${formatStatCount(n)} turns left',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              '${percent.round()}%',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(width: Insets.sm),
            Expanded(
              child: Text(
                'context used · $used of $window',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: meta?.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: Insets.xs),
        LinearMeter(
          value: fill,
          color: color,
          semanticsLabel:
              'Context: the newest request sent $used of $window tokens, '
              '${percent.round()}%; $leftWords',
        ),
        const SizedBox(height: Insets.xs),
        ExcludeSemantics(
          child: Text(
            left == null
                ? '${leftWords[0].toUpperCase()}${leftWords.substring(1)}.'
                : '${leftWords[0].toUpperCase()}${leftWords.substring(1)} '
                      'at this session’s average growth per turn.',
            style: meta,
          ),
        ),
      ],
    );
  }
}

/// Turns, tool calls, tokens and elapsed, side by side.
class _FigureRow extends StatelessWidget {
  const _FigureRow({required this.stats, required this.meta});

  final SessionStats stats;
  final TextStyle? meta;

  @override
  Widget build(BuildContext context) {
    final total = stats.tokens.total;
    final span = stats.span;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: _Figure(
            label: 'Turns',
            value: stats.turns == null ? null : formatStatCount(stats.turns),
            meta: meta,
          ),
        ),
        Expanded(
          child: _Figure(
            label: 'Tool calls',
            value: stats.toolCalls == null
                ? null
                : formatStatCount(stats.toolCalls),
            meta: meta,
          ),
        ),
        Expanded(
          child: _Figure(
            label: 'Tokens',
            value: total == null ? null : formatCompactCount(total),
            meta: meta,
          ),
        ),
        Expanded(
          child: Tooltip(
            message: 'First record to last, not time spent working.',
            child: _Figure(
              label: 'Elapsed',
              value: span == null ? null : formatStatSpan(span),
              meta: meta,
            ),
          ),
        ),
      ],
    );
  }
}

/// One figure: its number (or "not recorded", smaller and muted) over its
/// label.
class _Figure extends StatelessWidget {
  const _Figure({required this.label, required this.value, required this.meta});

  final String label;
  final String? value;
  final TextStyle? meta;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final value = this.value;
    return MergeSemantics(
      child: Padding(
        padding: const EdgeInsets.only(right: Insets.xs),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              value ?? kStatNotRecorded,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: value == null
                  ? meta
                  : theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
            ),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: meta,
            ),
          ],
        ),
      ),
    );
  }
}

/// One small bar per kind — input, output, cache read, cache write — scaled
/// to the largest; a kind that was not recorded gets words and no bar.
class _TokensByKind extends StatelessWidget {
  const _TokensByKind({required this.tally, required this.meta});

  final TokenTally tally;
  final TextStyle? meta;

  static const _order = [
    TokenKind.input,
    TokenKind.output,
    TokenKind.cacheRead,
    TokenKind.cacheWrite,
  ];

  @override
  Widget build(BuildContext context) {
    final total = tally.total;
    final top = _order
        .map((k) => k.of(tally) ?? 0)
        .fold<int>(0, (m, v) => math.max(m, v));
    final reasoning = tally.reasoning, output = tally.output;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final kind in _order)
          _BarRow(
            label: kind.label,
            swatch: tokenKindColor(context, kind),
            fraction: switch (kind.of(tally)) {
              null => null,
              final v => top <= 0 ? 0 : v / top,
            },
            valueLabel: switch (kind.of(tally)) {
              null => null,
              final v =>
                total == null || total <= 0
                    ? formatCompactCount(v)
                    : '${formatCompactCount(v)} · '
                          '${formatShare(v, total) ?? '0%'}',
            },
            meta: meta,
          ),
        if (reasoning != null)
          Padding(
            padding: const EdgeInsets.only(top: Insets.xs),
            child: Text(
              'Of the output, ${formatCompactCount(reasoning)} was reasoning'
              '${output == null || output <= 0 ? '' : ' (${formatShare(reasoning, output)})'}'
              '.',
              style: meta,
            ),
          ),
      ],
    );
  }
}

/// A label, a meter and its number on one 22px line — or the label and "not
/// recorded" where [fraction] is null, since an empty bar would read as zero.
class _BarRow extends StatelessWidget {
  const _BarRow({
    required this.label,
    required this.swatch,
    required this.fraction,
    required this.valueLabel,
    required this.meta,
  });

  final String label;
  final Color swatch;
  final double? fraction;
  final String? valueLabel;
  final TextStyle? meta;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fraction = this.fraction;
    final spoken = '$label: ${valueLabel ?? kStatNotRecorded}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: MergeSemantics(
        child: Row(
          children: [
            SizedBox(
              width: 88,
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
            ),
            const SizedBox(width: Insets.sm),
            if (fraction == null)
              Expanded(
                child: Semantics(
                  label: spoken,
                  excludeSemantics: true,
                  child: Text(kStatNotRecorded, style: meta),
                ),
              )
            else ...[
              Expanded(
                child: LinearMeter(
                  value: fraction,
                  color: swatch,
                  semanticsLabel: spoken,
                ),
              ),
              const SizedBox(width: Insets.sm),
              ExcludeSemantics(
                child: Text(
                  valueLabel!,
                  maxLines: 1,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The busiest tools as bars, and what did not make the cut in words.
class _ToolCalls extends StatelessWidget {
  const _ToolCalls({
    required this.byName,
    required this.total,
    required this.meta,
  });

  final Map<String, int> byName;
  final int? total;
  final TextStyle? meta;

  @override
  Widget build(BuildContext context) {
    final ranked = rankToolCalls(byName, total, limit: _topTools);
    String calls(int n) => '$n ${n == 1 ? 'call' : 'calls'}';
    // RankedBars is rows of Text and painted meters — nothing in it asks its
    // constraints, so the menu's intrinsic questions are answered.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        RankedBars(
          color: SemanticColors.of(context).working,
          bars: [
            for (final (name, count) in ranked.top)
              BarDatum(
                label: name,
                value: count.toDouble(),
                valueLabel: formatCompactCount(count),
              ),
          ],
        ),
        if (ranked.otherTools > 0)
          Text(
            '${ranked.otherTools} more '
            '${ranked.otherTools == 1 ? 'tool' : 'tools'}, '
            '${calls(ranked.otherCalls)}.',
            style: meta,
          ),
        if (ranked.unnamed > 0)
          Text(
            '${calls(ranked.unnamed)} with no tool name recorded.',
            style: meta,
          ),
      ],
    );
  }
}

/// Output tokens per turn as a sparkline, with the peak and average in words,
/// and the thinking band and legend where the agent breaks thinking out.
/// [Sparkline] sizes itself with a LimitedBox, not a LayoutBuilder, so it is
/// safe here as it stands; the legend is a [Wrap] of text.
class _OutputPerTurn extends StatelessWidget {
  const _OutputPerTurn({
    required this.perTurn,
    required this.reasoningPerTurn,
    required this.meta,
  });

  final List<int> perTurn;
  final List<int>? reasoningPerTurn;
  final TextStyle? meta;

  @override
  Widget build(BuildContext context) {
    final summary = perTurnSummary(perTurn);
    final reasoning = reasoningPerTurn;
    final segments = reasoning == null
        ? null
        : thinkingSegments(context, perTurn, reasoning);
    final hue = tokenKindColor(context, TokenKind.output);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Sparkline(
          values: [for (final v in perTurn) v.toDouble()],
          secondaryValues: reasoning == null
              ? null
              : [for (final v in reasoning) v.toDouble()],
          secondaryColor: hue,
          color: hue,
          height: 32,
          semanticsLabel:
              'Output tokens per turn. $summary'
              '${segments == null ? '' : '. ${thinkingSummary(segments)}'}',
        ),
        const SizedBox(height: Insets.xs),
        ExcludeSemantics(child: Text(summary, style: meta)),
        if (segments != null) ...[
          const SizedBox(height: Insets.xs),
          ExcludeSemantics(child: ChartLegend(segments: segments)),
        ],
      ],
    );
  }
}

/// This project's week: tokens by the day each of its sessions was last
/// active, as bars, with the attribution and any unrecorded sessions said.
/// Read only while the popover is open.
class _ProjectWeekSection extends ConsumerWidget {
  const _ProjectWeekSection({
    required this.sessionId,
    required this.width,
    required this.meta,
  });

  final String sessionId;
  final double width;
  final TextStyle? meta;

  static const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(projectWeekProvider(sessionId));
    final week = async.asData?.value;
    if (async.hasError && week == null) {
      return Text('This project’s week could not be read.', style: meta);
    }
    if (async.isLoading && week == null) {
      return Text('Reading this project’s sessions…', style: meta);
    }
    if (week == null) {
      return Text('This session is in no project.', style: meta);
    }
    if (week.sessions == 0) {
      return Text(
        'No session of ${week.projectName} recorded activity this week.',
        style: meta,
      );
    }
    String sessions(int n) => '$n ${n == 1 ? 'session' : 'sessions'}';
    final notes = <String>[
      'Each session’s tokens count on the day it was last active.',
      if (week.uncounted > 0)
        '${sessions(week.uncounted)} recorded no tokens and '
            '${week.uncounted == 1 ? 'is' : 'are'} not in the bars.',
    ];
    if (week.tokens == 0) {
      return Text(
        '${sessions(week.sessions)} of ${week.projectName} this week; token '
        'counts are $kStatNotRecorded for '
        '${week.sessions == 1 ? 'it' : 'any of them'}.',
        style: meta,
      );
    }
    final bars = [
      for (final day in week.days)
        BarDatum(
          label: _weekdays[day.day.weekday - 1],
          value: day.tokens.toDouble(),
          valueLabel: switch (day) {
            ProjectWeekDay(sessions: 0) => 'no sessions',
            ProjectWeekDay(sessions: final count, :final uncounted)
                when uncounted == count =>
              'tokens $kStatNotRecorded',
            _ =>
              '${formatCompactCount(day.tokens)} tokens · '
                  '${sessions(day.sessions)}',
          },
        ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _TightChartBox(
          width: width,
          height: _weekChartHeight,
          child: BarChart(
            bars: bars,
            color: SemanticColors.of(context).working,
            height: _weekChartHeight,
            semanticsLabel:
                '${week.projectName} this week: '
                '${formatCompactCount(week.tokens)} tokens across '
                '${sessions(week.sessions)}. '
                '${bars.map((b) => '${b.label} ${b.spoken}').join(', ')}',
          ),
        ),
        const SizedBox(height: Insets.xs),
        for (final note in notes) Text(note, style: meta),
      ],
    );
  }
}

/// A box of a fixed size that **answers intrinsic and dry-layout questions
/// itself** and hands its child that size as tight constraints.
///
/// [BarChart] lays out through a LayoutBuilder, which cannot answer an
/// intrinsic or dry-layout question; a [MenuAnchor] asks them of everything in
/// its panel, and a failed answer closes the card as it opens. A plain SizedBox
/// forwards some of those questions to its child; this does not, so the child
/// is only ever laid out. A copy of the usage card's box, kept private to each
/// card so neither's layout depends on the other's file.
class _TightChartBox extends SingleChildRenderObjectWidget {
  const _TightChartBox({
    required this.width,
    required this.height,
    required Widget super.child,
  });

  final double width;
  final double height;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderTightChartBox(Size(width, height));

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderTightChartBox renderObject,
  ) {
    renderObject.fixed = Size(width, height);
  }
}

class _RenderTightChartBox extends RenderProxyBox {
  _RenderTightChartBox(this._fixed);

  Size _fixed;
  set fixed(Size value) {
    if (value == _fixed) return;
    _fixed = value;
    markNeedsLayout();
  }

  @override
  double computeMinIntrinsicWidth(double height) => _fixed.width;

  @override
  double computeMaxIntrinsicWidth(double height) => _fixed.width;

  @override
  double computeMinIntrinsicHeight(double width) => _fixed.height;

  @override
  double computeMaxIntrinsicHeight(double width) => _fixed.height;

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      constraints.constrain(_fixed);

  @override
  double? computeDryBaseline(
    BoxConstraints constraints,
    TextBaseline baseline,
  ) => null;

  @override
  void performLayout() {
    size = constraints.constrain(_fixed);
    child?.layout(BoxConstraints.tight(size));
  }
}
