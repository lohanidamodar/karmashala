import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

/// SQL applied to move the database to the keyed version. Hand-written and
/// idempotent at the DDL level (`IF NOT EXISTS`), so a re-run is safe.
typedef MigrationStep = void Function(Database db);

/// Ordered schema migrations, keyed by the target `user_version`. Every step
/// above the stored `PRAGMA user_version` runs in order, one transaction each.
final Map<int, MigrationStep> schemaMigrations = {
  1: _migrateToV1,
  2: _migrateToV2,
  3: _migrateToV3,
  4: _migrateToV4,
  5: _migrateToV5,
  6: _migrateToV6,
  7: _migrateToV7,
  8: _migrateToV8,
  9: _migrateToV9,
  10: _migrateToV10,
  11: _migrateToV11,
  12: _migrateToV12,
  13: _migrateToV13,
  14: _migrateToV14,
  15: _migrateToV15,
  16: _migrateToV16,
  17: _migrateToV17,
  18: _migrateToV18,
  19: _migrateToV19,
  20: _migrateToV20,
  21: _migrateToV21,
  22: _migrateToV22,
  23: _migrateToV23,
  24: _migrateToV24,
  25: _migrateToV25,
  26: _migrateToV26,
  27: _migrateToV27,
  28: _migrateToV28,
  29: _migrateToV29,
  30: _migrateToV30,
  31: _migrateToV31,
  32: _migrateToV32,
  33: _migrateToV33,
  34: _migrateToV34,
  35: _migrateToV35,
  36: _migrateToV36,
  37: _migrateToV37,
  38: _migrateToV38,
  39: _migrateToV39,
  40: _migrateToV40,
  41: _migrateToV41,
  42: _migrateToV42,
  43: _migrateToV43,
  44: _migrateToV44,
  45: _migrateToV45,
  46: _migrateToV46,
  47: _migrateToV47,
  48: _migrateToV48,
  49: _migrateToV49,
  50: _migrateToV50,
};

/// Was this pane running when its row was written? `DEFAULT 0` is the honest
/// reading of older rows: inventing a claim would spawn a shell per pane.
void _migrateToV26(Database db) {
  db.execute(
    'ALTER TABLE terminal_panes ADD COLUMN was_live INTEGER NOT NULL '
    'DEFAULT 0;',
  );
  db.execute(
    'ALTER TABLE terminal_panes_backup ADD COLUMN was_live INTEGER NOT NULL '
    'DEFAULT 0;',
  );
}

/// What a session left behind when it ended. The baseline is written as
/// already-closed rows, so an upgrade does not raise a workspace's whole past.
void _migrateToV25(Database db) {
  db.execute('''
    CREATE TABLE IF NOT EXISTS session_follow_ups (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      session_id TEXT NOT NULL,
      reason TEXT NOT NULL,
      ending TEXT NOT NULL,
      summary TEXT,
      raised_at TEXT NOT NULL,
      resolved_at TEXT,
      resolution TEXT
    );
  ''');
  // At most one *open* follow-up per session: the writer is a poll and would
  // otherwise add an identical row on every session-revision bump.
  db.execute(
    'CREATE UNIQUE INDEX IF NOT EXISTS idx_follow_ups_open '
    'ON session_follow_ups (session_id) WHERE resolved_at IS NULL;',
  );

  final now = DateTime.now().toUtc().toIso8601String();
  db.execute(
    'INSERT INTO session_follow_ups '
    '(session_id, reason, ending, raised_at, resolved_at) '
    "SELECT id, 'predatesTheFeature', status, ?, ? FROM sessions "
    "WHERE status IN ('completed', 'failed', 'cancelled');",
    [now, now],
  );
}

void _migrateToV24(Database db) {
  db.execute(
    'CREATE INDEX IF NOT EXISTS idx_sessions_pane ON sessions (pane_id);',
  );
}

void _migrateToV23(Database db) {
  // The decision record: what a session decided, as opposed to what it said.
  // Append-only by explicit acts — the DAO offers no update and no delete.
  db.execute('''
    CREATE TABLE IF NOT EXISTS session_decisions (
      id                     INTEGER PRIMARY KEY AUTOINCREMENT,
      session_id             TEXT NOT NULL,
      sequence               INTEGER NOT NULL,
      kind                   TEXT NOT NULL,
      summary                TEXT NOT NULL,
      detail                 TEXT,
      decided_by             TEXT,
      recorded_by_session_id TEXT,
      origin_kind            TEXT NOT NULL,
      origin_id              TEXT,
      recorded_at            TEXT NOT NULL
    );
  ''');
  db.execute(
    'CREATE UNIQUE INDEX IF NOT EXISTS idx_session_decisions_sequence '
    'ON session_decisions (session_id, sequence);',
  );

  // Deliberately not backfilled: a turn checkpoint or a self-graded run is not
  // a decision, and converting one would put a sentence in the user's mouth.
}

void _migrateToV22(Database db) {
  // Where a session's agent actually runs. Deliberately not `worktree`, which
  // `SessionArchiveService` hands to `git worktree remove` — that deletes it.
  db.execute(
    'ALTER TABLE sessions ADD COLUMN working_directory_environment_id TEXT;',
  );
  db.execute('ALTER TABLE sessions ADD COLUMN working_directory_path TEXT;');
}

void _migrateToV21(Database db) {
  // Notes: a thought the user kept instead of acting on it. `body` is quoted
  // text, never a summary; `source_session_id` is no FK — a note outlives it.
  db.execute('''
    CREATE TABLE IF NOT EXISTS notes (
      id                     TEXT PRIMARY KEY,
      title                  TEXT,
      body                   TEXT NOT NULL,
      source_session_id      TEXT,
      source_repository_id   TEXT,
      source_message_ordinal INTEGER,
      source_message_role    TEXT,
      created_at             TEXT NOT NULL,
      updated_at             TEXT NOT NULL
    );
  ''');
  db.execute(
    'CREATE INDEX IF NOT EXISTS idx_notes_session '
    'ON notes (source_session_id);',
  );
  db.execute(
    'CREATE INDEX IF NOT EXISTS idx_notes_repository '
    'ON notes (source_repository_id);',
  );
}

