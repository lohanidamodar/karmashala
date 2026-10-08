part of '../chat_transcript.dart';

/// What a turn's actions may do in this session. Its host leaves an action
/// null where the session can never do it, so it is not offered; [busy] and a
/// turn with no [forkPoints] entry disable one for now, saying why.
///
/// Compared by value: rows rebuild when it changes, so its host passes stable
/// callbacks (tear-offs).
class TranscriptTurnActions {
  const TranscriptTurnActions({
    this.onRetry,
    this.onEdit,
    this.onFork,
    this.onRewind,
    this.busy,
    this.forkPoints = const {},
    this.noForkPoint = kNoTurnCheckpoint,
  });

  /// Sends the person's words again, as a new turn.
  final void Function(String words)? onRetry;

  /// Puts the person's words in the composer to edit and send.
  final void Function(String words)? onEdit;

  /// Forks the session from [TurnForkTarget]; the host previews and asks.
  final void Function(TurnForkTarget target)? onFork;

  /// Rewinds the session to before the person's message; the host asks how.
  /// Offered on the person's own rows only.
  final void Function(TurnRewindTarget target)? onRewind;

  /// Why retry, edit and fork wait right now — a turn is running.
  final String? busy;

  /// Each turn's fork targets, by the ordinal of the message that opened it.
  final Map<int, TurnForkPoints> forkPoints;

  /// Why a turn with no entry in [forkPoints] cannot be forked.
  final String noForkPoint;

  @override
  bool operator ==(Object other) =>
      other is TranscriptTurnActions &&
      other.onRetry == onRetry &&
      other.onEdit == onEdit &&
      other.onFork == onFork &&
      other.onRewind == onRewind &&
      other.busy == busy &&
      other.noForkPoint == noForkPoint &&
      _sameForkPoints(other.forkPoints, forkPoints);

  @override
  int get hashCode => Object.hash(
    onRetry,
    onEdit,
    onFork,
    onRewind,
    busy,
    noForkPoint,
    forkPoints.length,
  );
}

/// What a turn with no checkpoint says about forking from it.
const String kNoTurnCheckpoint =
    'No checkpoint was taken at this turn, so there is nothing to fork from.';

bool _sameForkPoints(Map<int, TurnForkPoints> a, Map<int, TurnForkPoints> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (final MapEntry(:key, :value) in a.entries) {
    if (b[key] != value) return false;
  }
  return true;
}

/// Where a row stands in the conversation: the person's message that opened
/// its turn and their words in it.
@immutable
class _TurnPlace {
  const _TurnPlace({
    required this.start,
    required this.words,
    required this.isLatest,
    this.turnIndex = 0,
    this.rewound = false,
  });

  final int start;
  final String words;

  /// The turn's place among the transcript's turns, rewound ones too.
  final int turnIndex;

  /// A rewind already undid this turn.
  final bool rewound;

  /// Asked when an action runs, not kept: a new turn opening must not
  /// rebuild the rows of the one before.
  final bool Function(int start) isLatest;

  bool get latest => isLatest(start);

  @override
  bool operator ==(Object other) =>
      other is _TurnPlace &&
      other.start == start &&
      other.words == words &&
      other.turnIndex == turnIndex &&
      other.rewound == rewound &&
      other.isLatest == isLatest;

  @override
  int get hashCode => Object.hash(start, words, turnIndex, rewound);
}

/// The person's own words in a message that opened a turn: no automation's
/// label and no note Karmashala put ahead of them.
String _personsWords(ChatMessage message) {
  final sent = AutomationAttribution.split(message.text);
  return splitScratchPreamble(sent?.rest ?? message.text).rest.trim();
}

/// Each message's turn, as the index of the message that opened it; null
/// before the first. Linear in [messages].
List<int?> _turnStartsOf(List<ChatMessage> messages) {
  int? start;
  return [
    for (var i = 0; i < messages.length; i++)
      if (_opensTurn(messages[i])) start = i else start,
  ];
}

