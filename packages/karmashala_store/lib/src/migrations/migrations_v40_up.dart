part of '../migrations.dart';

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
  final existing = db.select('SELECT 1 FROM app_metadata WHERE key = ?;', [
    prefsKey,
  ]);
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

/// Usage history: one row per measured quota window per fresh reading. Pruned
/// and downsampled by its writer, so the table stays small without a job.
void _migrateToV51(Database db) {
  db.execute('''
    CREATE TABLE IF NOT EXISTS usage_samples (
      account_key  TEXT NOT NULL,
      window_label TEXT NOT NULL,
      span_seconds INTEGER,
      percent      REAL NOT NULL,
      resets_at    TEXT,
      recorded_at  TEXT NOT NULL,
      PRIMARY KEY (account_key, window_label, recorded_at)
    );
  ''');
  db.execute(
    'CREATE INDEX IF NOT EXISTS idx_usage_samples_recorded '
    'ON usage_samples (recorded_at);',
  );
}

/// Which turn a checkpoint belongs to and what was asked, and each file's
/// line counts. Nullable: older rows never recorded any of it.
void _migrateToV52(Database db) {
  void addColumn(String table, String column, String type) {
    final columns = db
        .select('PRAGMA table_info($table);')
        .map((row) => row['name'] as String);
    if (columns.contains(column)) return;
    db.execute('ALTER TABLE $table ADD COLUMN $column $type;');
  }

  addColumn('session_checkpoints', 'turn', 'INTEGER');
  addColumn('session_checkpoints', 'prompt', 'TEXT');
  addColumn('session_checkpoint_files', 'additions', 'INTEGER');
  addColumn('session_checkpoint_files', 'deletions', 'INTEGER');
  db.execute(
    'CREATE INDEX IF NOT EXISTS idx_session_checkpoints_repository '
    'ON session_checkpoints (session_id, environment_id, repository_path, '
    'sequence);',
  );
}

/// A session the user asked to have resumed at a moment, usually a usage
/// window's reset. At most one live row per session; ended rows are the record.
void _migrateToV53(Database db) {
  db.execute('''
    CREATE TABLE IF NOT EXISTS scheduled_resumes (
      id                  TEXT PRIMARY KEY,
      session_id          TEXT NOT NULL,
      account_key         TEXT NOT NULL DEFAULT '',
      account_email       TEXT,
      window_label        TEXT,
      resets_at           TEXT,
      fire_at             TEXT NOT NULL,
      message             TEXT NOT NULL DEFAULT '',
      permission_mode     TEXT,
      notify              INTEGER NOT NULL DEFAULT 0,
      late_policy         TEXT NOT NULL DEFAULT 'ask',
      state               TEXT NOT NULL,
      reason              TEXT NOT NULL DEFAULT '',
      attempts            INTEGER NOT NULL DEFAULT 0,
      live_when_scheduled INTEGER NOT NULL DEFAULT 0,
      scheduled_by        TEXT NOT NULL DEFAULT 'the user',
      scheduled_at        TEXT NOT NULL,
      finished_at         TEXT,
      FOREIGN KEY (session_id) REFERENCES sessions (id) ON DELETE CASCADE
    );
  ''');
  db.execute(
    'CREATE UNIQUE INDEX IF NOT EXISTS idx_scheduled_resumes_live '
    'ON scheduled_resumes (session_id) '
    "WHERE state IN ('pending', 'queued', 'firing');",
  );
  db.execute(
    'CREATE INDEX IF NOT EXISTS idx_scheduled_resumes_fire_at '
    'ON scheduled_resumes (state, fire_at);',
  );
}

/// A context's colour, by the name of a hue the app's theme paints. Nullable:
/// a context has none until its owner picks one.
void _migrateToV54(Database db) {
  final columns = db
      .select('PRAGMA table_info(workspaces);')
      .map((row) => row['name'] as String);
  if (columns.contains('color')) return;
  db.execute('ALTER TABLE workspaces ADD COLUMN color TEXT;');
}

/// Recurring automations grow up: a gap measured from the last run's finish,
/// a per-automation late policy, a failure budget that disables a broken one
/// rather than letting it fail every night forever, and a runtime ceiling so a
/// hung run cannot hold its checkout for good.
///
/// Every column has a default that reproduces the old behaviour exactly, so an
/// existing automation keeps firing the way it did.
void _migrateToV55(Database db) {
  final columns = db
      .select('PRAGMA table_info(automations);')
      .map((row) => row['name'] as String)
      .toSet();
  void add(String name, String definition) {
    if (columns.contains(name)) return;
    db.execute('ALTER TABLE automations ADD COLUMN $name $definition;');
  }

  add('every_seconds', 'INTEGER');
  add('late_policy', "TEXT NOT NULL DEFAULT 'ask'");
  add('stop_after_failures', 'INTEGER NOT NULL DEFAULT 3');
  add('consecutive_failures', 'INTEGER NOT NULL DEFAULT 0');
  add('disabled_reason', 'TEXT');
  add('max_runtime_seconds', 'INTEGER');
}

