import '../../process/process_handle.dart';
import '../domain/file_edit.dart';

/// A rename a store server pushed on its own — the CLI named a conversation.
class ConversationNameUpdate {
  const ConversationNameUpdate({
    required this.conversationId,
    required this.name,
  });

  final String conversationId;
  final String name;
}

/// One file a store server says a conversation changed.
class StoreServerFileChange {
  const StoreServerFileChange({
    required this.path,
    required this.kind,
    this.movedTo,
  });

  /// In the agent's own spelling — a POSIX path inside a WSL distribution for
  /// a WSL install. `PathTranslator` is the one place that changes that.
  final String path;
  final FileEditKind kind;
  final String? movedTo;
}

/// What a store server answered about a conversation's file changes.
class FileChangeListing {
  const FileChangeListing.ok(this.changes) : failure = null;
  const FileChangeListing.failed(String this.failure) : changes = const [];

  final List<StoreServerFileChange> changes;

  /// Why the server could not answer, in words, or null.
  final String? failure;
}

/// One live connection to an agent's store server.
abstract interface class AgentStoreServerClient {
  /// Asks the CLI to name [conversationId] [title]. Returns null on success,
  /// or why it would not.
  Future<String?> rename(String conversationId, String title);

  /// The files [conversationId] changed, as the CLI itself recorded them.
  Future<FileChangeListing> listFileChanges(String conversationId);

  Future<void> close();
}

/// **A server process the CLI offers over its own store** — listing, renaming
/// and reporting on conversations from the state the CLI keeps current, rather
/// than from files it may not read back.
abstract interface class AgentStoreServer {
  /// The arguments after the executable that start the server on stdio.
  List<String> get arguments;

  /// A client over [connect], which opens the one process it talks to.
  ///
  /// [expectedHome] is the store the connection should be talking to, in the
  /// server's spelling, or null to accept whatever answers. [onNameUpdated]
  /// hears the names the CLI gives conversations on its own.
  AgentStoreServerClient open({
    required Future<ProcessHandle> Function() connect,
    required String clientVersion,
    String? expectedHome,
    void Function(ConversationNameUpdate update)? onNameUpdated,
  });
}