void _migrateToV20(Database db) {
  // Who produced the verdict, so a surface can derive `producer == subject` and
  // say out loud that an agent graded its own work.
  db.execute(
    'ALTER TABLE verification_runs ADD COLUMN produced_by_session_id TEXT;',
  );
  db.execute(
    'ALTER TABLE fanout_candidates '
    'ADD COLUMN verdict_producer_session_id TEXT;',
  );

  // Deliberately not backfilled: null means "not recorded", and either default
  // would invent a producer nobody wrote down.
}

void _migrateToV19(Database db) {
  // Which relay this device's frames travel through: a hosted URL, or the
  // sentinel `'local'` — the machine's IP moves, "my own relay" does not.
  db.execute('ALTER TABLE paired_devices ADD COLUMN relay_url TEXT;');

  // Every pre-v19 pairing went through the one configured relay; absent or
  // unreadable settings mean the hosted default.
  var relayUrl = 'wss://relay.popupbits.com';
  final settingsRows = db.select(
    "SELECT value FROM app_metadata WHERE key = 'settings.v1';",
  );
  if (settingsRows.isNotEmpty) {
    try {
      final decoded = jsonDecode(settingsRows.first['value'] as String);
      if (decoded is Map<String, dynamic>) {
        if (decoded['remoteRelayMode'] == 'local') {
          relayUrl = 'local';
        } else if (decoded['remoteRelayUrl'] is String) {
          final configured = (decoded['remoteRelayUrl'] as String).trim();
          final parsed = Uri.tryParse(configured);
          if (configured.isNotEmpty && parsed != null && parsed.hasScheme) {
            relayUrl = configured;
          }
        }
      }
    } on FormatException {
      // Unreadable settings: the default above stands.
    }
  }
  db.execute(
    'UPDATE paired_devices SET relay_url = ? WHERE relay_url IS NULL;',
    [relayUrl],
  );
}

void _migrateToV18(Database db) {
  // Phones paired with this host. Revoking *empties* `device_key` rather than
  // only flagging the row: a key that is gone cannot leak later.
  db.execute('''
    CREATE TABLE IF NOT EXISTS paired_devices (
      id            TEXT PRIMARY KEY,
      name          TEXT NOT NULL,
      device_key    TEXT NOT NULL,
      capabilities  INTEGER NOT NULL,
      generation    INTEGER NOT NULL,
      revoked       INTEGER NOT NULL DEFAULT 0,
      push_token    TEXT,
      push_platform TEXT,
      created_at    TEXT NOT NULL,
      last_seen_at  TEXT
    );
  ''');
}

void _migrateToV8(Database db) {
  // SSH as a third kind of execution environment: an `ssh` row points at the
  // `ssh_hosts` row that says where it is.
  db.execute('ALTER TABLE execution_environments ADD COLUMN ssh_host_id TEXT;');

  // Saved remote hosts. Deliberately not a credential store: no password,
  // passphrase or key material here, only where the key file lives.
  db.execute('''
    CREATE TABLE IF NOT EXISTS ssh_hosts (
      id                         TEXT PRIMARY KEY,
      name                       TEXT NOT NULL,
      host                       TEXT NOT NULL,
      port                       INTEGER NOT NULL,
      username                   TEXT NOT NULL,
      auth_method                TEXT NOT NULL,
      private_key_path           TEXT,
      private_key_environment_id TEXT,
      default_directory          TEXT,
      created_at                 TEXT NOT NULL,
      UNIQUE (host, port, username)
    );
  ''');

  // Trusted host keys — our known_hosts, one row per `host:port`. A mismatch is
  // the MITM signal, so the key is the address alone, not address plus key type.
  db.execute('''
    CREATE TABLE IF NOT EXISTS ssh_known_hosts (
      host        TEXT NOT NULL,
      port        INTEGER NOT NULL,
      key_type    TEXT NOT NULL,
      fingerprint TEXT NOT NULL,
      trusted_at  TEXT NOT NULL,
      PRIMARY KEY (host, port)
    );
  ''');
}

void _migrateToV7(Database db) {
  // The terminal layout: tabs, pane split trees and per-pane scrollback.
  // `scrollback` is inert replayed text + SGR runs, never a command to re-run.
  db.execute('''
    CREATE TABLE IF NOT EXISTS terminal_tabs (
      id              TEXT PRIMARY KEY,
      ordinal         INTEGER NOT NULL,
      layout          TEXT NOT NULL,
      focused_pane_id TEXT,
      is_active       INTEGER NOT NULL,
      updated_at      TEXT NOT NULL
    );
  ''');

  db.execute('''
    CREATE TABLE IF NOT EXISTS terminal_panes (
      id                TEXT PRIMARY KEY,
      tab_id            TEXT NOT NULL,
      ordinal           INTEGER NOT NULL,
      profile_id        TEXT NOT NULL,
      title             TEXT NOT NULL,
      working_directory TEXT,
      scrollback        TEXT NOT NULL,
      updated_at        TEXT NOT NULL,
      FOREIGN KEY (tab_id) REFERENCES terminal_tabs (id) ON DELETE CASCADE
    );
  ''');
  db.execute(
    'CREATE INDEX IF NOT EXISTS idx_terminal_panes_tab '
    'ON terminal_panes (tab_id);',
  );
}

void _migrateToV1(Database db) {
  db.execute('''
    CREATE TABLE IF NOT EXISTS app_metadata (
      key        TEXT PRIMARY KEY,
      value      TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );
  ''');
}

void _migrateToV6(Database db) {
  // Saved Claude Code accounts: the two JSON blobs Claude Code persists, plus
  // denormalised display copies. Unique by (email, organization_uuid).
  db.execute('''
    CREATE TABLE IF NOT EXISTS claude_accounts (
      id                TEXT PRIMARY KEY,
      email             TEXT NOT NULL,
      organization_uuid TEXT,
      organization_name TEXT,
      subscription_type TEXT,
      rate_limit_tier   TEXT,
      claude_ai_oauth   TEXT NOT NULL,
      oauth_account     TEXT,
      captured_env_id   TEXT,
      captured_at       TEXT NOT NULL,
      UNIQUE (email, organization_uuid)
    );
  ''');
}