/// Session search, second pass: a stored resume point per transcript so a
/// re-index reads only appended bytes, each turn's own time for date filters,
/// a prefix index so a half-typed word is one lookup, and a vocabulary view of
/// the FTS index for typo repair.
///
/// The columns are metadata-only — `ADD COLUMN` with no default rewrites no
/// rows — and old rows keep a null resume point and `at` until their
/// transcript next moves and is read whole once. The one step that costs is
/// the prefix index: FTS5 takes `prefix=` only at creation, so the index is
/// recreated and rebuilt from `conversation_turns`, inside this migration's
/// transaction. It reads no transcript, and runs once: a table that already
/// has the option is left alone.
void _migrateToV56(Database db) {
  Set<String> columnsOf(String table) => db
      .select('PRAGMA table_info($table);')
      .map((row) => row['name'] as String)
      .toSet();

  final state = columnsOf('conversation_index_state');
  void addState(String name, String type) {
    if (state.contains(name)) return;
    db.execute('ALTER TABLE conversation_index_state ADD COLUMN $name $type;');
  }

  addState('read_offset', 'INTEGER');
  addState('read_rows', 'INTEGER');
  addState('read_anchor', 'BLOB');
  addState('read_head', 'BLOB');

  if (!columnsOf('conversation_turns').contains('at')) {
    db.execute('ALTER TABLE conversation_turns ADD COLUMN at TEXT;');
  }

  // Without it a last word of two or three letters expands to every term that
  // starts with them, and FTS5 merges all their doclists before any LIMIT —
  // measured at over half a second for one keystroke on 45,000 turns.
  final fts = db.select(
    "SELECT sql FROM sqlite_master WHERE name = 'conversation_turns_fts';",
  );
  final ftsSql = fts.isEmpty ? '' : fts.first['sql'] as String? ?? '';
  if (!ftsSql.contains('prefix')) {
    db.execute('DROP TABLE IF EXISTS conversation_turns_vocab;');
    db.execute('DROP TABLE IF EXISTS conversation_turns_fts;');
    db.execute('''
      CREATE VIRTUAL TABLE conversation_turns_fts USING fts5(
        text,
        content = 'conversation_turns',
        content_rowid = 'id',
        prefix = '2 3'
      );
    ''');
    db.execute(
      'INSERT INTO conversation_turns_fts (conversation_turns_fts) '
      "VALUES ('rebuild');",
    );
  }

  db.execute(
    'CREATE VIRTUAL TABLE IF NOT EXISTS conversation_turns_vocab '
    "USING fts5vocab(conversation_turns_fts, 'row');",
  );
}

/// Automations that fire on an event rather than a clock, and the origin chain
/// that stops one answering its own action.
///
/// `automations.trigger_event` / `event_action` are null for every existing
/// row, which is exactly "time-based" — nothing armed changes. A run records
/// the chain of automations that led to it (`origin`, JSON) and the session
/// whose event fired it (`event_session_id`). `automation_session_origins`
/// holds, per session, the chain of the automation message on its way in, so
/// the one turn that message causes is known to be the automation's.
void _migrateToV57(Database db) {
  Set<String> columnsOf(String table) => db
      .select('PRAGMA table_info($table);')
      .map((row) => row['name'] as String)
      .toSet();
  void add(Set<String> existing, String table, String name, String type) {
    if (existing.contains(name)) return;
    db.execute('ALTER TABLE $table ADD COLUMN $name $type;');
  }

  final automations = columnsOf('automations');
  add(automations, 'automations', 'trigger_event', 'TEXT');
  add(automations, 'automations', 'event_action', 'TEXT');

  final runs = columnsOf('automation_runs');
  add(runs, 'automation_runs', 'origin', 'TEXT');
  add(runs, 'automation_runs', 'event_session_id', 'TEXT');

  db.execute('''
    CREATE TABLE IF NOT EXISTS automation_session_origins (
      session_id  TEXT PRIMARY KEY
        REFERENCES sessions (id) ON DELETE CASCADE,
      origin      TEXT NOT NULL,
      recorded_at TEXT NOT NULL
    );
  ''');
}

