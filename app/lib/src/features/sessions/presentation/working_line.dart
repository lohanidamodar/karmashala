import 'dart:async';

import 'package:agent_cli/descriptors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import '../../../core/util/clock_provider.dart';
import 'package:karmashala_ui/rows.dart';
import '../../agents/application/session_token_totals.dart'
    show formatTokenCount;
import '../application/acp_session_providers.dart';
import '../application/session_activity_providers.dart';
import '../application/session_plan_providers.dart';
import '../application/session_status_providers.dart';
import '../application/session_usage_providers.dart';

/// What the line says about a turn, read from the agent's status — the parts
/// that change it, and nothing that moves on every reading.
typedef _Turn = ({bool working, String? word, DateTime? since, int? tokens});

_Turn _turnOf(AgentStatusReport? report) {
  final working =
      report != null &&
      report.turnStatus == AgentActivityStatus.working &&
      !report.hasOpenPrompt &&
      !report.hasOpenQuestion;
  final detail = working ? report.working : null;
  return (
    working: working,
    word: detail?.word,
    since: detail?.since,
    tokens: detail?.tokens,
  );
}

/// **The chat's live "working" line**, under the last message while a turn
/// runs, like the terminal's spinner line: the agent's own word, what it is on
/// or "Working…", the turn's time, its tokens, and "Esc to stop" where Esc
/// stops it. Nothing between turns, nor while the agent asks — its card shows
/// then.
class WorkingLine extends ConsumerStatefulWidget {
  const WorkingLine({
    required this.sessionId,
    this.escStops = false,
    super.key,
  });

  final String sessionId;

  /// Esc stops the turn here, so a pointer surface names the key as quiet
  /// text. The composer's ■ is the one Stop control (owner, 2026-10-08).
  final bool escStops;

  @override
  ConsumerState<WorkingLine> createState() => _WorkingLineState();
}

class _WorkingLineState extends ConsumerState<WorkingLine> {
  Timer? _tick;

  /// When this line first saw the turn, for a server too old to say when it
  /// began: a count from here is short, never invented.
  DateTime? _firstSeen;

  @override
  void didUpdateWidget(WorkingLine old) {
    super.didUpdateWidget(old);
    if (old.sessionId != widget.sessionId) _firstSeen = null;
  }

  @override
  void dispose() {
    // Cancelled in the widget's own teardown, not left to a provider scope: a
    // scope's auto-dispose is itself cancelled when the tree unmounts.
    _tick?.cancel();
    _tick = null;
    super.dispose();
  }

  /// One timer per line, armed only while it counts. Safe from `build`: it
  /// schedules, it does not set state.
  void _startTicking() {
    _tick ??= Timer.periodic(kActivityTickInterval, (_) => setState(() {}));
  }

  void _stopTicking() {
    _tick?.cancel();
    _tick = null;
  }

