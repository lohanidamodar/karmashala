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

export 'src/agents/data/antigravity_session_resume.dart';
export 'src/agents/data/antigravity_store_reader.dart';
export 'src/cli_detection/data/antigravity_store_sessions.dart';
export 'src/cli_detection/data/antigravity_transcript.dart';
export 'src/cli_detection/data/claude_store_reader.dart';
export 'src/cli_detection/data/cli_store.dart';
export 'src/cli_detection/data/cli_transcript_reader.dart';
export 'src/cli_detection/data/codex_app_server_client.dart';
export 'src/cli_detection/data/codex_app_server_launch.dart';
export 'src/cli_detection/data/codex_app_server_reader.dart';
export 'src/cli_detection/data/codex_store_reader.dart';
export 'src/cli_detection/data/codex_thread.dart';
export 'src/cli_detection/data/conversation_store_index.dart';
export 'src/cli_detection/data/store_scan_slots.dart';
export 'src/cli_detection/data/store_session_reader.dart';
export 'src/cli_detection/data/subagent_transcript.dart';
export 'src/cli_detection/domain/conversation_presence.dart';
export 'src/cli_detection/domain/conversation_query.dart';
export 'src/cli_detection/domain/detected_project.dart';
export 'src/cli_detection/domain/detected_session.dart';
export 'src/cli_detection/domain/imported_session.dart';
export 'src/util/sqlite_rows.dart';