/// Every message one session sent another through `session_send`: who sent
/// it, to whom, the text as sent, and when. Its own table rather than
/// `session_events`, which is the chat engine's log — a relay row there would
/// make a PTY session look as if it had one.
///
/// `from_session_id` is not a foreign key: a sender's row may be deleted and
/// the record of what it said should outlive it.
void _migrateToV58(Database db) {
  db.execute('''
    CREATE TABLE IF NOT EXISTS session_relays (
      id              INTEGER PRIMARY KEY AUTOINCREMENT,
      from_session_id TEXT NOT NULL,
      to_session_id   TEXT NOT NULL
        REFERENCES sessions (id) ON DELETE CASCADE,
      text            TEXT NOT NULL,
      created_at      TEXT NOT NULL
    );
  ''');
  db.execute(
    'CREATE INDEX IF NOT EXISTS idx_session_relays_to '
    'ON session_relays (to_session_id, created_at);',
  );
  db.execute(
    'CREATE INDEX IF NOT EXISTS idx_session_relays_pair '
    'ON session_relays (from_session_id, to_session_id, created_at);',
  );
}

/// The terminal layout is each client's own (`TerminalLayoutStore`, in the
/// app-support folder): the server keeps none of it. Dropped, not moved.
void _migrateToV59(Database db) {
  db.execute('DROP TABLE IF EXISTS terminal_panes;');
  db.execute('DROP TABLE IF EXISTS terminal_tabs;');
  db.execute('DROP TABLE IF EXISTS terminal_panes_backup;');
  db.execute('DROP TABLE IF EXISTS terminal_tabs_backup;');
  db.execute("DELETE FROM app_metadata WHERE key LIKE 'terminal.%';");
}

/// Whether the person let a session's agent operate Karmashala
/// (`Session.operatorGranted`). Off for every session, old ones included:
/// the tools that act were open to every session before, and are not now.
void _migrateToV60(Database db) {
  final columns = db
      .select('PRAGMA table_info(sessions);')
      .map((row) => row['name'] as String);
  if (columns.contains('operator_granted')) return;
  db.execute(
    'ALTER TABLE sessions ADD COLUMN operator_granted INTEGER NOT NULL '
    'DEFAULT 0;',
  );
}

/// Named `flutter run` configurations, per project so every checkout and
/// worktree of it shares them. Lists are JSON arrays of strings.
void _migrateToV61(Database db) {
  db.execute('''
    CREATE TABLE IF NOT EXISTS flutter_run_configurations (
      id                TEXT PRIMARY KEY,
      project_id        TEXT NOT NULL
        REFERENCES projects (id) ON DELETE CASCADE,
      name              TEXT NOT NULL,
      project_directory TEXT,
      target            TEXT,
      flavor            TEXT,
      build_mode        TEXT NOT NULL DEFAULT 'debug',
      dart_defines      TEXT NOT NULL DEFAULT '[]',
      dart_define_files TEXT NOT NULL DEFAULT '[]',
      device_id         TEXT,
      created_at        TEXT NOT NULL,
      updated_at        TEXT NOT NULL,
      UNIQUE (project_id, name)
    );
  ''');
}

/// Each project check's output read as data — analyzer diagnostics or test
/// results — so a later run of the same check can be compared with it. No
/// foreign keys: a reading outlives the session and the run that made it.
void _migrateToV62(Database db) {
  db.execute('''
    CREATE TABLE IF NOT EXISTS check_results (
      id                  INTEGER PRIMARY KEY AUTOINCREMENT,
      verification_run_id TEXT,
      session_id          TEXT,
      repository_id       TEXT NOT NULL,
      directory           TEXT,
      check_name          TEXT NOT NULL,
      recorded_at         TEXT NOT NULL,
      results             TEXT NOT NULL
    );
  ''');
  db.execute(
    'CREATE INDEX IF NOT EXISTS idx_check_results_check '
    'ON check_results (repository_id, check_name, recorded_at);',
  );
  db.execute(
    'CREATE INDEX IF NOT EXISTS idx_check_results_session '
    'ON check_results (session_id, recorded_at);',
  );
}