void _migrateToV5(Database db) {
  // The CLI's own identity for a native session, distinct from our row id and
  // required to resume the same conversation in an external terminal.
  db.execute('ALTER TABLE sessions ADD COLUMN external_session_id TEXT;');
}

void _migrateToV2(Database db) {
  // Execution environments: where commands run (Windows native or a WSL distro).
  // Every path elsewhere references one of these by id (constraints 7 & 8).
  db.execute('''
    CREATE TABLE IF NOT EXISTS execution_environments (
      id               TEXT PRIMARY KEY,
      kind             TEXT NOT NULL,
      name             TEXT NOT NULL,
      wsl_distribution TEXT,
      created_at       TEXT NOT NULL
    );
  ''');

  // Projects: a unit of work rooted at a folder in some environment.
  db.execute('''
    CREATE TABLE IF NOT EXISTS projects (
      id                  TEXT PRIMARY KEY,
      name                TEXT NOT NULL,
      root_environment_id TEXT NOT NULL,
      root_path           TEXT NOT NULL,
      created_at          TEXT NOT NULL,
      FOREIGN KEY (root_environment_id)
        REFERENCES execution_environments (id) ON DELETE RESTRICT
    );
  ''');

  // Repositories: a Git repository belonging to a project.
  db.execute('''
    CREATE TABLE IF NOT EXISTS repositories (
      id             TEXT PRIMARY KEY,
      project_id     TEXT NOT NULL,
      name           TEXT NOT NULL,
      environment_id TEXT NOT NULL,
      path           TEXT NOT NULL,
      created_at     TEXT NOT NULL,
      FOREIGN KEY (project_id) REFERENCES projects (id) ON DELETE CASCADE,
      FOREIGN KEY (environment_id)
        REFERENCES execution_environments (id) ON DELETE RESTRICT
    );
  ''');
  db.execute(
    'CREATE INDEX IF NOT EXISTS idx_repositories_project '
    'ON repositories (project_id);',
  );

  // Agent installations: an agent executable installed in one environment.
  // Each (agent, environment, executable) is an independent installation.
  db.execute('''
    CREATE TABLE IF NOT EXISTS agent_installations (
      id              TEXT PRIMARY KEY,
      agent_kind      TEXT NOT NULL,
      environment_id  TEXT NOT NULL,
      executable_path TEXT NOT NULL,
      version         TEXT,
      created_at      TEXT NOT NULL,
      FOREIGN KEY (environment_id)
        REFERENCES execution_environments (id) ON DELETE CASCADE,
      UNIQUE (agent_kind, environment_id, executable_path)
    );
  ''');

  // Sessions: a unit of work targeting one repository, run by one installation,
  // optionally in a Git worktree (per-session choice).
  db.execute('''
    CREATE TABLE IF NOT EXISTS sessions (
      id                      TEXT PRIMARY KEY,
      repository_id           TEXT NOT NULL,
      agent_installation_id   TEXT NOT NULL,
      title                   TEXT NOT NULL,
      use_worktree            INTEGER NOT NULL,
      worktree_environment_id TEXT,
      worktree_path           TEXT,
      status                  TEXT NOT NULL,
      created_at              TEXT NOT NULL,
      FOREIGN KEY (repository_id) REFERENCES repositories (id) ON DELETE CASCADE,
      FOREIGN KEY (agent_installation_id)
        REFERENCES agent_installations (id) ON DELETE RESTRICT
    );
  ''');
  db.execute(
    'CREATE INDEX IF NOT EXISTS idx_sessions_repository '
    'ON sessions (repository_id);',
  );

  // Session events: the normalized, append-only log of everything that happens
  // in a session. Rows are never updated or deleted in normal operation.
  db.execute('''
    CREATE TABLE IF NOT EXISTS session_events (
      id         INTEGER PRIMARY KEY AUTOINCREMENT,
      session_id TEXT NOT NULL,
      seq        INTEGER NOT NULL,
      type       TEXT NOT NULL,
      payload    TEXT NOT NULL,
      created_at TEXT NOT NULL,
      FOREIGN KEY (session_id) REFERENCES sessions (id) ON DELETE CASCADE,
      UNIQUE (session_id, seq)
    );
  ''');
  db.execute(
    'CREATE INDEX IF NOT EXISTS idx_session_events_session '
    'ON session_events (session_id, seq);',
  );
}

void _migrateToV3(Database db) {
  // A session may span multiple repositories; `sessions.repository_id` stays the
  // primary one and this table records every one.
  db.execute('''
    CREATE TABLE IF NOT EXISTS session_repositories (
      session_id    TEXT NOT NULL,
      repository_id TEXT NOT NULL,
      role          TEXT NOT NULL,
      PRIMARY KEY (session_id, repository_id),
      FOREIGN KEY (session_id) REFERENCES sessions (id) ON DELETE CASCADE,
      FOREIGN KEY (repository_id) REFERENCES repositories (id) ON DELETE CASCADE
    );
  ''');
  // Backfill the primary link for any pre-existing sessions.
  db.execute('''
    INSERT OR IGNORE INTO session_repositories (session_id, repository_id, role)
      SELECT id, repository_id, 'primary' FROM sessions;
  ''');
}

void _migrateToV4(Database db) {
  // Sessions imported from a CLI store, kept in their own table so the native
  // schema is untouched. `UNIQUE(source, external_id)` makes re-imports idempotent.
  db.execute('''
    CREATE TABLE IF NOT EXISTS imported_sessions (
      id             TEXT PRIMARY KEY,
      repository_id  TEXT NOT NULL,
      source         TEXT NOT NULL,
      external_id    TEXT NOT NULL,
      environment_id TEXT NOT NULL,
      title          TEXT,
      preview        TEXT NOT NULL,
      file_path      TEXT NOT NULL,
      store_home     TEXT NOT NULL,
      is_subagent    INTEGER NOT NULL,
      updated_at     TEXT,
      created_at     TEXT NOT NULL,
      FOREIGN KEY (repository_id) REFERENCES repositories (id) ON DELETE CASCADE,
      UNIQUE (source, external_id)
    );
  ''');
  db.execute(
    'CREATE INDEX IF NOT EXISTS idx_imported_sessions_repo '
    'ON imported_sessions (repository_id);',
  );
}

