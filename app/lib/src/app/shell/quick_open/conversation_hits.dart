import 'dart:async';

import 'package:karmashala_conversations/karmashala_conversations.dart';

import '../../../features/cli_detection/data/conversation_search.dart';

/// The palette's answers from the server's conversation search, by query.
/// The palette draws synchronously and the server answers later: a query not
/// answered yet reads as null and is asked once, and [onAnswer] redraws when
/// it lands.
class ConversationHits {
  ConversationHits(this._search, {required this.onAnswer});

  final ConversationSearch _search;
  final void Function() onAnswer;

  final _answers = <String, List<ConversationHit>>{};
  final _asked = <String>{};
  var _closed = false;

  /// What the index could not cover when last asked; null until it answers,
  /// and from a server that cannot say.
  ConversationIndexStatus? get status => _status;
  ConversationIndexStatus? _status;
  var _statusAsked = false;

  /// [query]'s hits, [limit] at most, or null while the server is asked.
  List<ConversationHit>? hitsFor(String query, int limit) {
    _askStatus();
    final key = '$limit\u0000$query';
    final answered = _answers[key];
    if (answered != null || !_asked.add(key)) return answered;
    unawaited(
      _search
          .search(query, limit: limit)
          .then(
            (page) {
              if (_closed) return;
              _answers[key] = page.hits;
              onAnswer();
            },
            // A search the server could not answer finds nothing here; the
            // rest of the palette is unaffected.
            onError: (Object _) {
              if (!_closed) _answers[key] = const [];
            },
          ),
    );
    return null;
  }

  void _askStatus() {
    if (_statusAsked) return;
    _statusAsked = true;
    unawaited(
      _search.status().then(
        (status) {
          if (_closed) return;
          _status = status;
          onAnswer();
        },
        // Unknown coverage is said as nothing, never as complete.
        onError: (Object _) {},
      ),
    );
  }

  /// Drops every answer, after the index changed under them.
  void forget() {
    _answers.clear();
    _asked.clear();
    _statusAsked = false;
  }

  void close() => _closed = true;
}

/// What a conversation search may be missing, in a few words, or null when
/// the index reports no gap — or reports nothing, which is no claim either.
String? conversationCoverageNote(ConversationIndexStatus? status) {
  if (status == null) return null;
  final parts = [
    if (status.backfilling) 'reading history',
    if ((status.unindexed ?? 0) > 0)
      '${status.unindexed} of ${status.named} conversations not indexed',
    if ((status.unreadable ?? 0) > 0)
      '${status.unreadable} could not be read, may be out of date',
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}
