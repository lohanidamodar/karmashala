import 'dart:convert';

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
/// * **v17** — Loop 60: when a session's worktree was archived away. Nothing
///   else about the session is removed with it.
/// * **v18** — Loop 70: companion devices paired with this host
///   (`paired_devices`), for the mobile-companion remote access feature.
/// * **v19** — Loop 80: which relay each paired device was paired through
///   (`paired_devices.relay_url`), so the host can serve local-relay and
///   hosted-relay devices side by side.
/// * **v20** — G3 step 1: who produced a verdict — the session behind a
///   `verification_runs` row and behind a `fanout_candidates` verdict — so a
///   self-graded pass can be told from an independently checked one.
/// * **v21** — Notes: an idea the user chose to keep out of a conversation
///   instead of acting on it, with the session and message it was taken from.
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
};

void _migrateToV21(Database db) {
  // Notes: a thought the user chose to keep instead of acting on it.
  //
  // `body` is **quoted text, never a summary**. A note is made by tapping the
  // affordance under a message, and what it stores is that message's own words;
  // the same argument `HandoffPacket` makes at length applies here for the same
  // reason — a paraphrase's errors are invisible to the reader who most needs
  // them, and the reader here is the agent the note is later sent back to.
  // Editing is the user's, deliberately, and `updated_at` says when they did.
  //
  // `source_session_id` is **not** a foreign key, like
  // `verification_runs.session_id` and for the same reason: a note is a
  // deferred instruction that has to outlive the conversation it came from.
  // Deleting a finished session must not delete the idea it produced, and a
  // note whose session is gone still says everything it said before — its own
  // text — with an origin that no longer resolves.
  //
  // `source_message_ordinal` is the message's index in the transcript that was
  // on screen, which is stable because transcripts are append-only. It is a
  // pointer back to the moment, not an identity: the id it would want does not
  // exist for a PTY-hosted session, whose transcript is the agent's own file
  // and has no row of ours to name.
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
  // Who produced the verdict (G3 step 1).
  //
  // `verification_runs.session_id` already says whose *work* a run is about.
  // Nothing said who graded it, and in practice the agent calling
  // `verification_start`/`verification_finish` is the agent that wrote the
  // code — a self-graded exam with a very good transcript. Recording the
  // producer is what lets a surface derive `producer == subject` and say so.
  //
  // Two columns rather than one shared table: fan-out stores a *copy* of the
  // verdict precisely so an old comparison still reads after the run behind it
  // is pruned, and a copied verdict that loses its attribution on the way is
  // the thing this migration exists to prevent.
  db.execute(
    'ALTER TABLE verification_runs ADD COLUMN produced_by_session_id TEXT;',
  );
  db.execute(
    'ALTER TABLE fanout_candidates '
    'ADD COLUMN verdict_producer_session_id TEXT;',
  );

  // Deliberately **not** backfilled, unlike v16's `parent_link_kind`.
  //
  // There the backfill was a fact: one writer, one possible value. Here there
  // is no fact to recover. Copying `session_id` across would assert that every
  // historical verdict was self-reported, and leaving it to be read as
  // independent would assert the opposite; both invent a producer nobody
  // recorded. Null means "not recorded", and the domain keeps that as its own
  // third state rather than collapsing it into either neighbour.
}

