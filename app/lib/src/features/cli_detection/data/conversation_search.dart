import 'package:agent_cli/read.dart' show conversationQueryTokens;
import 'package:karmashala_conversations/karmashala_conversations.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/data/data_client.dart';
import '../../../core/data/data_providers.dart';

/// Full-text search over what was said in every conversation, asked of the
/// server, which keeps the index — the one search quick open, typed commands
/// and the `session_search` tool call. Nothing is kept here.
class ConversationSearch {
  ConversationSearch(this._client);

  final DataClient _client;

  /// A page of conversations that said [query], best first. A query too short
  /// to search is answered here, empty. Throws [DataRefused] — `invalid` for
  /// a cursor the index has moved past.
  Future<SessionSearchPage> search(
    String query, {
    SessionSearchFilter filter = const SessionSearchFilter(),
    int limit = 20,
    String? cursor,
  }) async {
    if (conversationQueryTokens(query) == null || limit <= 0) {
      return SessionSearchPage.empty;
    }
    final reply = await _client.send(
      ConversationsSearch(query, filter: filter, limit: limit, cursor: cursor),
    );
    return reply.value;
  }

  /// Asks the server to read what the running sessions appended since their
  /// last reading; answers how many conversations changed.
  Future<int> catchUp() async =>
      (await _client.send(const ConversationsCatchUp())).value;
}

final conversationSearchProvider = Provider<ConversationSearch>(
  (ref) => ConversationSearch(ref.watch(dataClientProvider)),
);