void _migrateToV9(Database db) {
  // Keep-alive: a process whose tab was closed is stored as a single-pane row
  // with `detached = 1`, so its scrollback survives quit exactly like a tab's.
  db.execute(
    'ALTER TABLE terminal_tabs ADD COLUMN detached INTEGER NOT NULL DEFAULT 0;',
  );
}

void _migrateToV10(Database db) {
  // `launch_command` restores a pane as the agent it was. It is on the pane,
  // not the session: only `startPane` reads it, and that is the user asking.
  db.execute('ALTER TABLE terminal_panes ADD COLUMN launch_command TEXT;');

  // The *only* record of agent-spawn depth; depth is walked, never stored. Not
  // an FK — deleting a parent must orphan its children, not cascade them away.
  db.execute('ALTER TABLE sessions ADD COLUMN parent_session_id TEXT;');

  // The terminal pane a session runs in. Null for chat sessions and for ones
  // launched into an external terminal, whose pane we do not own.
  db.execute('ALTER TABLE sessions ADD COLUMN pane_id TEXT;');

  // Two columns because they are two questions: `surface` is a runtime fact,
  // `view` is a rendering the user can flip without starting anything.
  db.execute(
    "ALTER TABLE sessions ADD COLUMN surface TEXT NOT NULL DEFAULT 'external';",
  );
  db.execute(
    "ALTER TABLE sessions ADD COLUMN view TEXT NOT NULL DEFAULT 'chat';",
  );

  db.execute(
    'CREATE INDEX IF NOT EXISTS idx_sessions_parent '
    'ON sessions (parent_session_id);',
  );
}

void _migrateToV11(Database db) {
  // Per-session permission mode. Nullable with no default, and null is a real
  // answer: "written before this column existed, ask the settings".
  db.execute('ALTER TABLE sessions ADD COLUMN permission_mode TEXT;');
}

void _migrateToV12(Database db) {
  // Persistent fan-out comparisons, written to still read after the thing they
  // describe is gone — the winner merged, the losers' worktrees removed.
  db.execute("""
    CREATE TABLE IF NOT EXISTS fanout_comparisons (
      id                  TEXT PRIMARY KEY,
      repository_id       TEXT NOT NULL,
      prompt              TEXT NOT NULL,
      created_at          TEXT NOT NULL,
      finished_at         TEXT,
      outcome             TEXT NOT NULL,
      winner_candidate_id TEXT,
      merged_commit       TEXT,
      archived            INTEGER NOT NULL DEFAULT 0,
      FOREIGN KEY (repository_id) REFERENCES repositories (id) ON DELETE CASCADE
    );
  """);
  db.execute(
    'CREATE INDEX IF NOT EXISTS idx_fanout_comparisons_repo '
    'ON fanout_comparisons (repository_id, created_at);',
  );

  // `session_id` is deliberately no FK, and `agent_id` is copied rather than
  // joined: the row must still name who wrote the diff once either is removed.
  db.execute("""
    CREATE TABLE IF NOT EXISTS fanout_candidates (
      id                      TEXT PRIMARY KEY,
      comparison_id           TEXT NOT NULL,
      position                INTEGER NOT NULL,
      session_id              TEXT,
      installation_id         TEXT NOT NULL,
      agent_id                TEXT NOT NULL,
      worktree_environment_id TEXT,
      worktree_path           TEXT,
      branch                  TEXT,
      launch                  TEXT NOT NULL,
      failure                 TEXT,
      files_changed           INTEGER,
      insertions              INTEGER,
      deletions               INTEGER,
      commits                 INTEGER,
      diff_captured_at        TEXT,
      worktree_removed        INTEGER NOT NULL DEFAULT 0,
      verdict                 TEXT,
      verdict_label           TEXT,
      verdict_run_id          TEXT,
      notes                   TEXT,
      FOREIGN KEY (comparison_id) REFERENCES fanout_comparisons (id)
        ON DELETE CASCADE,
      UNIQUE (comparison_id, position)
    );
  """);
  db.execute(
    'CREATE INDEX IF NOT EXISTS idx_fanout_candidates_comparison '
    'ON fanout_candidates (comparison_id, position);',
  );
  db.execute(
    'CREATE INDEX IF NOT EXISTS idx_fanout_candidates_session '
    'ON fanout_candidates (session_id);',
  );
}

void _migrateToV13(Database db) {
  // The layout-loss guard: a shadow copy taken inside `saveLayout`'s own
  // transaction, just before its delete. No FK and no cascade, deliberately.
  db.execute('''
    CREATE TABLE IF NOT EXISTS terminal_tabs_backup (
      id              TEXT PRIMARY KEY,
      ordinal         INTEGER NOT NULL,
      layout          TEXT NOT NULL,
      focused_pane_id TEXT,
      is_active       INTEGER NOT NULL,
      detached        INTEGER NOT NULL DEFAULT 0,
      updated_at      TEXT NOT NULL
    );
  ''');

  db.execute('''
    CREATE TABLE IF NOT EXISTS terminal_panes_backup (
      id                TEXT PRIMARY KEY,
      tab_id            TEXT NOT NULL,
      ordinal           INTEGER NOT NULL,
      profile_id        TEXT NOT NULL,
      title             TEXT NOT NULL,
      working_directory TEXT,
      scrollback        TEXT NOT NULL,
      launch_command    TEXT,
      updated_at        TEXT NOT NULL
    );
  ''');
}

