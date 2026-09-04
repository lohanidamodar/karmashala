import '../../agents/data/antigravity_store_reader.dart';
import '../../agents/domain/agent_ids.dart';
import '../../environments/domain/environment_path.dart';
import '../domain/detected_session.dart';

/// Reads Antigravity conversations from a `.gemini/antigravity-cli` store into
/// the shape the rest of detection speaks.
///
/// The same `read(home, environmentId)` shape as `ClaudeStoreReader` and
/// `CodexStoreReader`, so `CliDetectionService` treats all three alike. The
/// work of opening the store belongs to `AntigravityStoreReader`
/// (`features/agents/data/`), which is where the file formats are documented;
/// this is only the mapping.
class AntigravityStoreSessions {
  const AntigravityStoreSessions({
    // Step counts open one SQLite file per conversation and nothing in
    // detection shows them, so the sweep stays a directory listing plus two
    // small files.
    this.reader = const AntigravityStoreReader(countSteps: false),
  });

  final AntigravityStoreReader reader;

  Future<List<DetectedSession>> read(
    String storeHome,
    String environmentId,
  ) async {
    final conversations = await reader.read(storeHome);
    return [
      for (final conversation in conversations)
        DetectedSession(
          cli: AgentIds.antigravity,
          sessionId: conversation.id,
          cwd: EnvironmentPath(
            environmentId: environmentId,
            path: conversation.workspace ?? '',
          ),
          filePath: conversation.filePath,
          storeHome: conversation.storeHome,
          title: conversation.title,
          preview: conversation.preview,
          modifiedAt: conversation.modifiedAt,
        ),
    ];
  }
}
