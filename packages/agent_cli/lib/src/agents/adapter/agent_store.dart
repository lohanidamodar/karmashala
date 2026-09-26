import '../../cli_detection/data/store_session_reader.dart';
import '../../cli_detection/domain/conversation_presence.dart';
import '../../util/sqlite_rows.dart';
import 'agent_store_editor.dart';

/// **An agent's own conversation store**, as far as this package can read and
/// change it: the sessions in it, whether a conversation is still there, and
/// how a conversation is renamed or removed the way the CLI itself would.
///
/// Where the store lives is data — `AgentStoreSpec.homeDirectoryName` on the
/// descriptor. How it is laid out is this. An agent that declares a home but
/// no [AgentStore] is located and listed, and every question here answers
/// "unknown" for it rather than guessing.
abstract interface class AgentStore {
  /// A reader for the sessions in one store home.
  ///
  /// A new reader per call, so a caller that keeps one keeps its caches — the
  /// reason a second scan costs what changed rather than the whole store.
  /// [readRows] is the host's SQLite binding, for a store that is a database.
  StoreSessionReader sessionReader({
    SqliteRowReader readRows = noSqliteBinding,
  });

  /// The store directory a session started in [workingDirectory] is filed
  /// under, lowercased, or null for a store whose layout is not addressable
  /// from a working directory — what narrows a read
  /// (`StoreSessionReader.read`'s `directories`).
  String? directoryNameFor(String workingDirectory);

  /// Whether the store at [storeHome] holds [conversationId] — a question about
  /// a name, answered without reading a transcript.
  Future<ConversationPresence> presenceOf(
    String storeHome,
    String conversationId,
  );

  /// Every conversation id the store holds, or null when it told us nothing.
  /// Null is load-bearing: an empty set says "no conversations at all".
  Future<Set<String>?> conversationIds(String storeHome);

  /// Every conversation the store holds, by id, with the file its transcript
  /// is in — one walk of names, no transcript opened. Null when the store
  /// told us nothing, as for [conversationIds].
  Future<Map<String, String>?> transcripts(String storeHome);

  /// Where a conversation's record may be when a scan did not place it (a
  /// conversation its store files under no directory), in the order to try.
  /// Empty for a store whose scan finds everything.
  List<String> recordCandidates(String storeHome, String conversationId);

  /// How a conversation is renamed and removed in this store, or null when
  /// the store is not ours to change.
  AgentStoreEditor? get editor;
}
