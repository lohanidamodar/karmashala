part of '../migrations.dart';

void _migrateToV1(Database db) {
  db.execute('''
    CREATE TABLE IF NOT EXISTS app_metadata (
      key        TEXT PRIMARY KEY,
      value      TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );
  ''');
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

void _migrateToV5(Database db) {
  // The CLI's own identity for a native session, distinct from our row id and
  // required to resume the same conversation in an external terminal.
  db.execute('ALTER TABLE sessions ADD COLUMN external_session_id TEXT;');
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

void _migrateToV19(Database db) {
  // Which relay this device's frames travel through: a hosted URL, or the
  // sentinel `'local'` — the machine's IP moves, "my own relay" does not.
  db.execute('ALTER TABLE paired_devices ADD COLUMN relay_url TEXT;');

  // Every pre-v19 pairing went through the one configured relay; absent or
  // unreadable settings mean this build's hosted relay, or none at all.
  String? relayUrl = const String.fromEnvironment('KARMASHALA_RELAY_URL');
  if (relayUrl.isEmpty) relayUrl = null;
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