void _migrateToV14(Database db) {
  // The index over checkpoints — the content is a git tree kept reachable from
  // `refs/karmashala/checkpoints/<session>`. No FK: it outlives its session.
  db.execute('''
    CREATE TABLE IF NOT EXISTS session_checkpoints (
      id                TEXT PRIMARY KEY,
      session_id        TEXT NOT NULL,
      environment_id    TEXT NOT NULL,
      repository_path   TEXT NOT NULL,
      sequence          INTEGER NOT NULL,
      tree_sha          TEXT NOT NULL,
      commit_sha        TEXT NOT NULL,
      parent_commit_sha TEXT,
      head_sha          TEXT,
      reason            TEXT NOT NULL,
      label             TEXT,
      created_at        TEXT NOT NULL
    );
  ''');
  db.execute(
    'CREATE INDEX IF NOT EXISTS idx_session_checkpoints_session '
    'ON session_checkpoints (session_id, sequence);',
  );

  // What changed between a checkpoint and the one before it, denormalised so a
  // list of turns can be rendered without running git once per row.
  db.execute('''
    CREATE TABLE IF NOT EXISTS session_checkpoint_files (
      checkpoint_id TEXT NOT NULL,
      path          TEXT NOT NULL,
      status        TEXT NOT NULL,
      PRIMARY KEY (checkpoint_id, path),
      FOREIGN KEY (checkpoint_id) REFERENCES session_checkpoints (id)
        ON DELETE CASCADE
    );
  ''');
}

void _migrateToV15(Database db) {
  // Verification runs. `session_id` is no FK — evidence outlives the session —
  // and no image or log bytes live here, only a directory that points at them.
  db.execute('''
    CREATE TABLE IF NOT EXISTS verification_runs (
      id                 TEXT PRIMARY KEY,
      title              TEXT NOT NULL,
      target_kind        TEXT NOT NULL,
      target_url         TEXT,
      target_serial      TEXT,
      target_package     TEXT,
      session_id         TEXT,
      started_at         TEXT NOT NULL,
      finished_at        TEXT,
      verdict            TEXT,
      reason             TEXT,
      artifact_directory TEXT NOT NULL
    );
  ''');
  db.execute(
    'CREATE INDEX IF NOT EXISTS idx_verification_runs_session '
    'ON verification_runs (session_id);',
  );

  // The actions taken, in order. `ordinal` is the step's identity, so an
  // artifact points back at it without a second surrogate key.
  db.execute('''
    CREATE TABLE IF NOT EXISTS verification_steps (
      run_id  TEXT NOT NULL,
      ordinal INTEGER NOT NULL,
      kind    TEXT NOT NULL,
      summary TEXT NOT NULL,
      detail  TEXT,
      ok      INTEGER NOT NULL,
      at      TEXT NOT NULL,
      PRIMARY KEY (run_id, ordinal),
      FOREIGN KEY (run_id) REFERENCES verification_runs (id) ON DELETE CASCADE
    );
  ''');

  db.execute('''
    CREATE TABLE IF NOT EXISTS verification_artifacts (
      id            TEXT PRIMARY KEY,
      run_id        TEXT NOT NULL,
      step_ordinal  INTEGER,
      kind          TEXT NOT NULL,
      label         TEXT NOT NULL,
      relative_path TEXT NOT NULL,
      byte_size     INTEGER NOT NULL,
      at            TEXT NOT NULL,
      FOREIGN KEY (run_id) REFERENCES verification_runs (id) ON DELETE CASCADE
    );
  ''');
  db.execute(
    'CREATE INDEX IF NOT EXISTS idx_verification_artifacts_run '
    'ON verification_artifacts (run_id);',
  );
}

void _migrateToV16(Database db) {
  // Why a session has a parent: spawn, handoff and fork read completely
  // differently, and the rows cannot be told apart afterwards.
  db.execute('ALTER TABLE sessions ADD COLUMN parent_link_kind TEXT;');

  // Backfilled, unusually, because it is a fact rather than a default:
  // `_openNewSession` was the sole writer of `parent_session_id` before this.
  db.execute(
    "UPDATE sessions SET parent_link_kind = 'spawn' "
    'WHERE parent_session_id IS NOT NULL AND parent_link_kind IS NULL;',
  );
}

void _migrateToV17(Database db) {
  // When this session's worktree was archived away. One directory goes; the
  // transcript, notes, checkpoints and ending status all stay.
  db.execute('ALTER TABLE sessions ADD COLUMN archived_at TEXT;');
}

/// A session's title is the user's only once they have typed one. `DEFAULT 0`
/// hands existing rows back to their CLI, which is all the column can know.
void _migrateToV27(Database db) {
  db.execute(
    'ALTER TABLE sessions ADD COLUMN title_by_user INTEGER NOT NULL DEFAULT 0;',
  );
}

/// A session carries its own model. Nullable and undefaulted like
/// `permission_mode`: null means "nobody chose", a state the user can return to.
void _migrateToV28(Database db) {
  db.execute('ALTER TABLE sessions ADD COLUMN model_id TEXT;');
}

/// Review comments as durable threads anchored to a `blob_sha` plus a line
/// range, so a stale thread renders as detached rather than silently re-anchored.
void _migrateToV30(Database db) {
  db.execute('''
    CREATE TABLE IF NOT EXISTS review_threads (
      id             TEXT PRIMARY KEY,
      repository_id  TEXT NOT NULL,
      file_path      TEXT NOT NULL,
      blob_sha       TEXT NOT NULL,
      start_line     INTEGER,
      end_line       INTEGER,
      anchor_excerpt TEXT,
      status         TEXT NOT NULL,
      session_id     TEXT,
      created_at     TEXT NOT NULL,
      updated_at     TEXT NOT NULL,
      FOREIGN KEY (repository_id) REFERENCES repositories (id) ON DELETE CASCADE
    );
  ''');
  // Every thread on a repository, grouped in memory by path. Indexed on the
  // pair, so one file's threads are a range scan for the MCP tools that ask by path.
  db.execute(
    'CREATE INDEX IF NOT EXISTS idx_review_threads_repo_path '
    'ON review_threads (repository_id, file_path);',
  );

  db.execute('''
    CREATE TABLE IF NOT EXISTS review_thread_comments (
      id          INTEGER PRIMARY KEY AUTOINCREMENT,
      thread_id   TEXT NOT NULL,
      sequence    INTEGER NOT NULL,
      author      TEXT NOT NULL,
      author_kind TEXT NOT NULL,
      body        TEXT NOT NULL,
      created_at  TEXT NOT NULL,
      FOREIGN KEY (thread_id) REFERENCES review_threads (id) ON DELETE CASCADE
    );
  ''');
  db.execute(
    'CREATE UNIQUE INDEX IF NOT EXISTS idx_review_thread_comment_sequence '
    'ON review_thread_comments (thread_id, sequence);',
  );
}