/// Screenshots filed against the checkpoint whose working tree they showed, so
/// two checkpoints' pictures can be compared. The PNG is a file beside the
/// store; a checkpoint's deletion takes its rows with it.
void _migrateToV63(Database db) {
  db.execute('''
    CREATE TABLE IF NOT EXISTS checkpoint_screenshots (
      id            TEXT PRIMARY KEY,
      checkpoint_id TEXT NOT NULL
        REFERENCES session_checkpoints (id) ON DELETE CASCADE,
      session_id    TEXT,
      source        TEXT NOT NULL,
      size          TEXT NOT NULL,
      width         INTEGER NOT NULL,
      height        INTEGER NOT NULL,
      subject       TEXT,
      label         TEXT,
      path          TEXT NOT NULL,
      captured_at   TEXT NOT NULL
    );
  ''');
  db.execute(
    'CREATE INDEX IF NOT EXISTS idx_checkpoint_screenshots_checkpoint '
    'ON checkpoint_screenshots (checkpoint_id, captured_at);',
  );
  db.execute(
    'CREATE INDEX IF NOT EXISTS idx_checkpoint_screenshots_session '
    'ON checkpoint_screenshots (session_id, captured_at);',
  );
}

/// What kind of project a row is. Null is an ordinary project; `scratch` is
/// the server-owned folder sessions without a project run in, one per
/// environment, which the rules key on rather than on its path.
void _migrateToV64(Database db) {
  final columns = db
      .select('PRAGMA table_info(projects);')
      .map((row) => row['name'] as String);
  if (columns.contains('kind')) return;
  db.execute('ALTER TABLE projects ADD COLUMN kind TEXT;');
}

/// An ACP session's conversation, written by the server from the agent's
/// `session/update` stream. `revision` is per session, so a
/// client naming the one it holds is sent only the rows that moved.
void _migrateToV65(Database db) {
  db.execute('''
    CREATE TABLE IF NOT EXISTS session_messages (
      id          TEXT PRIMARY KEY,
      session_id  TEXT NOT NULL REFERENCES sessions (id) ON DELETE CASCADE,
      ordinal     INTEGER NOT NULL,
      role        TEXT NOT NULL,
      text        TEXT NOT NULL DEFAULT '',
      thinking    TEXT,
      tool_json   TEXT,
      plan_json   TEXT,
      message_id  TEXT,
      revision    INTEGER NOT NULL,
      created_at  TEXT NOT NULL,
      updated_at  TEXT NOT NULL,
      UNIQUE (session_id, ordinal)
    );
  ''');
  db.execute(
    'CREATE INDEX IF NOT EXISTS idx_session_messages_revision '
    'ON session_messages (session_id, revision);',
  );
}

/// What an installation's executable is run with before any launch's own
/// arguments — `["-y", "<package>"]` when the executable is `npx` standing in
/// for an uninstalled ACP agent. A JSON list; null is none.
void _migrateToV66(Database db) {
  final columns = db
      .select('PRAGMA table_info(agent_installations);')
      .map((row) => row['name'] as String);
  if (columns.contains('leading_arguments')) return;
  db.execute(
    'ALTER TABLE agent_installations ADD COLUMN leading_arguments TEXT;',
  );
}

/// The ACP agents a person added — typed in (`custom`) or picked from the
/// public registry (`registry`) — each a command, its argv and environment
///. The server composes its agent registry from these.
void _migrateToV67(Database db) {
  db.execute('''
    CREATE TABLE IF NOT EXISTS acp_agents (
      id           TEXT PRIMARY KEY,
      name         TEXT NOT NULL,
      command      TEXT NOT NULL,
      args         TEXT NOT NULL DEFAULT '[]',
      env          TEXT NOT NULL DEFAULT '{}',
      source       TEXT NOT NULL,
      registry_id  TEXT,
      created_at   TEXT NOT NULL
    );
  ''');
}

/// The registry entry's icon URL beside an ACP agent row, so the agent is
/// drawn with its own icon rather than a generic glyph. Null for a row typed
/// in by hand or kept before this column.
void _migrateToV68(Database db) {
  final columns = db
      .select('PRAGMA table_info(acp_agents);')
      .map((row) => row['name'] as String);
  if (columns.contains('icon_url')) return;
  db.execute('ALTER TABLE acp_agents ADD COLUMN icon_url TEXT;');
}

/// What an ACP session's agent reported of its own usage (`usage_update`):
/// the latest context used of its size and the cumulative cost, and one
/// entry per turn in `turns_json` — the last report before the turn ended.
/// Nothing is computed here; a column is null until the agent said it.
void _migrateToV69(Database db) {
  db.execute('''
    CREATE TABLE IF NOT EXISTS session_usage (
      session_id    TEXT PRIMARY KEY
        REFERENCES sessions (id) ON DELETE CASCADE,
      context_used  INTEGER,
      context_size  INTEGER,
      cost_amount   REAL,
      cost_currency TEXT,
      turns_json    TEXT NOT NULL DEFAULT '[]',
      updated_at    TEXT NOT NULL
    );
  ''');
}

