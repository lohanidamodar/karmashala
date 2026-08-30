import 'package:sqlite3/sqlite3.dart';

/// A single schema migration step: SQL applied to move the database **to** the
/// keyed version. Steps are hand-written (no code generation) and must be
/// idempotent at the DDL level (`IF NOT EXISTS`) so re-runs are safe.
typedef MigrationStep = void Function(Database db);

/// Ordered schema migrations, keyed by the target `user_version`.
///
/// The database applies every step whose version is greater than the stored
/// `PRAGMA user_version`, in ascending order, inside a transaction each. The
/// highest key here is the current [AppDatabase.schemaVersion].
///
/// * **v1** — Loop 0: the `app_metadata` key/value table.
/// * **v2** — Loop 1: the core domain schema (environments, projects,
///   repositories, agent installations, sessions, and the append-only
///   session-event log).
/// * **v7** — Loop 29: the terminal workspace (tabs, their pane split trees and
///   each pane's persisted scrollback).
/// * **v8** — Loop 37: SSH as an execution environment (saved hosts, trusted
///   host keys, and the `ssh_host_id` link on `execution_environments`).
/// * **v10** — Loop 41: agents hosted in terminal panes — a pane records the
///   agent command it ran, and a session records which pane it lives in and
///   which session (if any) asked for it.
/// * **v11** — Loop 49: a session carries its own permission mode, so the
///   composer control has somewhere to write and the resolver has one place to
///   read.
/// * **v12** — Loop 54: a session records *why* it has a parent — spawned,
///   handed off to another provider, or forked — so lineage can be drawn
///   without inferring the relationship from the two rows.
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
};

void _migrateToV8(Database db) {
  // SSH as a third kind of execution environment (Loop 37). An `ssh` row in
  // `execution_environments` points at the `ssh_hosts` row that says where it
  // is and how to log in.
  db.execute('ALTER TABLE execution_environments ADD COLUMN ssh_host_id TEXT;');

  // Saved remote hosts. Deliberately **not** a credential store: no password,
  // no passphrase and no key material is written here. `private_key_path` is
  // where the key file lives, paired with the environment that owns that path
  // (principle 2) — the key itself is read at connect time and never copied
  // into the database. Passwords and passphrases are prompted per connection
  // and held in memory only.
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

  // Trusted host keys — our known_hosts. One row per `host:port`: the presented
  // fingerprint must equal the stored one, and a mismatch is the MITM signal, so
  // the primary key is deliberately the address and not the address plus key
  // type. Re-trusting a legitimately rebuilt host means deleting the row, which
  // is an explicit user action.
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
  // The terminal workspace (Loop 29): which tabs were open, how each tab's panes
  // were split, and each pane's scrollback, so the terminal comes back after a
  // restart. `layout` is the pane tree as JSON (see PaneLayout.toJson);
  // `scrollback` is the rendered buffer re-emitted as text + SGR runs, capped
  // per pane — inert replayed content, never a command to re-run.
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
  // Saved Claude Code accounts (Loop 22): OAuth token snapshots captured from a
  // Claude installation so the user can switch the logged-in account without
  // re-authenticating. `claude_ai_oauth` and `oauth_account` hold the two JSON
  // blobs Claude Code persists (the token bundle from `.credentials.json` and
  // the identity record from `.claude.json`); the other columns are denormalized
  // copies for display. Uniqueness is by (email, organization_uuid) so the same
  // email in two orgs stays distinct while re-capturing the same account
  // updates in place.
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
  // The CLI's own identity for a native session. This is deliberately distinct
  // from the app's row id and is required to resume the same conversation in an
  // external terminal.
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

  // Projects: a logical workspace rooted at a folder in some environment.
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
  // A session may span multiple repositories within its project (Loop 13). The
  // `sessions.repository_id` column remains the primary repository; this link
  // table records every repository a session is associated with.
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
  // Sessions imported from a CLI store (Claude Code / Codex) — a read-only
  // history that lives beside native engine sessions (Loop 20). Kept in its own
  // table so the native `sessions` schema/FKs are untouched. `UNIQUE(source,
  // external_id)` makes re-imports idempotent (duplicates ignored).
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
  // Keep-alive (Loop 38): closing a tab no longer kills the process behind it,
  // so a session can be running with no tab showing it. Those are stored in the
  // same table as a single-pane row with `detached = 1`, which keeps their
  // scrollback on exactly the same persistence path as a tab's — the alternative
  // was the one kind of session whose history quietly vanished on quit.
  //
  // They never come back *as* tabs: on load they are listed as background
  // sessions the user can reopen or end.
  db.execute(
    'ALTER TABLE terminal_tabs ADD COLUMN detached INTEGER NOT NULL DEFAULT 0;',
  );
}

