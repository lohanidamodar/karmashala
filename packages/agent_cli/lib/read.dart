/// **Mode 4 — reading what the CLIs already wrote.**
///
/// Every one of these agents keeps its own conversation store, and this reads
/// them where they are: Claude Code's per-project JSONL, Codex's rollouts and
/// its `app-server` thread list, Antigravity's conversation directory. Out come
/// projects, sessions, transcripts and presence — without the CLI running.
///
/// `CliStoreLocator` finds each store home, including a WSL one reached over
/// `\\wsl.localhost`, from a runner resolver and a list of installations.
library;

export 'src/agents/antigravity/antigravity_directory_conversations.dart';
export 'src/agents/antigravity/antigravity_session_resume.dart';
export 'src/agents/antigravity/antigravity_store.dart';
export 'src/agents/antigravity/antigravity_store_editor.dart';
export 'src/agents/antigravity/antigravity_store_reader.dart';
export 'src/agents/antigravity/antigravity_store_sessions.dart';
export 'src/agents/antigravity/antigravity_transcript.dart';
export 'src/agents/claude_code/claude_code_store.dart';
export 'src/agents/claude_code/claude_code_store_editor.dart';
export 'src/agents/claude_code/claude_file_edits.dart';
export 'src/agents/claude_code/claude_media_reader.dart';
export 'src/agents/claude_code/claude_store_reader.dart';
export 'src/cli_detection/data/cli_detection_service.dart';
export 'src/cli_detection/data/cli_store.dart';
export 'src/cli_detection/data/cli_transcript_reader.dart';
export 'src/agents/codex/codex_app_server_client.dart';
export 'src/agents/adapter/store_server_launch.dart';
export 'src/agents/codex/codex_app_server_reader.dart';
export 'src/agents/codex/codex_file_edits.dart';
export 'src/agents/codex/codex_media_reader.dart';
export 'src/agents/codex/codex_store.dart';
export 'src/agents/codex/codex_store_editor.dart';
export 'src/agents/codex/codex_store_reader.dart';
export 'src/agents/codex/codex_store_server.dart';
export 'src/agents/codex/codex_thread.dart';
export 'src/cli_detection/data/conversation_store_index.dart';
export 'src/cli_detection/data/store_scan_slots.dart';
export 'src/cli_detection/data/store_session_reader.dart';
export 'src/cli_detection/data/subagent_transcript.dart';
export 'src/cli_detection/data/transcript_dialect.dart';
export 'src/agents/domain/file_edit.dart';
export 'src/cli_detection/domain/conversation_presence.dart';
export 'src/cli_detection/domain/conversation_query.dart';
export 'src/cli_detection/domain/detected_project.dart';
export 'src/cli_detection/domain/detected_project_merger.dart';
export 'src/cli_detection/domain/detected_session.dart';
export 'src/cli_detection/domain/imported_session.dart';
export 'src/media/session_media_item.dart';
export 'src/media/session_media_store.dart';
export 'src/util/sqlite_rows.dart';
export 'src/util/sqlite_writer.dart';