void _migrateToV19(Database db) {
  // Which relay this device's frames travel through (Loop 80): the literal
  // hosted relay URL, or the sentinel `'local'` for the relay embedded in this
  // app. The sentinel, not the LAN URL of the moment: the machine's IP and the
  // relay's port both move, while "my own relay" stays the same fact — the
  // host resolves it to the live embedded relay at serve time.
  db.execute('ALTER TABLE paired_devices ADD COLUMN relay_url TEXT;');

  // Backfill from the relay the app was configured to use when the column
  // arrived: every pre-v19 pairing went through that one relay, because
  // serving two at once is what this migration exists to enable. Absent or
  // unreadable settings mean the defaults: hosted mode, PopupBits relay
  // (the literal below is `kDefaultRelayUrl`, unimportable from core).
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
  // Phones paired with this desktop host (Loop 70, mobile companion).
  //
  // `device_key` is the 32-byte symmetric key from the pairing key schedule,
  // stored as lowercase hex. Revoking a device **empties** the key rather than
  // only flagging the row — a revoked row must be unable to seal or open
  // another frame, and a key that is gone cannot leak later. The row itself
  // stays so the settings list can show what was revoked and when.
  //
  // `generation` is the rendezvous generation counter from the Loop-64 key
  // schedule: the one number persisted per device. Both the rotating
  // rendezvous id and the per-direction sealing keys derive from it, so there
  // are deliberately no sequence-number columns here — sequences live and die
  // with a generation.
  //
  // `push_token`/`push_platform` are what `notifications.register` persists;
  // actual push delivery is a later loop.
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
  // Persistent fan-out comparisons (Loop 52).
  //
  // A fan-out used to live entirely in one dialog: closing it lost the prompt,
  // which agents ran it and which one won. These two tables are the record, and
  // they are written to be readable *after* the thing they describe is gone —
  // the winner merged, the losers' worktrees removed.
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

  // `session_id` is deliberately **not** a foreign key. A candidate is a
  // historical fact about a comparison; deleting the session must orphan the
  // link, not erase the row that says this agent ran and what it produced. The
  // same reasoning as `sessions.parent_session_id` in v10.
  //
  // `agent_id` is copied rather than joined through `installation_id` for the
  // same reason: an installation can be removed when an agent is uninstalled,
  // and the record must still name who wrote the diff.
  //
  // `worktree_removed` plus the `files_changed`/`insertions`/`deletions`/
  // `commits` columns are what makes a discarded loser still legible: the
  // directory is gone, the last thing it showed is not.
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
  // The workspace-loss guard (Loop 53).
  //
  // `saveWorkspace` is a destructive full replace, so the one save that can
  // never be taken back is the one that writes nothing over something. Loop 48
  // watched that happen once in ten real runs and could not find the trigger.
  //
  // These two tables are a shadow copy taken *inside* that save's transaction,
  // just before the delete: whatever the store held is still on disk afterwards.
  // Deliberately plain mirrors — no foreign key, no cascade, no index. A backup
  // that participates in the live schema's referential integrity is a backup
  // that the next cascade can take with it, which is precisely the failure it
  // exists to survive.
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
  // Session checkpoints (Loop 53): what the working tree looked like when a
  // turn ended, so it can be put back.
  //
  // The *content* is not here. A checkpoint is a git tree and the commit that
  // anchors it, both in the repository's own object store, reachable from
  // `refs/chitragupta/checkpoints/<session>` so `git gc` keeps them. This table
  // is the index over them: which session, in which order, against which repo,
  // and what a reader can be shown without shelling out to git.
  //
  // Deliberately no foreign key to `sessions`. A checkpoint is a recovery
  // record for work in a *repository*; losing the way back to that work because
  // the session row it was captured under went away is the wrong failure.
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
  // Verification runs (Loop 51): a recorded attempt to prove a change works,
  // against a page or a device, with a verdict an agent can hand to a human.
  //
  // `session_id` is deliberately **not** a foreign key. Evidence has to outlive
  // the session that produced it — archiving or deleting a session must not
  // delete the proof that its change worked — and `sessions` belongs to another
  // part of the app, so this stays a plain reference resolved by lookup.
  //
  // `artifact_directory` is where the run's files are. **No image or log bytes
  // are stored in SQLite**; every artifact row points at a file under that
  // directory, which is what keeps the database small and the exported report's
  // relative links working when the folder is copied somewhere else.
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

  // The actions taken, in order. `ordinal` is the run-local sequence number and
  // the step's identity, so an artifact can point back at the action that
  // produced it without a second surrogate key.
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
  // Nullable, and null is a real answer for a *pre-v16* row: "we did not record
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

void _migrateToV17(Database db) {
  // When this session's worktree was archived away (Loop 60).
  //
  // Archiving removes **one directory** and nothing else. The transcript, the
  // review notes, the checkpoints and the session row itself all stay exactly
  // where they were, which is the whole point: a user who cleans up a finished
  // task must not lose the record of how it was done. This column is the only
  // thing that changes in the database, and it is a timestamp rather than a
  // flag so the row also says *when*.
  //
  // Deliberately not a `SessionStatus` value. Status is what the agent process
  // is doing — running, failed, cancelled — and an archived session keeps
  // whichever of those it ended on; overloading the same column would destroy
  // the record of how the work finished in order to record that its directory
  // was tidied.
  db.execute('ALTER TABLE sessions ADD COLUMN archived_at TEXT;');
}