/// The auth method a person chose for an ACP installation, so the next start
/// authenticates with it: the method's id and name as the agent advertised
/// them, and when `authenticate` last succeeded with it — null for a login
/// the person completed in a terminal, which the protocol cannot confirm.
void _migrateToV70(Database db) {
  db.execute('''
    CREATE TABLE IF NOT EXISTS acp_auth_choices (
      installation_id  TEXT PRIMARY KEY
        REFERENCES agent_installations (id) ON DELETE CASCADE,
      method_id        TEXT NOT NULL,
      method_name      TEXT NOT NULL,
      authenticated_at TEXT,
      chosen_at        TEXT NOT NULL
    );
  ''');
}

/// Messages sent while a session's turn ran, kept here and delivered one per
/// turn in `seq` order. `request_id` is the sender's key, so a resend after a
/// restart finds its row rather than queueing it twice.
void _migrateToV71(Database db) {
  db.execute('''
    CREATE TABLE IF NOT EXISTS session_queued_messages (
      id                TEXT PRIMARY KEY,
      session_id        TEXT NOT NULL REFERENCES sessions (id) ON DELETE CASCADE,
      seq               INTEGER NOT NULL,
      text              TEXT NOT NULL,
      state             TEXT NOT NULL,
      origin            TEXT NOT NULL,
      origin_id         TEXT,
      created_at        TEXT NOT NULL,
      updated_at        TEXT NOT NULL,
      delivered_at      TEXT,
      request_id        TEXT,
      error             TEXT
    );
  ''');
  db.execute(
    'CREATE INDEX IF NOT EXISTS idx_session_queued_messages_session '
    'ON session_queued_messages (session_id, state, seq);',
  );
}

/// Each agent a session has run under, in switch order: the row keeps only
/// the active one, so the earlier ones' conversations are named here. A row
/// with none ran one agent; span 0 is written at the first switch.
void _migrateToV72(Database db) {
  db.execute('''
    CREATE TABLE IF NOT EXISTS session_agent_spans (
      session_id            TEXT NOT NULL
        REFERENCES sessions (id) ON DELETE CASCADE,
      seq                   INTEGER NOT NULL,
      agent_installation_id TEXT NOT NULL,
      external_session_id   TEXT,
      started_at            TEXT NOT NULL,
      first_message_ordinal INTEGER,
      carried_packet        TEXT,
      PRIMARY KEY (session_id, seq)
    );
  ''');
}

/// Async children whose turn results are pushed to their parent: which turn
/// is awaited, from when, so a restart can re-arm the push. A null
/// `turn_started_at` awaits nothing until the parent sends a follow-up.
void _migrateToV73(Database db) {
  db.execute('''
    CREATE TABLE IF NOT EXISTS session_delegations (
      child_session_id  TEXT PRIMARY KEY
        REFERENCES sessions (id) ON DELETE CASCADE,
      parent_session_id TEXT NOT NULL
        REFERENCES sessions (id) ON DELETE CASCADE,
      title             TEXT NOT NULL,
      agent             TEXT NOT NULL,
      model             TEXT,
      end_on_answer     INTEGER NOT NULL DEFAULT 0,
      delegated_at      TEXT NOT NULL,
      turn              INTEGER NOT NULL,
      turn_started_at   TEXT
    );
  ''');
  db.execute(
    'CREATE INDEX IF NOT EXISTS idx_session_delegations_parent '
    'ON session_delegations (parent_session_id);',
  );
}

/// The texts a session is started with — an opening message, a handoff
/// packet typed as one, a system prompt — held here instead of on disk, one
/// per kind, until the launch has used them. `route` is how it went.
void _migrateToV74(Database db) {
  db.execute('''
    CREATE TABLE IF NOT EXISTS session_handoffs (
      session_id  TEXT NOT NULL
        REFERENCES sessions (id) ON DELETE CASCADE,
      kind        TEXT NOT NULL,
      text        TEXT NOT NULL,
      route       TEXT NOT NULL,
      created_at  TEXT NOT NULL,
      consumed_at TEXT,
      PRIMARY KEY (session_id, kind)
    );
  ''');
}

/// Who cancelled a queued message — `device:<id>`, `app`, or the server for
/// an ended session — so a cancel nobody remembers can be traced.
void _migrateToV75(Database db) {
  db.execute(
    'ALTER TABLE session_queued_messages ADD COLUMN cancelled_by TEXT;',
  );
}

