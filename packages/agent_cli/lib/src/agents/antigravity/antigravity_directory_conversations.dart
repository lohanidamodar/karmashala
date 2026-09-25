import '../../util/sqlite_rows.dart';
import '../adapter/agent_directory_conversations.dart';
import '../adapter/directory_conversation_attribution.dart';
import '../adapter/directory_resume_plan.dart';
import '../domain/agent_descriptor.dart';
import 'antigravity_session_resume.dart';
import 'antigravity_store_reader.dart';

/// `agy` mints its own conversation id and will not accept one; its store
/// records `{directory: conversation}` in `cache/last_conversations.json`, and
/// it prints `agy --conversation=<id>` as it exits.
class AntigravityDirectoryConversations implements AgentDirectoryConversations {
  const AntigravityDirectoryConversations();

  /// The resume hint is printed as the CLI exits, so it sits at the bottom of
  /// a dead pane.
  @override
  int get announcementLines => 40;

  @override
  Future<Map<String, String>> lastConversations(
    String storeHome, {
    required SqliteRowReader readRows,
  }) => AntigravityStoreReader(
    readRows: readRows,
  ).readLastConversations(storeHome);

  @override
  String? conversationFor(Map<String, String> byDirectory, String directory) =>
      conversationForDirectory(byDirectory, directory);

  @override
  Future<DirectoryConversationAttribution> attribute({
    required AgentDescriptor descriptor,
    required String storeHome,
    required String workingDirectory,
    required DateTime launchedAt,
    required SqliteRowReader readRows,
    String paneOutput = '',
    Set<String> conversationIdsHeldByOtherSessions = const {},
  }) =>
      AntigravitySessionAttributor(
        reader: AntigravityStoreReader(countSteps: false, readRows: readRows),
      ).attribute(
        descriptor: descriptor,
        storeHome: storeHome,
        workingDirectory: workingDirectory,
        launchedAt: launchedAt,
        paneOutput: paneOutput,
        conversationIdsHeldByOtherSessions: conversationIdsHeldByOtherSessions,
      );

  @override
  DirectoryResumePlan planResume({
    required AgentDescriptor descriptor,
    required String workingDirectory,
    String? conversationId,
    String? lastConversationForDirectory,
    Set<String> conversationIdsHeldByOtherSessions = const {},
  }) => planAntigravityResume(
    descriptor: descriptor,
    workingDirectory: workingDirectory,
    conversationId: conversationId,
    lastConversationForDirectory: lastConversationForDirectory,
    conversationIdsHeldByOtherSessions: conversationIdsHeldByOtherSessions,
  );

  @override
  String continueNotice(String conversationId, String directory) =>
      'Antigravity never told this session its conversation id. Continuing '
      '$conversationId, the conversation its store records for $directory.';
}
