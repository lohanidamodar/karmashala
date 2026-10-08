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

part 'session_stats_popover/stats_rows.dart';
part 'session_stats_popover/project_week_section.dart';

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