/// One turn action as the row offers it.
class _TurnAction {
  const _TurnAction({
    required this.id,
    required this.label,
    required this.icon,
    required this.run,
    this.disabledBecause,
  });

  final String id;
  final String label;
  final IconData icon;
  final Future<void> Function(BuildContext context) run;
  final String? disabledBecause;

  bool get enabled => disabledBecause == null;
}

/// The turn's actions a row offers — Retry, Edit and resend (the person's
/// row only), Fork from here — each disabled with its reason where it waits.
List<_TurnAction> _turnActionsFor({
  required TranscriptTurnActions actions,
  required _TurnPlace place,
  required bool user,
}) {
  final busy = actions.busy;
  final points = actions.forkPoints[place.start];
  final target = user ? points?.before : points?.after;
  return [
    if (actions.onRetry case final retry?)
      _TurnAction(
        id: 'retry',
        label: 'Retry',
        icon: AppIcons.arrowClockwise,
        disabledBecause: busy,
        run: (context) async {
          if (!place.latest) {
            final go = await showConfirmDialog(
              context,
              title: 'Send this message again?',
              message:
                  'It goes to the agent as a new turn. The conversation '
                  'continues from now, not from then: everything said since '
                  'stays in it.',
              confirmLabel: 'Send again',
            );
            if (!go) return;
          }
          retry(place.words);
        },
      ),
    if (user)
      if (actions.onEdit case final edit?)
        _TurnAction(
          id: 'edit',
          label: 'Edit and resend',
          icon: AppIcons.pencilSimple,
          disabledBecause: busy,
          run: (_) async => edit(place.words),
        ),
    if (user)
      if (actions.onRewind case final rewind?)
        _TurnAction(
          id: 'rewind',
          label: 'Rewind to here…',
          icon: AppIcons.arrowCounterClockwise,
          disabledBecause: place.rewound
              ? 'This message was already rewound.'
              : busy == null
              ? null
              : kRewindWhileWorking,
          run: (_) async => rewind(
            TurnRewindTarget(
              turnIndex: place.turnIndex,
              words: place.words,
              before: points?.before,
            ),
          ),
        ),
    if (actions.onFork case final fork?)
      _TurnAction(
        id: 'fork',
        label: 'Fork from here',
        icon: AppIcons.gitBranch,
        disabledBecause: busy ?? (target == null ? actions.noForkPoint : null),
        run: (_) async => fork(target!),
      ),
  ];
}

/// A row action that may be disabled, its tooltip then saying why.
class _TurnIconButton extends StatelessWidget {
  const _TurnIconButton({required this.action});

  final _TurnAction action;

  @override
  Widget build(BuildContext context) {
    final touch = UiDensity.of(context).isTouch;
    final floor = touch ? Touch.target : Insets.xl;
    final why = action.disabledBecause;
    return IconButton(
      key: ValueKey('chat-turn-${action.id}'),
      tooltip: why == null ? action.label : '${action.label}: $why',
      visualDensity: touch ? VisualDensity.standard : VisualDensity.compact,
      iconSize: touch ? Touch.icon : Chrome.iconSmall,
      constraints: BoxConstraints(minWidth: floor, minHeight: floor),
      padding: EdgeInsets.zero,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
      icon: Icon(action.icon),
      onPressed: why == null ? () => action.run(context) : null,
    );
  }
}

/// Touch: a turn's actions behind one ⋯, in a sheet of thumb-sized rows; a
/// disabled one says why under its name.
class _TurnMoreButton extends StatelessWidget {
  const _TurnMoreButton({required this.actions, required this.extra});

  final List<_TurnAction> actions;

  /// Copy turn and Save as note, which live in the sheet on touch too.
  final List<_TurnAction> extra;

