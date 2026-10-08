part of '../chat_transcript.dart';

/// How a turn ended, as its own record says.
enum TurnEnding { done, stopped, failed }

/// A finished turn's footer: how it ended, how long it ran and when.
@immutable
class TurnFooter {
  const TurnFooter({
    required this.ending,
    required this.elapsed,
    required this.endedAt,
  });

  final TurnEnding ending;
  final Duration elapsed;
  final DateTime endedAt;

  @override
  bool operator ==(Object other) =>
      other is TurnFooter &&
      other.ending == ending &&
      other.elapsed == elapsed &&
      other.endedAt == endedAt;

  @override
  int get hashCode => Object.hash(ending, elapsed, endedAt);
}

/// **Every finished turn's footer**, keyed by the index of the row it hangs
/// under — the turn's last word from the agent, its interruption or its
/// error. Timed by the record's own stamps, from the person's message to that
/// row; a turn missing either stamp gets none. The last turn only once
/// [lastTurnOver]: while it runs, the working line stands in its place.
///
/// [lastTurnStoppedAt] is a Stop pressed during the last turn, which ended
/// since: that turn reads stopped whatever the agent wrote after, and hangs
/// its footer on its last row when the agent wrote nothing.
Map<int, TurnFooter> turnFooters(
  List<ChatMessage> messages, {
  required bool lastTurnOver,
  DateTime? lastTurnStoppedAt,
}) {
  final starts = [
    for (var i = 0; i < messages.length; i++)
      if (_opensTurn(messages[i])) i,
  ];
  final out = <int, TurnFooter>{};
  for (var k = 0; k < starts.length; k++) {
    final last = k == starts.length - 1;
    if (last && !lastTurnOver) break;
    final from = starts[k];
    final to = last ? messages.length : starts[k + 1];
    final start = messages[from].at;
    final stoppedAt = last ? lastTurnStoppedAt : null;
    final stopped =
        stoppedAt != null && start != null && !stoppedAt.isBefore(start);
    var placed = false;
    for (var i = to - 1; i > from; i--) {
      final ending = _endingOf(messages[i]);
      if (ending == null) continue;
      placed = true;
      final end = messages[i].at;
      if (start != null && end != null && !end.isBefore(start)) {
        out[i] = TurnFooter(
          ending: stopped && ending == TurnEnding.done
              ? TurnEnding.stopped
              : ending,
          elapsed: end.difference(start),
          endedAt: end,
        );
      }
      break;
    }
    if (!placed && stopped) {
      out[to - 1] = TurnFooter(
        ending: TurnEnding.stopped,
        elapsed: stoppedAt.difference(start),
        endedAt: stoppedAt,
      );
    }
  }
  return out;
}

/// The person's own message: not an interruption the CLI wrote in their name,
/// nor one still waiting in the queue.
bool _opensTurn(ChatMessage message) =>
    message.role == 'user' &&
    !message.queued &&
    !_interruptionNote.hasMatch(message.text.trim());

TurnEnding? _endingOf(ChatMessage message) => switch (message.role) {
  'agent' => TurnEnding.done,
  'error' => TurnEnding.failed,
  'user' when _interruptionNote.hasMatch(message.text.trim()) =>
    TurnEnding.stopped,
  kTranscriptNoticeRole when message.text.startsWith('Interrupted') =>
    TurnEnding.stopped,
  _ => null,
};

/// `Crunched for 6s · 1.2k tokens · done 6:07 PM`, `Stopped after 6s · 6:07
/// PM`: one muted line under the turn, quieter than anything in it.
class _TurnFooterLine extends StatelessWidget {
  const _TurnFooterLine({required this.footer, this.verb, this.tokens});

  final TurnFooter footer;

  /// The agent's own past-tense word for this turn, when it left one.
  final String? verb;
  final int? tokens;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final time = MaterialLocalizations.of(context).formatTimeOfDay(
      TimeOfDay.fromDateTime(footer.endedAt.toLocal()),
      alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
    );
    final took = formatElapsed(footer.elapsed);
    final text = switch (footer.ending) {
      TurnEnding.done => [
        '${verb ?? 'Worked'} for $took',
        if (tokens case final tokens?) '${formatCompactCount(tokens)} tokens',
        'done $time',
      ].join(' · '),
      TurnEnding.stopped => 'Stopped after $took · $time',
      TurnEnding.failed => 'Failed after $took · $time',
    };
    return SelectionContainer.disabled(
      child: Padding(
        padding: const EdgeInsets.only(top: Insets.xs),
        child: Text(
          text,
          key: const ValueKey('chat-turn-footer'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