/// When a session's worktree was removed, apart from when the session was
/// archived (hidden): until now `archived_at` meant both, and only the
/// worktree action set it.
void _migrateToV76(Database db) {
  final columns = {
    for (final row in db.select('PRAGMA table_info(sessions);'))
      row['name'] as String,
  };
  if (columns.contains('worktree_removed_at')) return;
  db.execute('ALTER TABLE sessions ADD COLUMN worktree_removed_at TEXT;');
  db.execute(
    'UPDATE sessions SET worktree_removed_at = archived_at '
    'WHERE archived_at IS NOT NULL AND worktree_path IS NOT NULL;',
  );
}

/// A delegation's last report — its state, `report` (the child's own) or
/// `turn` (a turn's end), when, its text, and whether it reached the parent
/// — what the parent asked to be told (`report_mode`: none, final,
/// each_turn), and when it stopped being followed: closed rather than
/// deleted, so its parent still sees how it ended.
void _migrateToV77(Database db) {
  for (final column in [
    'report_state',
    'report_via',
    'reported_at',
    'closed_at',
    'report_mode',
    'report_text',
  ]) {
    db.execute('ALTER TABLE session_delegations ADD COLUMN $column TEXT;');
  }
  db.execute(
    'ALTER TABLE session_delegations ADD COLUMN report_delivered INTEGER;',
  );
}

/// A pairing's relay can move without a re-pair: the relay a move was asked
/// for, the one it moved from (still listened on, and still pushed through,
/// until the phone is heard on the new one), and whether it has been.
void _migrateToV78(Database db) {
  db.execute('ALTER TABLE paired_devices ADD COLUMN relay_move_to TEXT;');
  db.execute('ALTER TABLE paired_devices ADD COLUMN relay_moved_from TEXT;');
  db.execute(
    'ALTER TABLE paired_devices ADD COLUMN relay_move_settled INTEGER '
    'NOT NULL DEFAULT 1;',
  );
}

/// What an agent showed in its thread: a session's artifacts, and a snapshot
/// of each revision so a client reads what was shown even after the source
/// moves. The source path is the server's to read; a client never gets it.
void _migrateToV79(Database db) {
  db.execute('''
    CREATE TABLE IF NOT EXISTS session_artifacts (
      id                    TEXT PRIMARY KEY,
      session_id            TEXT NOT NULL,
      title                 TEXT NOT NULL,
      kind                  TEXT NOT NULL,
      mode                  TEXT NOT NULL,
      origin                TEXT NOT NULL,
      source_environment_id TEXT,
      source_path           TEXT,
      file_name             TEXT NOT NULL,
      revision              INTEGER NOT NULL,
      size                  INTEGER NOT NULL,
      mime_type             TEXT NOT NULL,
      network_allowed       INTEGER NOT NULL DEFAULT 0,
      source_state          TEXT NOT NULL DEFAULT 'present',
      source_problem        TEXT,
      created_at            TEXT NOT NULL,
      updated_at            TEXT NOT NULL
    );
  ''');
  db.execute(
    'CREATE INDEX IF NOT EXISTS idx_session_artifacts_session '
    'ON session_artifacts (session_id, created_at);',
  );
  db.execute('''
    CREATE TABLE IF NOT EXISTS session_artifact_revisions (
      artifact_id TEXT NOT NULL
        REFERENCES session_artifacts (id) ON DELETE CASCADE,
      revision    INTEGER NOT NULL,
      size        INTEGER NOT NULL,
      digest      TEXT NOT NULL,
      path        TEXT NOT NULL,
      captured_at TEXT NOT NULL,
      PRIMARY KEY (artifact_id, revision)
    );
  ''');
}

