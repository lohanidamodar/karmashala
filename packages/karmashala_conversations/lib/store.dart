/// **The server's alone.** The conversation index over its store: the DAO,
/// the indexer that reads transcripts through the agent adapters, the search
/// behind `conversations.search`, and the one-off backfill.
library;

export 'src/conversation_values.dart';
export 'src/conversation_index_backfill.dart';
export 'src/conversation_index_dao.dart';
export 'src/conversation_indexer.dart';
export 'src/session_search.dart';
