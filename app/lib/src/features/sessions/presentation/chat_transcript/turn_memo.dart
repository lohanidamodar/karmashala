// Per-turn readings the list memoises: footers, prose, turn places and rewind folds.

part of '../chat_transcript.dart';

mixin _TranscriptTurnMemo on State<ChatTranscriptView> {
  List<ChatMessage>? _footerMessages;
  TranscriptTurn? _footerTurn;
  DateTime? _footerStoppedAt;
  var _footers = const <int, TurnFooter>{};

  /// [turnFooters], walked again only when the list, the turn or its Stop
  /// moved: an elapsed tick or a hover rebuild costs nothing here.
  Map<int, TurnFooter> _footersFor(
    List<ChatMessage> messages,
    TranscriptTurn turn,
  ) {
    final stoppedAt = widget.lastTurnStoppedAt;
    if (identical(messages, _footerMessages) &&
        turn == _footerTurn &&
        stoppedAt == _footerStoppedAt) {
      return _footers;
    }
    _footerMessages = messages;
    _footerTurn = turn;
    _footerStoppedAt = stoppedAt;
    return _footers = turnFooters(
      messages,
      lastTurnOver: turn == TranscriptTurn.idle,
      lastTurnStoppedAt: stoppedAt,
    );
  }

  List<ChatMessage>? _proseMessages;
  TranscriptTurn? _proseTurn;
  var _prose = const <int, AgentProse>{};

  /// [agentProse], walked again only when the list or the turn moved.
  Map<int, AgentProse> _proseFor(
    List<ChatMessage> messages,
    TranscriptTurn turn,
  ) {
    if (identical(messages, _proseMessages) && turn == _proseTurn) {
      return _prose;
    }
    _proseMessages = messages;
    _proseTurn = turn;
    final over = switch (turn) {
      TranscriptTurn.idle => true,
      TranscriptTurn.unknown => !messages.any((m) => m.pending),
      _ => false,
    };
    return _prose = agentProse(messages, lastTurnOver: over);
  }

  List<ChatMessage>? _placedMessages;
  var _starts = const <int?>[];
  var _turnIndexes = const <int, int>{};

  /// Where the row at [ordinal] stands in its turn; the starts are walked
  /// again only when the list moved.
  _TurnPlace? _placeOf(int ordinal) {
    final messages = widget.messages;
    if (!identical(messages, _placedMessages)) {
      _placedMessages = messages;
      _starts = _turnStartsOf(messages);
      var turn = 0;
      _turnIndexes = {
        for (var i = 0; i < messages.length; i++)
          if (_opensTurn(messages[i])) i: turn++,
      };
    }
    final start = _starts[ordinal];
    if (start == null) return null;
    _readFolds();
    return _TurnPlace(
      start: start,
      words: _personsWords(messages[start]),
      isLatest: _isLatestTurn,
      turnIndex: _turnIndexes[start] ?? 0,
      rewound: _folds[start] != null,
    );
  }

  List<ChatMessage>? _foldedMessages;

  /// Each message's rewind row, by index, where a rewind folded it.
  var _folds = const <int?>[];

  /// Each rewind row's first folded message.
  var _foldStarts = const <int, int>{};

  /// The rewinds opened to read, by their rewind row's place in the whole
  /// conversation.
  final _openFolds = <int>{};

  void _readFolds() {
    final messages = widget.messages;
    if (identical(messages, _foldedMessages)) return;
    _foldedMessages = messages;
    _folds = rewindFolds(
      messages.length,
      roleAt: (i) => messages[i].role,
      textAt: (i) => messages[i].text,
      opensTurn: (i) => _opensTurn(messages[i]),
    );
    final starts = <int, int>{};
    for (var i = 0; i < _folds.length; i++) {
      if (_folds[i] case final owner?) starts.putIfAbsent(owner, () => i);
    }
    _foldStarts = starts;
  }

  void _toggleFold(int owner) => setState(() {
    final key = widget.firstOrdinal + owner;
    if (!_openFolds.remove(key)) _openFolds.add(key);
  });

  bool _isLatestTurn(int start) => _starts.isNotEmpty && _starts.last == start;
}
