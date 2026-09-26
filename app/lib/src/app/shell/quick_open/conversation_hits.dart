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

  /// [query]'s hits, [limit] at most, or null while the server is asked.
  List<ConversationHit>? hitsFor(String query, int limit) {
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

  /// Drops every answer, after the index changed under them.
  void forget() {
    _answers.clear();
    _asked.clear();
  }

  void close() => _closed = true;
}