/// `activity_log`, the timeline's own history: append-only, with no foreign
/// keys, and each entry carrying its own copy of what is drawn so deleting a
/// session, checkout or project never blanks it. The triggers log a session
/// row's own facts from every writer; `INSERT OR IGNORE` with non-null
/// inputs cannot fail the write it rides on.
void _migrateToV80(Database db) {
  db.execute('''
    CREATE TABLE IF NOT EXISTS activity_log (
      id                INTEGER PRIMARY KEY AUTOINCREMENT,
      at                TEXT NOT NULL,
      kind              TEXT NOT NULL,
      session_id        TEXT NOT NULL,
      title             TEXT,
      project_id        TEXT,
      project_name      TEXT,
      checkout_path     TEXT,
      agent             TEXT,
      machine           TEXT,
      parent_session_id TEXT,
      detail            TEXT,
      source            TEXT NOT NULL,
      source_id         TEXT,
      backfilled        INTEGER NOT NULL DEFAULT 0,
      approximate       INTEGER NOT NULL DEFAULT 0,
      recorded_at       TEXT NOT NULL,
      UNIQUE (source, source_id)
    );
  ''');
  db.execute(
    'CREATE INDEX IF NOT EXISTS idx_activity_log_at ON activity_log (at);',
  );
  db.execute(
    'CREATE INDEX IF NOT EXISTS idx_activity_log_project_at '
    'ON activity_log (project_id, at);',
  );
  db.execute(
    'CREATE INDEX IF NOT EXISTS idx_activity_log_session_at '
    'ON activity_log (session_id, at);',
  );

  const now = "strftime('%Y-%m-%dT%H:%M:%fZ', 'now')";
  // The row's own copy, read live and, for a row whose repository or
  // installation is already gone (a cascade), from what was logged last.
  String copy(String row) {
    String last(String column) =>
        '(SELECT $column FROM activity_log WHERE session_id = $row.id '
        'AND $column IS NOT NULL ORDER BY id DESC LIMIT 1)';
    return [
      'COALESCE((SELECT project_id FROM repositories '
          'WHERE id = $row.repository_id), ${last('project_id')})',
      'COALESCE((SELECT p.name FROM repositories r JOIN projects p '
          'ON p.id = r.project_id WHERE r.id = $row.repository_id), '
          '${last('project_name')})',
      'COALESCE($row.worktree_path, $row.working_directory_path, '
          '(SELECT path FROM repositories WHERE id = $row.repository_id), '
          '${last('checkout_path')})',
      'COALESCE((SELECT agent_kind FROM agent_installations '
          'WHERE id = $row.agent_installation_id), ${last('agent')})',
      'COALESCE((SELECT e.name FROM agent_installations a '
          'JOIN execution_environments e ON e.id = a.environment_id '
          'WHERE a.id = $row.agent_installation_id), ${last('machine')})',
    ].join(',\n        ');
  }

  String append(
    String row, {
    required String kind,
    required String at,
    required String title,
    String detail = 'NULL',
    String parent = 'NULL',
    required String source,
    String sourceId = 'NULL',
  }) =>
      '''
      INSERT OR IGNORE INTO activity_log (at, kind, session_id, title,
        project_id, project_name, checkout_path, agent, machine,
        parent_session_id, detail, source, source_id, recorded_at)
      VALUES ($at, '$kind', $row.id, $title,
        ${copy(row)},
        $parent, $detail, '$source', $sourceId, $now);''';

  db.execute('''
    CREATE TRIGGER IF NOT EXISTS activity_session_started
    AFTER INSERT ON sessions
    BEGIN
      ${append('NEW', kind: 'sessionStarted', at: 'NEW.created_at', title: 'NEW.title', parent: 'NEW.parent_session_id', source: 'session', sourceId: "NEW.id || ':started'")}
    END;
  ''');
  db.execute('''
    CREATE TRIGGER IF NOT EXISTS activity_session_linked
    AFTER INSERT ON sessions
    WHEN NEW.parent_session_id IS NOT NULL
    BEGIN
      ${append('NEW', kind: 'linked', at: 'NEW.created_at', title: 'NEW.title', parent: 'NEW.parent_session_id', detail: 'NEW.parent_link_kind', source: 'lineage', sourceId: 'NEW.id')}
    END;
  ''');
  db.execute('''
    CREATE TRIGGER IF NOT EXISTS activity_session_renamed
    AFTER UPDATE OF title ON sessions
    WHEN NEW.title IS NOT OLD.title
    BEGIN
      ${append('NEW', kind: 'renamed', at: now, title: 'NEW.title', detail: 'NEW.title', source: 'session')}
    END;
  ''');
  db.execute('''
    CREATE TRIGGER IF NOT EXISTS activity_session_archived
    AFTER UPDATE OF archived_at ON sessions
    WHEN NEW.archived_at IS NOT NULL AND OLD.archived_at IS NULL
    BEGIN
      ${append('NEW', kind: 'archived', at: 'NEW.archived_at', title: 'NEW.title', source: 'session', sourceId: "NEW.id || ':archived:' || NEW.archived_at")}
    END;
  ''');
  db.execute('''
    CREATE TRIGGER IF NOT EXISTS activity_session_unarchived
    AFTER UPDATE OF archived_at ON sessions
    WHEN NEW.archived_at IS NULL AND OLD.archived_at IS NOT NULL
    BEGIN
      ${append('NEW', kind: 'unarchived', at: now, title: 'NEW.title', source: 'session')}
    END;
  ''');
  db.execute('''
    CREATE TRIGGER IF NOT EXISTS activity_session_deleted
    AFTER DELETE ON sessions
    BEGIN
      ${append('OLD', kind: 'deleted', at: now, title: 'OLD.title', parent: 'OLD.parent_session_id', source: 'session')}
    END;
  ''');
}

