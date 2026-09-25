import '../../util/sqlite_rows.dart';
import '../domain/agent_descriptor.dart';
import 'directory_conversation_attribution.dart';
import 'directory_resume_plan.dart';

/// **A store that records the last conversation per directory** rather than
/// taking a conversation id at launch.
///
/// Such a CLI mints its own id and will not accept one, so the app learns which
/// conversation a session is on after the fact — from what the CLI printed in
/// the pane, or from the store's directory map — and can continue a session
/// whose id it was never told by naming the conversation the store records for
/// its directory.
abstract interface class AgentDirectoryConversations {
  /// How many bottom lines of a pane's scrollback to read for the CLI's own
  /// announcement of its conversation — printed as it exits.
  int get announcementLines;

  /// The store's `{directory: conversation id}` map under [storeHome].
  Future<Map<String, String>> lastConversations(
    String storeHome, {
    required SqliteRowReader readRows,
  });

  /// The conversation [byDirectory] records for [directory], matched the way
  /// the CLI itself matches paths, or null.
  String? conversationFor(Map<String, String> byDirectory, String directory);

  /// Which conversation the session launched in [workingDirectory] at
  /// [launchedAt] is on, or why that cannot be told.
  Future<DirectoryConversationAttribution> attribute({
    required AgentDescriptor descriptor,
    required String storeHome,
    required String workingDirectory,
    required DateTime launchedAt,
    required SqliteRowReader readRows,
    String paneOutput = '',
    Set<String> conversationIdsHeldByOtherSessions = const {},
  });

  /// How to continue a session, given what is known about it.
  DirectoryResumePlan planResume({
    required AgentDescriptor descriptor,
    required String workingDirectory,
    String? conversationId,
    String? lastConversationForDirectory,
    Set<String> conversationIdsHeldByOtherSessions = const {},
  });

  /// What to tell the user before continuing [conversationId], which the
  /// session was never given the id of — it names its target, which is why it
  /// is not a guess.
  String continueNotice(String conversationId, String directory);
}