  Future<void> _open(BuildContext context) async {
    final all = [...actions, ...extra];
    final picked = await showRowMenuSheet(context, 'This turn', [
      for (final action in all)
        if (action.enabled)
          DesktopMenuItem(
            value: action.id,
            label: action.label,
            icon: action.icon,
          )
        else
          DesktopMenuDetailItem(
            value: action.id,
            label: action.label,
            detail: action.disabledBecause!,
            icon: action.icon,
            detailMaxLines: 3,
            enabled: false,
          ),
    ]);
    if (picked == null || !context.mounted) return;
    for (final action in all) {
      if (action.id == picked && action.enabled) await action.run(context);
    }
  }

  @override
  Widget build(BuildContext context) => IconButton(
    key: const ValueKey('chat-turn-more'),
    tooltip: 'More for this turn',
    iconSize: Touch.icon,
    constraints: const BoxConstraints(
      minWidth: Touch.target,
      minHeight: Touch.target,
    ),
    padding: EdgeInsets.zero,
    color: Theme.of(context).colorScheme.onSurfaceVariant,
    icon: const Icon(AppIcons.dotsThree),
    onPressed: () => _open(context),
  );
}

/// The turn holding [index] as Markdown — what Copy turn copies: each side
/// under its own heading, each call one line with its time where recorded.
String transcriptTurnMarkdown(List<ChatMessage> messages, int index) {
  var start = index;
  while (start > 0 && messages[start].role != 'user') {
    start--;
  }
  var end = index + 1;
  while (end < messages.length && messages[end].role != 'user') {
    end++;
  }
  final parts = <String>[
    // A rewound turn is copied as what it is: kept, but undone.
    if (rewindFolds(
          messages.length,
          roleAt: (i) => messages[i].role,
          textAt: (i) => messages[i].text,
          opensTurn: (i) => _opensTurn(messages[i]),
        )[start] !=
        null)
      '_Rewound: this turn was undone._',
  ];
  String? heading;
  void under(String name, String body) {
    if (heading != name) {
      parts.add('### $name');
      heading = name;
    }
    parts.add(body);
  }

  for (var i = start; i < end; i++) {
    final message = messages[i];
    switch (message.role) {
      case 'user':
        final words = _personsWords(message);
        if (words.isNotEmpty) under('You', words);
      case 'agent':
        final (_, clean) = splitThinking(
          message.text,
          explicit: message.thinking,
        );
        if (clean.trim().isNotEmpty) under('Agent', clean.trim());
      case 'tool':
        final tool = message.tool;
        if (tool == null) {
          under('Agent', '- ${message.text.split('\n').first}');
          continue;
        }
        final subject = tool.subject?.split('\n').first.trim();
        final took = commandDuration(message);
        under(
          'Agent',
          [
            '- **${toolDisplayName(tool.name)}**',
            if (subject != null && subject.isNotEmpty)
              '`${subject.replaceAll('`', "'")}`',
            if (tool.isError) '(failed)',
            if (took != null) '(${formatCommandDuration(took)})',
          ].join(' '),
        );
      default:
        if (message.text.trim().isNotEmpty) {
          under('Agent', '> ${message.text.trim().split('\n').join('\n> ')}');
        }
    }
  }
  // Consecutive call lines read as one list, not a paragraph per call.
  final out = StringBuffer();
  for (var i = 0; i < parts.length; i++) {
    if (i > 0) {
      out.write(
        parts[i].startsWith('- ') && parts[i - 1].startsWith('- ')
            ? '\n'
            : '\n\n',
      );
    }
    out.write(parts[i]);
  }
  return out.toString();
}

/// The messages in [messages] that opened a turn, for matching each turn to
/// its checkpoints ([turnForkPoints]).
List<TranscriptTurnStart> transcriptTurnStarts(List<ChatMessage> messages) => [
  for (var i = 0; i < messages.length; i++)
    if (_opensTurn(messages[i]))
      (ordinal: i, at: messages[i].at, text: _personsWords(messages[i])),
];
