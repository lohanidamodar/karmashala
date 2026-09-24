part of '../migrations.dart';

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

void _migrateToV22(Database db) {
  // Where a session's agent actually runs. Deliberately not `worktree`, which
  // `SessionArchiveService` hands to `git worktree remove` — that deletes it.
  db.execute(
    'ALTER TABLE sessions ADD COLUMN working_directory_environment_id TEXT;',
  );
  db.execute('ALTER TABLE sessions ADD COLUMN working_directory_path TEXT;');
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

void _migrateToV24(Database db) {
  db.execute(
    'CREATE INDEX IF NOT EXISTS idx_sessions_pane ON sessions (pane_id);',
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