/// Saved Explorer sections: live groups over facts the app already has. Two
/// tables — what the user said, and the membership derived from it.
void _migrateToV29(Database db) {
  db.execute('''
    CREATE TABLE IF NOT EXISTS explorer_sections (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      kind TEXT NOT NULL,
      pattern TEXT,
      position INTEGER NOT NULL,
      collapsed INTEGER NOT NULL DEFAULT 1
    );
  ''');
  db.execute('''
    CREATE TABLE IF NOT EXISTS explorer_section_members (
      section_id TEXT NOT NULL
        REFERENCES explorer_sections(id) ON DELETE CASCADE,
      session_id TEXT NOT NULL,
      PRIMARY KEY (section_id, session_id)
    );
  ''');

  // `INSERT OR IGNORE`: the step must stay idempotent, and a seed that threw on
  // a re-run would be the one statement here that could not be applied twice.
  const seed = [
    ('section-pinned', 'Pinned', 'pinned', 0),
    ('section-checks-failing', 'Checks failing', 'checksFailing', 1),
    ('section-awaiting-input', 'Awaiting input', 'awaitingInput', 2),
    ('section-ended-in-failure', 'Ended in failure', 'endedInFailure', 3),
  ];
  for (final (id, name, kind, position) in seed) {
    db.execute(
      'INSERT OR IGNORE INTO explorer_sections '
      '(id, name, kind, pattern, position, collapsed) '
      'VALUES (?, ?, ?, NULL, ?, 1);',
      [id, name, kind, position],
    );
  }
}

/// Workspaces: the grouping level above project. Additive and only additive —
/// the owner's live database holds ~31 projects and thousands of sessions.
void _migrateToV31(Database db) {
  db.execute('''
    CREATE TABLE IF NOT EXISTS workspaces (
      id         TEXT PRIMARY KEY,
      name       TEXT NOT NULL,
      created_at TEXT NOT NULL
    );
  ''');
  db.execute(
    'CREATE UNIQUE INDEX IF NOT EXISTS idx_workspaces_name '
    'ON workspaces (name COLLATE NOCASE);',
  );
  // A `REFERENCES` clause is legal on `ADD COLUMN` precisely because the
  // default is NULL — which is also what every existing project gets.
  db.execute(
    'ALTER TABLE projects ADD COLUMN workspace_id TEXT '
    'REFERENCES workspaces (id) ON DELETE SET NULL;',
  );
}

/// What a context is *for*, in the user's own words: a name is enough to pick
/// a context and not enough to remember one.
void _migrateToV32(Database db) {
  db.execute('ALTER TABLE workspaces ADD COLUMN description TEXT;');
}

/// Saved command snippets. One table, no foreign keys, nothing seeded: a
/// snippet belongs to the person, not to a project, repository or session.
void _migrateToV33(Database db) {
  db.execute('''
    CREATE TABLE IF NOT EXISTS command_snippets (
      id         TEXT PRIMARY KEY,
      label      TEXT NOT NULL,
      command    TEXT NOT NULL,
      shell      TEXT,
      submit     INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );
  ''');
}

/// Todos, and the project a todo or a note is filed under. Both nullable:
/// filed under nothing is an ordinary todo, not an unfinished one.
void _migrateToV34(Database db) {
  db.execute('''
    CREATE TABLE IF NOT EXISTS todos (
      id         TEXT PRIMARY KEY,
      body       TEXT NOT NULL,
      done_at    TEXT,
      project_id TEXT REFERENCES projects (id) ON DELETE SET NULL,
      position   INTEGER NOT NULL,
      created_at TEXT NOT NULL
    );
  ''');
  // Serves exactly one query — the `SET NULL` fan-out when a project is
  // deleted, which without it scans every todo ever written.
  db.execute(
    'CREATE INDEX IF NOT EXISTS idx_todos_project ON todos (project_id);',
  );
  // `REFERENCES` is legal on `ADD COLUMN` because the default is NULL, which
  // is also what every existing note gets until the backfill below.
  db.execute(
    'ALTER TABLE notes ADD COLUMN project_id TEXT '
    'REFERENCES projects (id) ON DELETE SET NULL;',
  );
  db.execute(
    'CREATE INDEX IF NOT EXISTS idx_notes_project ON notes (project_id);',
  );
  db.execute('''
    UPDATE notes SET project_id = (
      SELECT project_id FROM repositories
       WHERE repositories.id = notes.source_repository_id
    )
    WHERE source_repository_id IS NOT NULL;
  ''');
}

/// Per-agent permission modes: a session records the mode in its agent's own
/// vocabulary instead of a shared three-value enum. Column name and type stay.
void _migrateToV35(Database db) {
  // (agent id, legacy value, canonical selection).
  const rewrites = [
    ('claudeCode', 'ask', 'mode=manual'),
    ('claudeCode', 'acceptEdits', 'mode=acceptEdits'),
    ('claudeCode', 'bypass', 'mode=bypassPermissions'),
    ('antigravity', 'ask', 'mode=prompt'),
    ('antigravity', 'acceptEdits', 'mode=accept-edits'),
    ('antigravity', 'bypass', 'mode=skip-permissions'),
    ('codex', 'ask', 'approval=on-request;sandbox=workspace-write'),
    ('codex', 'acceptEdits', 'approval=on-request;sandbox=workspace-write'),
    ('codex', 'bypass', 'approval=on-request;sandbox=bypass-all'),
  ];
  for (final (agentId, legacy, selection) in rewrites) {
    db.execute(
      'UPDATE sessions SET permission_mode = ? '
      'WHERE permission_mode = ? AND agent_installation_id IN '
      '(SELECT id FROM agent_installations WHERE agent_kind = ?);',
      [selection, legacy, agentId],
    );
  }
}

/// Index the CLI conversation a session records — the lookup import and
/// adoption run once per detected conversation.
void _migrateToV36(Database db) {
  db.execute(
    'CREATE INDEX IF NOT EXISTS idx_sessions_external '
    'ON sessions (external_session_id, created_at, id);',
  );
}