void _migrateToV10(Database db) {
  // Agents in a PTY (Loop 41).
  //
  // `launch_command` lets a pane be restored as the agent it was rather than as
  // the shell profile it never had. It is deliberately on the *pane*, not on a
  // session: the dormant restore path re-executes nothing, so recording a
  // command here can only be read by `startPane`, which is the user explicitly
  // asking for it.
  db.execute('ALTER TABLE terminal_panes ADD COLUMN launch_command TEXT;');

  // `parent_session_id` is the *only* record of agent-spawn depth. The depth
  // itself is walked from this chain and never stored: a stored number is a
  // second source of truth that will eventually disagree with the chain it
  // claims to describe. Deliberately not a foreign key — deleting a parent must
  // orphan its children, not cascade away sessions the user still has open.
  db.execute('ALTER TABLE sessions ADD COLUMN parent_session_id TEXT;');

  // The terminal pane a session runs in, for sessions hosted in a PTY rather
  // than driven through a protocol adapter. Null for chat sessions and for
  // sessions launched into an external terminal, which we do not own a pane for.
  db.execute('ALTER TABLE sessions ADD COLUMN pane_id TEXT;');

  // Where the process lives, and how the session is drawn. Two columns because
  // they are two questions: `surface` is a runtime fact (we own the PTY, or
  // somebody else's terminal window does) and `view` is a rendering the user can
  // flip without starting or stopping anything.
  //
  // Rows written before this migration were driven by a protocol adapter with no
  // terminal of any kind, so `external` is the closest true answer for them — we
  // do not own a process for them either — and `chat` is what they were actually
  // showing. Neither default claims a pane that does not exist.
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
  // Per-session permission mode (Loop 49).
  //
  // Until now the mode was resolved at launch from the per-agent setting and
  // then thrown away with the local that held it, so nothing could say what a
  // running session was actually running under — which is exactly what a
  // control claiming to show the *effective* mode has to answer.
  //
  // Nullable with no default, and null is a real answer: "written before this
  // column existed, ask the settings". Every row created from here on is
  // stamped at launch, so null never means "unknown" for a new session. A
  // `NOT NULL DEFAULT 'ask'` would have been a lie for the old rows, half of
  // which were launched under a different mode entirely.
  db.execute('ALTER TABLE sessions ADD COLUMN permission_mode TEXT;');
}

void _migrateToV12(Database db) {
  // Why a session has a parent (Loop 54).
  //
  // `parent_session_id` arrived in v10 with exactly one way to acquire one: an
  // agent calling `open_new_session` over MCP. Handoff and fork are two more,
  // and they are not the same relationship — "an agent delegated this", "the
  // user moved this to another provider" and "the user branched this" read
  // completely differently in a sidebar, and the rows themselves cannot be told
  // apart afterwards. Two sessions in one repository with one naming the other
  // look identical whichever of the three produced them.
  //
  // Nullable, and null is a real answer for a *pre-v12* row: "we did not record
  // it". Unlike depth, this is not derivable from the chain, so there is no
  // second source of truth to disagree with — a link kind is a fact about the
  // moment of creation, and nothing else keeps it.
  db.execute('ALTER TABLE sessions ADD COLUMN parent_link_kind TEXT;');

  // Backfilled, unusually for this schema, and only because the backfill is a
  // *fact* rather than a default. Every existing parented row was written by
  // `LauncherControlServer._openNewSession` — the sole writer of
  // `parent_session_id` in the app before this migration — so `spawn` is what
  // those rows actually are, not the safest guess about them. Rows with no
  // parent are left null, because there is no relationship to name.
  db.execute(
    "UPDATE sessions SET parent_link_kind = 'spawn' "
    'WHERE parent_session_id IS NOT NULL AND parent_link_kind IS NULL;',
  );
}