/// Webhooks: an automation started by a call to its URL — its hook id, the
/// signature rule, the model, the worktree choice and the hourly limit — and
/// the log of every call, kept as a hash of the body, never the body. The
/// signing secrets are not here; they live in the server's vault.
void _migrateToV81(Database db) {
  db.execute('ALTER TABLE automations ADD COLUMN webhook_id TEXT;');
  db.execute('ALTER TABLE automations ADD COLUMN webhook_signature INTEGER;');
  db.execute('ALTER TABLE automations ADD COLUMN webhook_model TEXT;');
  db.execute('ALTER TABLE automations ADD COLUMN webhook_worktree INTEGER;');
  db.execute('ALTER TABLE automations ADD COLUMN webhook_per_hour INTEGER;');
  db.execute(
    'CREATE UNIQUE INDEX IF NOT EXISTS idx_automations_webhook '
    'ON automations (webhook_id) WHERE webhook_id IS NOT NULL;',
  );
  db.execute('''
    CREATE TABLE IF NOT EXISTS webhook_calls (
      id            TEXT PRIMARY KEY,
      automation_id TEXT REFERENCES automations (id) ON DELETE CASCADE,
      hook_id       TEXT NOT NULL,
      received_at   TEXT NOT NULL,
      ip            TEXT NOT NULL,
      status        INTEGER NOT NULL,
      outcome       TEXT NOT NULL,
      reason        TEXT,
      delivery_id   TEXT,
      body_sha256   TEXT NOT NULL,
      body_bytes    INTEGER NOT NULL,
      session_id    TEXT,
      run_id        TEXT
    );
  ''');
  db.execute(
    'CREATE INDEX IF NOT EXISTS idx_webhook_calls_hook '
    'ON webhook_calls (hook_id, received_at);',
  );
  db.execute(
    'CREATE INDEX IF NOT EXISTS idx_webhook_calls_automation '
    'ON webhook_calls (automation_id, received_at);',
  );
}

/// The rung a person placed each of a person-added ACP agent's modes on,
/// as JSON mode → rung name; empty for a row whose modes nobody placed.
void _migrateToV82(Database db) {
  final columns = db
      .select('PRAGMA table_info(acp_agents);')
      .map((row) => row['name'] as String);
  if (columns.contains('mode_rungs')) return;
  db.execute(
    "ALTER TABLE acp_agents ADD COLUMN mode_rungs TEXT NOT NULL DEFAULT '{}';",
  );
}

/// The model the agent said it was running as it wrote each chat row; null
/// for a row written before, or while it had said none.
void _migrateToV83(Database db) {
  final columns = db
      .select('PRAGMA table_info(session_messages);')
      .map((row) => row['name'] as String);
  if (columns.contains('model')) return;
  db.execute('ALTER TABLE session_messages ADD COLUMN model TEXT;');
}

/// Every automation picks a model and a worktree, as only webhooks could, and
/// keeps the steps after its agent (null: its checks, as before); a run keeps
/// what started it and what its steps did. A webhook's model is copied over.
void _migrateToV84(Database db) {
  Set<String> columnsOf(String table) => db
      .select('PRAGMA table_info($table);')
      .map((row) => row['name'] as String)
      .toSet();
  if (!columnsOf('automations').contains('model_id')) {
    db.execute('ALTER TABLE automations ADD COLUMN model_id TEXT;');
    db.execute(
      'ALTER TABLE automations ADD COLUMN run_in_worktree INTEGER NOT NULL '
      'DEFAULT 0;',
    );
    db.execute('ALTER TABLE automations ADD COLUMN steps TEXT;');
    db.execute(
      'UPDATE automations SET model_id = webhook_model, '
      'run_in_worktree = COALESCE(webhook_worktree, 0) '
      'WHERE webhook_id IS NOT NULL;',
    );
  }
  if (!columnsOf('automation_runs').contains('started_by')) {
    db.execute('ALTER TABLE automation_runs ADD COLUMN started_by TEXT;');
    db.execute('ALTER TABLE automation_runs ADD COLUMN step_results TEXT;');
  }
}

/// The prompt a webhook's run was started with — its template filled with
/// the call's fields — so Deliveries can show what the agent was told. On the
/// run, not the call log, which keeps no part of a body.
void _migrateToV85(Database db) {
  final columns = db
      .select('PRAGMA table_info(automation_runs);')
      .map((row) => row['name'] as String);
  if (columns.contains('prompt')) return;
  db.execute('ALTER TABLE automation_runs ADD COLUMN prompt TEXT;');
}