/// Index the installation a session ran under: re-detection, repoint, and the
/// foreign key check SQLite runs when an installation is removed.
void _migrateToV37(Database db) {
  db.execute(
    'CREATE INDEX IF NOT EXISTS idx_sessions_installation '
    'ON sessions (agent_installation_id);',
  );
}

/// Saved Codex OAuth identities. The whole token bundle is kept because
/// refresh token, account id and access token are one credential.
void _migrateToV38(Database db) {
  db.execute('''
    CREATE TABLE IF NOT EXISTS codex_accounts (
      id TEXT PRIMARY KEY,
      account_id TEXT NOT NULL UNIQUE,
      email TEXT,
      plan_type TEXT,
      auth_json TEXT NOT NULL,
      captured_env_id TEXT,
      captured_at TEXT NOT NULL
    );
  ''');
}

/// Whether a human chose an installation's executable path, so a sweep can fix
/// a broken one without ever overwriting an explicit choice.
void _migrateToV39(Database db) {
  final columns = db
      .select('PRAGMA table_info(agent_installations);')
      .map((row) => row['name'] as String);
  if (columns.contains('executable_by_user')) return;
  db.execute(
    'ALTER TABLE agent_installations '
    'ADD COLUMN executable_by_user INTEGER NOT NULL DEFAULT 0;',
  );
}

/// When an installation's version was last read from the binary, so a recorded
/// version is a dated reading rather than a bare number.
void _migrateToV40(Database db) {
  final columns = db
      .select('PRAGMA table_info(agent_installations);')
      .map((row) => row['name'] as String);
  if (columns.contains('version_read_at')) return;
  db.execute(
    'ALTER TABLE agent_installations ADD COLUMN version_read_at TEXT;',
  );
}

/// Full-text search over every conversation's *visible* turns, plus the
/// per-conversation watermark that keeps a re-index off an unmoved transcript.
void _migrateToV41(Database db) {
  db.execute('''
    CREATE TABLE IF NOT EXISTS conversation_turns (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      session_id TEXT NOT NULL,
      cli TEXT NOT NULL,
      ordinal INTEGER NOT NULL,
      role TEXT NOT NULL,
      text TEXT NOT NULL
    );
  ''');
  db.execute(
    'CREATE INDEX IF NOT EXISTS idx_conversation_turns_session '
    'ON conversation_turns(session_id);',
  );
  db.execute('''
    CREATE VIRTUAL TABLE IF NOT EXISTS conversation_turns_fts USING fts5(
      text,
      content = 'conversation_turns',
      content_rowid = 'id'
    );
  ''');
  // The three triggers FTS5 documents for external content. The update one is
  // here so the first UPDATE cannot leave the index describing the old text.
  db.execute('''
    CREATE TRIGGER IF NOT EXISTS conversation_turns_ai
    AFTER INSERT ON conversation_turns BEGIN
      INSERT INTO conversation_turns_fts (rowid, text)
      VALUES (new.id, new.text);
    END;
  ''');
  db.execute('''
    CREATE TRIGGER IF NOT EXISTS conversation_turns_ad
    AFTER DELETE ON conversation_turns BEGIN
      INSERT INTO conversation_turns_fts (conversation_turns_fts, rowid, text)
      VALUES ('delete', old.id, old.text);
    END;
  ''');
  db.execute('''
    CREATE TRIGGER IF NOT EXISTS conversation_turns_au
    AFTER UPDATE ON conversation_turns BEGIN
      INSERT INTO conversation_turns_fts (conversation_turns_fts, rowid, text)
      VALUES ('delete', old.id, old.text);
      INSERT INTO conversation_turns_fts (rowid, text)
      VALUES (new.id, new.text);
    END;
  ''');
  // `modified_at` and `size` are nullable together: a transcript read without a
  // stat is indexed and has no watermark. An unknown is not a zero (§19).
  db.execute('''
    CREATE TABLE IF NOT EXISTS conversation_index_state (
      session_id TEXT PRIMARY KEY,
      cli TEXT NOT NULL,
      file_path TEXT NOT NULL,
      modified_at TEXT,
      size INTEGER,
      turns INTEGER NOT NULL,
      indexed_at TEXT NOT NULL
    );
  ''');
}

/// Worktree setup: what a repository wants done to a worktree git has just
/// made, and the recorded verdict of the last time it was done.
void _migrateToV42(Database db) {
  db.execute('''
    CREATE TABLE IF NOT EXISTS worktree_setup (
      repository_id TEXT PRIMARY KEY
        REFERENCES repositories(id) ON DELETE CASCADE,
      command       TEXT,
      copy_paths    TEXT NOT NULL DEFAULT '[]',
      updated_at    TEXT NOT NULL
    );
  ''');
  db.execute('''
    CREATE TABLE IF NOT EXISTS worktree_setup_runs (
      repository_id  TEXT NOT NULL
        REFERENCES repositories(id) ON DELETE CASCADE,
      worktree_path  TEXT NOT NULL,
      environment_id TEXT NOT NULL,
      ran_at         TEXT NOT NULL,
      verdict        TEXT NOT NULL,
      detail         TEXT NOT NULL,
      PRIMARY KEY (repository_id, worktree_path)
    );
  ''');
}

