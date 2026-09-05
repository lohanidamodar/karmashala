import '../../agents/data/antigravity_store_reader.dart';
import '../../agents/domain/agent_ids.dart';
import '../../environments/domain/environment_path.dart';
import '../domain/detected_session.dart';
import 'codex_app_server_launch.dart';
import 'store_scan_slots.dart';
import 'store_session_reader.dart';

/// Reads Antigravity conversations from a `.gemini/antigravity-cli` store into
/// the shape the rest of detection speaks.
///
/// The same `read(home, environmentId)` shape as `ClaudeStoreReader` and
/// `CodexStoreReader`, so `CliDetectionService` treats all three alike. The
/// work of opening the store belongs to `AntigravityStoreReader`
/// (`features/agents/data/`), which is where the file formats are documented;
/// this is only the mapping.
class AntigravityStoreSessions implements StoreSessionReader {
  const AntigravityStoreSessions({
    // Step counts open one SQLite file per conversation and nothing in
    // detection shows them, so the sweep stays a directory listing plus two
    // small files.
    this.reader = const AntigravityStoreReader(countSteps: false),
  });

  final AntigravityStoreReader reader;

  /// [directories], [slots] and [appServer] are ignored: this store is one
  /// directory listing plus two small files, so there is nothing to narrow,
  /// nothing that fans out, and no server to ask.
  @override
  Future<List<DetectedSession>> read(
    String storeHome,
    String environmentId, {
    Set<String>? directories,
    StoreScanSlots? slots,
    CodexAppServerLaunch? appServer,
  }) async {
    final conversations = await reader.read(storeHome);
    return [
      for (final conversation in conversations)
        // **A conversation the store places nowhere is left out.**
        // `cache/last_conversations.json` holds one entry per *directory*, so
        // a conversation in a directory that has since been used again has no
        // workspace at all (`AntigravityConversation.workspace`). Every reader
        // of a `DetectedSession` groups it by its `cwd`, so inventing one would
        // file the conversation under a repository it never ran in — the exact
        // failure the design note refuses for
        // attribution, for the same reason.
        if (conversation.workspace case final workspace?)
          DetectedSession(
            cli: AgentIds.antigravity,
            sessionId: conversation.id,
            cwd: EnvironmentPath(
              environmentId: environmentId,
              path: workspace,
            ),
            // The conversation's own file. Named because it is what identity
            // is read from and what a delete would remove — **not** because it
            // can be shown: its message columns are protobuf in an unpublished
            // schema, which is why `agentSupportsChatView` refuses this agent
            // and `readCliTranscript` returns nothing for it.
            filePath: conversation.filePath,
            storeHome: conversation.storeHome,
            // What `/rename` wrote, and nothing else. Deliberately not
            // `displayTitle`, which falls back to the CLI's own generated
            // preview: a preview is a summary of the first message, not a name
            // the user chose, and `SessionTitleSyncService` writes this field
            // into session rows.
            title: conversation.title,
            preview: conversation.preview,
            modifiedAt: conversation.modifiedAt,
          ),
    ];
  }
}