  @override
  Widget build(BuildContext context) {
    final turn = ref.watch(
      agentSessionStatusProvider(
        widget.sessionId,
      ).select((status) => _turnOf(status.asData?.value)),
    );
    if (!turn.working) {
      _stopTicking();
      _firstSeen = null;
      return const SizedBox.shrink();
    }
    final now = ref.read(clockProvider).nowUtc();
    _firstSeen ??= now;
    // **Nothing ticks for a surface nobody can see.** `Visibility.of`, not
    // `TickerMode.of`: an `IndexedStack` only wraps a `_VisibilityScope`.
    // Still drawn while hidden, so it is the right size when it comes back.
    if (Visibility.of(context)) {
      _startTicking();
    } else {
      _stopTicking();
    }

    final activity = ref.watch(
      sessionOutstandingCallsProvider(widget.sessionId),
    );
    final running = activity.calls;
    final subagents = running.where((call) => call.isSubagent).length;
    final oldest = running.isEmpty
        ? null
        : running.reduce((a, b) => a.startedAt.isBefore(b.startedAt) ? a : b);

    // The agent's own word first; then what it is on; then its plan's step.
    final String headline;
    if (turn.word case final word?) {
      headline = word;
    } else if (running.length == 1) {
      headline = running.single.summary;
    } else if (running.isNotEmpty) {
      headline = describeRunningMix(running.length, subagents);
    } else {
      final step = ref
          .watch(sessionAgentPlanProvider(widget.sessionId))
          .plan
          ?.current
          ?.text
          .split('\n')
          .first
          .trim();
      headline = step == null || step.isEmpty ? 'Working…' : step;
    }

    final since = turn.since ?? oldest?.startedAt ?? _firstSeen!;
    final elapsed = now.difference(since);
    final time = formatElapsed(elapsed.isNegative ? Duration.zero : elapsed);
    final tokens = _tokensLabel(turn.tokens);
    final meta = [time, ?tokens].join(' · ');

    final theme = Theme.of(context);
    final colour = SemanticColors.of(context).working;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    // A phone has no Esc to name.
    final escHint = widget.escStops && !UiDensity.of(context).isTouch;
    final spot = activity.blindSpot;
    final tooltip = [
      for (final call in running)
        '${call.isSubagent ? 'Subagent ' : ''}${call.summary} · '
            '${formatElapsed(call.ageAt(now))}',
      if (spot != null) activityBlindSpotDetail(spot),
    ].join('\n');

    Widget line = Row(
      children: [
        // The app's own "working" glyph and colour, so this and the status
        // badge cannot describe one session in two languages. Still under
        // reduced motion: the ring steps only when motion is allowed.
        if (subagents > 0)
          Icon(AppIcons.robot, size: Chrome.iconSmall, color: colour)
        else
          WorkingSpinner(size: Chrome.iconSmall, color: colour),
        const SizedBox(width: Insets.sm),
        Flexible(
          child: Text(
            headline,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: muted,
          ),
        ),
        Flexible(
          child: Text(
            ' · $meta',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: muted,
          ),
        ),
      ],
    );
    if (tooltip.isNotEmpty) line = Tooltip(message: tooltip, child: line);

    return Semantics(
      // Deliberately not a live region: the time changes every second, and a
      // screen reader announcing it every second would be unusable.
      label: [
        if (running.length == 1 && turn.word == null)
          '${running.single.isSubagent ? 'Subagent' : 'Tool'} running: '
              '$headline'
        else
          'Working: $headline',
        meta,
      ].join(', '),
      child: Padding(
        key: const ValueKey('chat-working-line'),
        padding: const EdgeInsets.only(top: Insets.xs, bottom: Insets.sm),
        child: !escHint
            ? line
            : LayoutBuilder(
                // Too narrow, and the hint would crowd out what is running.
                builder: (context, box) => box.maxWidth < UiDensity.compactWidth
                    ? line
                    : Row(
                        children: [
                          Expanded(child: line),
                          const SizedBox(width: Insets.sm),
                          ExcludeSemantics(
                            child: Text(
                              'Esc to stop',
                              key: const ValueKey('chat-working-esc-hint'),
                              maxLines: 1,
                              style: muted,
                            ),
                          ),
                        ],
                      ),
              ),
      ),
    );
  }

  /// The agent's own count off its line; else, for a chat session, the
  /// context its agent reports in use — said as that, not as the turn's.
  String? _tokensLabel(int? tokens) {
    if (tokens != null) return '${formatTokenCount(tokens)} tokens';
    if (!ref.watch(isAcpSessionProvider(widget.sessionId))) return null;
    final used = ref.watch(
      sessionUsageProvider(widget.sessionId).select((u) => u?.contextUsed),
    );
    return used == null ? null : '${formatTokenCount(used)} in context';
  }
}

/// The longer form of a blind spot, for the tooltip: the line says only
/// "Working…" when nothing here records what on.
String activityBlindSpotDetail(ActivityBlindSpot spot) => switch (spot) {
  ActivityBlindSpot.noRecord =>
    'The status says this session is working. Nothing this app can read '
        'records which call is in flight, so it is named as unknown rather '
        'than shown as none.',
};
