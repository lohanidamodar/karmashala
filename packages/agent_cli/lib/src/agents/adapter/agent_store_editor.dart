import '../../cli_detection/domain/detected_session.dart';
import '../../util/sqlite_writer.dart';
import 'agent_store_server.dart';

/// What a store edit actually cost, counted rather than timed: index walks,
/// records decoded, index files rewritten. Shared by every editor one caller
/// drives, so "did this delete walk the index once?" is answerable.
class StoreEditCounters {
  int storeScans = 0;
  int indexEntriesRead = 0;
  int indexWrites = 0;
}

/// What an edit may need from the host.
class StoreEditContext {
  const StoreEditContext({
    required this.counters,
    required this.writeSqlite,
    this.serverFor,
  });

  final StoreEditCounters counters;

  /// The host's SQLite binding, for a store whose index is a database.
  final SqliteWriter writeSqlite;

  /// The agent's store server in one environment, for a store that must be
  /// *asked* to change rather than written to. Null when the caller has none,
  /// and such a rename is skipped, never faked by writing a file the CLI
  /// ignores.
  final AgentStoreServerClient? Function(
    String environmentId,
    String storeHome,
  )?
  serverFor;
}

/// How a conversation is renamed and removed the way the CLI itself would.
abstract interface class AgentStoreEditor {
  /// Renames [session] to [title] in its CLI's store.
  Future<void> rename(
    DetectedSession session,
    String title,
    StoreEditContext context,
  );

  /// Drops every index entry naming one of [conversationIds] from the store at
  /// [storeHome], after their transcripts were deleted.
  Future<void> prune(
    String storeHome,
    Set<String> conversationIds,
    StoreEditContext context,
  );
}
