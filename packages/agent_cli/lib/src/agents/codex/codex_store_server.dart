import '../../process/process_handle.dart';
import '../adapter/agent_store_server.dart';
import '../domain/file_edit.dart';
import 'codex_app_server_client.dart';
import 'codex_thread.dart';

/// The app-server arguments. `--listen stdio://` is the default on both Codex
/// 0.145.0 and 0.153.4, and naming it keeps a future default change from
/// quietly moving this connection onto a socket.
///
/// `-c check_for_update_on_startup=false` leads, as a global option must sit
/// left of the `app-server` subcommand. The app-server does not itself check
/// for updates (only the TUI does, in `tui/src/updates.rs`), so this is a
/// belt-and-braces override on an always-internal process: a Codex Karmashala
/// spawns never runs the startup update check that behavioural antivirus reads
/// as a dropper signal (docs/windows-antivirus.md). Unconditional because the
/// app-server is never a session the user watches; the per-session setting
/// governs the interactive launches.
const List<String> codexAppServerArguments = [
  '-c',
  'check_for_update_on_startup=false',
  'app-server',
  '--listen',
  'stdio://',
];

/// `codex app-server --listen stdio://`: Codex's own index of its threads,
/// which it keeps current where the rollout files are not.
class CodexStoreServer implements AgentStoreServer {
  const CodexStoreServer();

  @override
  List<String> get arguments => codexAppServerArguments;

  @override
  AgentStoreServerClient open({
    required Future<ProcessHandle> Function() connect,
    required String clientVersion,
    String? expectedHome,
    void Function(ConversationNameUpdate update)? onNameUpdated,
  }) => CodexStoreServerClient(
    CodexAppServerClient(
      connect: connect,
      clientVersion: clientVersion,
      expectedCodexHome: expectedHome,
      onThreadNameUpdated: onNameUpdated == null
          ? null
          : (update) => onNameUpdated(
              ConversationNameUpdate(
                conversationId: update.threadId,
                name: update.name,
              ),
            ),
    ),
  );
}

/// [CodexAppServerClient] seen through the store-server boundary.
class CodexStoreServerClient implements AgentStoreServerClient {
  CodexStoreServerClient(this.client);

  final CodexAppServerClient client;

  @override
  Future<String?> rename(String conversationId, String title) async {
    final result = await client.setThreadName(conversationId, title);
    return result.ok ? null : '${result.failure}';
  }

  @override
  Future<FileChangeListing> listFileChanges(String conversationId) async {
    final result = await client.listFileChanges(conversationId);
    final failure = result.failure;
    if (failure != null) return FileChangeListing.failed(failure.message);
    return FileChangeListing.ok([
      for (final change in result.changes)
        StoreServerFileChange(
          path: change.path,
          movedTo: change.movedTo,
          kind: switch (change.kind) {
            CodexFileChangeKind.add => FileEditKind.created,
            CodexFileChangeKind.delete => FileEditKind.deleted,
            // An `update` is a modification; a kind this build does not know
            // is still a change Codex reported, and "modified" is the weaker
            // claim.
            CodexFileChangeKind.update ||
            CodexFileChangeKind.unknown => FileEditKind.modified,
          },
        ),
    ]);
  }

  @override
  Future<void> close() => client.close();
}