/// Scheduled automations, their occurrences, and the preconditions that gate
/// them. The gate is the feature.
void _migrateToV43(Database db) {
  db.execute('''
    CREATE TABLE IF NOT EXISTS automations (
      id                    TEXT PRIMARY KEY,
      repository_id         TEXT NOT NULL
        REFERENCES repositories(id) ON DELETE CASCADE,
      name                  TEXT NOT NULL,
      cron                  TEXT,
      fires_at              TEXT,
      agent_installation_id TEXT NOT NULL,
      prompt                TEXT NOT NULL,
      permission_mode       TEXT,
      enabled               INTEGER NOT NULL DEFAULT 1,
      armed_at              TEXT NOT NULL
    );
  ''');
  db.execute(
    'CREATE INDEX IF NOT EXISTS idx_automations_repository '
    'ON automations (repository_id);',
  );
  db.execute('''
    CREATE TABLE IF NOT EXISTS automation_runs (
      id                 TEXT PRIMARY KEY,
      automation_id      TEXT NOT NULL
        REFERENCES automations(id) ON DELETE CASCADE,
      scheduled_for      TEXT NOT NULL,
      fired_at           TEXT NOT NULL,
      state              TEXT NOT NULL,
      reason             TEXT NOT NULL DEFAULT '',
      base_checkpoint_id TEXT,
      session_id         TEXT,
      finished_at        TEXT,
      commits_made       INTEGER
    );
  ''');
  db.execute(
    'CREATE INDEX IF NOT EXISTS idx_automation_runs_automation '
    'ON automation_runs (automation_id, scheduled_for);',
  );
  db.execute('''
    CREATE TABLE IF NOT EXISTS project_verification (
      repository_id TEXT PRIMARY KEY
        REFERENCES repositories(id) ON DELETE CASCADE,
      enabled       INTEGER NOT NULL DEFAULT 0,
      updated_at    TEXT NOT NULL
    );
  ''');
  db.execute('''
    CREATE TABLE IF NOT EXISTS project_checks (
      id            TEXT PRIMARY KEY,
      repository_id TEXT NOT NULL
        REFERENCES repositories(id) ON DELETE CASCADE,
      name          TEXT NOT NULL,
      command       TEXT NOT NULL,
      created_at    TEXT NOT NULL
    );
  ''');
  db.execute(
    'CREATE INDEX IF NOT EXISTS idx_project_checks_repository '
    'ON project_checks (repository_id);',
  );
}

/// What repository a checkout *is*, as distinct from where it is: a nullable
/// canonical id derived from `origin`.
void _migrateToV44(Database db) {
  final columns = db
      .select('PRAGMA table_info(repositories);')
      .map((row) => row['name'] as String)
      .toSet();
  if (columns.contains('canonical_id')) return;
  db.execute('ALTER TABLE repositories ADD COLUMN canonical_id TEXT;');
}

/// A named workbench shape the user can reopen. One `shape` column holds the
/// whole document rather than a row per tab and a row per pane.
void _migrateToV45(Database db) {
  db.execute('''
    CREATE TABLE IF NOT EXISTS terminal_presets (
      id         TEXT PRIMARY KEY,
      name       TEXT NOT NULL,
      shape      TEXT NOT NULL,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );
  ''');
}

/// The verdicts an automation's project checks left on one occurrence: a row
/// per check, plus a timestamp saying the checks were looked at at all.
void _migrateToV46(Database db) {
  db.execute('''
    CREATE TABLE IF NOT EXISTS automation_run_checks (
      run_id              TEXT NOT NULL
        REFERENCES automation_runs(id) ON DELETE CASCADE,
      ordinal             INTEGER NOT NULL,
      check_id            TEXT,
      name                TEXT NOT NULL,
      command             TEXT NOT NULL,
      verdict             TEXT NOT NULL,
      reason              TEXT NOT NULL,
      verification_run_id TEXT,
      checked_at          TEXT NOT NULL,
      PRIMARY KEY (run_id, ordinal)
    );
  ''');
  final columns = db
      .select('PRAGMA table_info(automation_runs);')
      .map((row) => row['name'] as String);
  if (columns.contains('checks_observed_at')) return;
  db.execute('ALTER TABLE automation_runs ADD COLUMN checks_observed_at TEXT;');
}

/// A companion's presence, as it last described itself. Four nullable columns
/// and no defaults, because each has to be able to say *nothing was said*.
void _migrateToV47(Database db) {
  final columns = db
      .select('PRAGMA table_info(paired_devices);')
      .map((row) => row['name'] as String);
  if (columns.contains('presence_at')) return;
  db.execute('ALTER TABLE paired_devices ADD COLUMN presence_kind TEXT;');
  db.execute('ALTER TABLE paired_devices ADD COLUMN presence_visibility TEXT;');
  db.execute('ALTER TABLE paired_devices ADD COLUMN presence_session TEXT;');
  db.execute('ALTER TABLE paired_devices ADD COLUMN presence_at TEXT;');
}

/// The recap a person asked a session's own CLI to write. One row per session,
/// replaced on each request.
void _migrateToV48(Database db) {
  db.execute('''
    CREATE TABLE IF NOT EXISTS session_recaps (
      session_id TEXT PRIMARY KEY,
      text       TEXT NOT NULL,
      agent_id   TEXT NOT NULL,
      model      TEXT,
      turn_count INTEGER NOT NULL,
      written_at TEXT NOT NULL,
      FOREIGN KEY (session_id) REFERENCES sessions (id) ON DELETE CASCADE
    );
  ''');
}

/// Which checkout a project's one-click "New session" runs in. Null means the
/// old rule — the first checkout the picker would offer — so nothing is
/// implied about projects that never chose.
void _migrateToV49(Database db) {
  db.execute(
    'ALTER TABLE projects ADD COLUMN default_repository_id TEXT '
    'REFERENCES repositories (id) ON DELETE SET NULL;',
  );
}

/// Retires `settings.v1`'s either/or `remoteRelayMode`: a setup that used the
/// local relay and never wrote the side-by-side prefs gets them written, so
/// the next settings save, which drops the key, cannot switch it back to
/// hosted. `remote.relay_prefs.v1` is the app's `kRelayPrefsMetadataKey`.
void _migrateToV50(Database db) {
  const prefsKey = 'remote.relay_prefs.v1';
  final existing = db.select(
    'SELECT 1 FROM app_metadata WHERE key = ?;',
    [prefsKey],
  );
  if (existing.isNotEmpty) return;
  final settingsRows = db.select(
    "SELECT value FROM app_metadata WHERE key = 'settings.v1';",
  );
  if (settingsRows.isEmpty) return;
  try {
    final decoded = jsonDecode(settingsRows.first['value'] as String);
    // Hosted, junk or absent is what unset prefs already mean.
    if (decoded is! Map<String, dynamic> ||
        decoded['remoteRelayMode'] != 'local') {
      return;
    }
  } on FormatException {
    return;
  }
  db.execute(
    'INSERT INTO app_metadata (key, value, updated_at) VALUES (?, ?, ?);',
    [
      prefsKey,
      jsonEncode({'local': true, 'hosted': false}),
      DateTime.now().toUtc().toIso8601String(),
    ],
  );
}
