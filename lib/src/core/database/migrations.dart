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
/// * **v7** — Loop 29: the terminal layout (tabs, their pane split trees and
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
/// * **v22** — T10 follow-up: the directory a session's agent actually runs
///   in, which an adopted session knew and threw away.
/// * **v23** — G1: a session's append-only decision record — the constraints,
///   rejected approaches, approvals, verdicts and marked checkpoints that a
///   handoff packet was carrying a transcript instead of.
/// * **v24** — Index the pane hosting a session so switching terminal tabs does
///   not scan every historical session row.
/// * **v25** — G2: what a session left behind when it ended, so a crash or an
///   unfinished check is still waiting in the morning rather than scrolling
///   past at 14:32.
/// * **v26** — whether each stored terminal pane had a process behind it when
///   it was written, so a restart can put back what was running.
/// * **v28** — the model picker: a session carries its own model id, the way
///   it has carried its own permission mode since v11.
/// * **v29** — saved Explorer sections: live, rule-based groups over state the
///   app already polls, plus the manual groups and the built-in Pinned one.
/// * **v30** — review comments as durable, addressable threads, anchored to a
///   file's *content* rather than to a row of whatever diff was on screen.
/// * **v31** — workspaces: the level *above* project, so ~31 projects across
///   four unrelated contexts can be narrowed to the one being worked in.
/// * **v32** — what a context is *for*, in the user's own words: the one thing
///   a bare name in a picker cannot carry.
/// * **v33** — saved command snippets: the commands the user keeps, each
///   optionally tagged with the shell it is written for, so a WSL one-liner is
///   never offered in a PowerShell pane.
/// * **v34** — todos, and the project a todo or a note is filed under. Both
///   nullable: filed under nothing is an ordinary todo, not an unfinished one.
/// * **v35** — a session's permission mode in **its agent's own vocabulary**:
///   `ask`/`acceptEdits`/`bypass` become a canonical selection over that
///   agent's declared axes, because a shared three-value enum cannot say that
///   Claude Code has six modes or that Codex's sandbox and approval policy are
///   two separate dimensions.
/// * **v39** — whether a human chose an installation's executable path, so the
///   startup path repair can fix a broken one whoever set it and still never
///   overwrite a working hand-set one.
/// * **v40** — *when* an installation's version was last read from the binary,
///   so a recorded version is a dated reading rather than a bare number that
///   cannot be told apart from a current one.
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
};

/// Was this pane running when its row was written?
///
/// The owner: *"if there were active panes on last close start all those panes
/// on active tab"*. The store could not answer that. Every pane came back
/// [PaneLiveness.restored] — replayed history with a Start button — because a
/// row recorded a pane's *shape* (profile, directory, scrollback, launch) and
/// never whether anything was running in it, so "put back what was running" and
/// "re-run week-old history" were the same statement.
///
/// One column separates them, and it is the pane's, not the tab's: a split can
/// hold a live shell beside a pane whose process exited an hour ago, and only
/// the first should come back.
///
/// `DEFAULT 0` is the honest reading of every row written before this: those
/// rows never claimed anything was running, and inventing a claim for them
/// would spawn a shell per pane on the first launch after an upgrade.
/// `terminal_panes_backup` gets it too — a backup with a column missing is a
/// backup that cannot be restored by the same code that reads the live table.
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

/// What a session left behind when it ended.
///
/// **Raises nothing for what is already there, and has to say so out loud.**
/// The observer's durable signal is the session's own row, which goes on saying
/// `failed` forever — so without the second statement below, the first sweep
/// after an upgrade would present a workspace's whole history as things that
/// just happened. That is a wall of notices about work the user finished with
/// weeks ago, and the fastest possible way to teach somebody to ignore the
/// list.
///
/// The baseline is written as **already-closed** rows: never raised, never
/// shown, and marked [FollowUpReason.predatesTheFeature] so anyone reading the
/// table can see exactly what they are. A closed row with no resolution is
/// "not recorded", which is what this is — nobody decided anything about these,
/// they simply predate the question. Follow-ups begin from the first ending
/// this build actually observes.
///
/// No foreign key on `session_id`, matching `verification_runs`: a notice about
/// a session must not be able to take that session's row with it, and a session
/// deleted out from under a follow-up is something the reader resolves rather
/// than a constraint violation.
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
  // At most one *open* follow-up per session, enforced here rather than in the
  // DAO because the writer is a poll: it re-reads the same ended rows on every
  // session-revision bump, and without this the list would grow by an identical
  // row per bump. Resolved rows are exempt — the same session ending twice over
  // a week is two things to come back to, and only the later one is still open.
  db.execute(
    'CREATE UNIQUE INDEX IF NOT EXISTS idx_follow_ups_open '
    'ON session_follow_ups (session_id) WHERE resolved_at IS NULL;',
  );

  // The status names are the ending names — `endingOfStatus` maps them one to
  // one — so the mark this writes is exactly the one the service looks for.
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
  // The decision record (G1): what a session decided, as opposed to what it
  // said.
  //
  // `HandoffPacket` carries a quoted tail of the conversation and a count of
  // the turns it dropped, and the dropped ones are disproportionately
  // load-bearing — a decision is made once and thereafter assumed, so "the
  // isolate pool deadlocked on Windows" is forty turns back inside
  // `omittedTurns`. This table is where such a thing is written down *once*,
  // at the moment it is decided, so a later reader does not have to find it in
  // a transcript that no longer includes it.
  //
  // **Append-only, and only by explicit acts.** Nothing here is derived from
  // prose. A row exists because somebody answered an approval prompt, finished
  // a verification run, labelled a checkpoint, or called `decision_record` —
  // and the DAO offers no update and no delete, so the record of what was
  // decided cannot be quietly revised into what is convenient now. That is the
  // same argument `handoff_packet.dart` makes at length about the recap: there
  // is no model in this path, and a paraphrase's errors are invisible to the
  // reader who most needs them.
  //
  // `sequence` is 1-based within a session and unique, which is what makes the
  // chain a chain: two writers cannot both claim position 4, and a gap is
  // visible rather than silently closed.
  //
  // `summary` is the decision **in the words of whoever made it** — an agent's
  // own sentence, or the agent's own description of what a keystroke does. Not
  // a gist of it.
  //
  // `origin_kind`/`origin_id` are the pointer back to the act. The id is
  // nullable because some acts leave no row of their own: an approval prompt
  // lives on the agent's screen and is gone when it is answered, so the honest
  // pointer names the act without pretending there is a record to open.
  // Deliberately **not** a foreign key, like `notes.source_session_id` and
  // `verification_runs.session_id`: a decision has to outlive the run or
  // checkpoint that produced it, and a row whose origin has been pruned still
  // says everything it said before.
  //
  // `decided_by` is words, not an id — "the user", or the agent's display
  // name at the time. The packet attributes every line it renders, and the
  // reader needs a name they recognise rather than a key to resolve;
  // `recorded_by_session_id` is beside it for the case where the resolution
  // still matters.
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

  // Deliberately **not** backfilled, for the same reason v20 was not.
  //
  // There is nothing to recover. Every existing session has checkpoints saying
  // a turn happened and possibly verification runs saying a check was made,
  // and neither is a decision: a turn checkpoint records that time passed, and
  // a run this session may well have graded itself records a claim. Turning
  // either into a decision row would put a sentence in the user's mouth for
  // every session that already exists. An empty record reads as "not
  // recorded", which is exactly what it is.
}

void _migrateToV22(Database db) {
  // Where a session's agent is actually running (T10 follow-up).
  //
  // Two columns rather than one, matching `worktree_*`: a path divorced from
  // the environment that owns it is not a location (constraints 7 & 8), so a
  // WSL session records a WSL path against its WSL environment and nothing
  // translates it implicitly on the way back out.
  //
  // Deliberately **not** `worktree`, which the schema already has and which
  // means something narrower and more dangerous: `SessionLauncher` reads a
  // non-null `worktree` as "this session runs in a git worktree" and sets
  // `use_worktree` from it, and `SessionArchiveService` hands it to
  // `WorktreeService.remove` — `git worktree remove`, which deletes the
  // directory. An ordinary cwd stored there would eventually offer to delete
  // the user's own checkout.
  //
  // Nullable and undefaulted, like `permission_mode` in v11 and for the same
  // reason: a row written before this column existed has an **unknown**
  // directory, not the repository root. Backfilling the root would assert that
  // every one of those sessions started there, and the sessions this column
  // exists for — the ones adopted out of a terminal pane — are exactly the ones
  // most likely to have started somewhere else. Readers fall back to the
  // repository root themselves, which is a fallback rather than a claim.
  db.execute(
    'ALTER TABLE sessions ADD COLUMN working_directory_environment_id TEXT;',
  );
  db.execute('ALTER TABLE sessions ADD COLUMN working_directory_path TEXT;');
}

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
  // The terminal layout (Loop 29): which tabs were open, how each tab's panes
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
  // The layout-loss guard (Loop 53).
  //
  // `saveLayout` is a destructive full replace, so the one save that can
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
  // `refs/karmashala/checkpoints/<session>` so `git gc` keeps them. This table
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

/// A session's title is the user's only once they have typed one.
///
/// The rename sync could not tell a CLI-set title from a user-set one after a
/// restart: it remembered what it had written **in memory only**, so on the next
/// start every row's title looked like the user's and no further `/rename` was
/// ever copied in. The owner hit exactly that — `/rename` landed in the store
/// (1,034 title records in that one file, the last of them the new name) and
/// the sidebar went on showing the old one.
///
/// Recording the one event that makes a title the user's is what survives a
/// restart. `DEFAULT 0` deliberately hands existing rows back to their CLI: the
/// column cannot say what happened before it existed, and the failure it fixes
/// is the one the owner is actually having. A row the user renames in the app
/// is marked from that moment and never taken again.
void _migrateToV27(Database db) {
  db.execute(
    'ALTER TABLE sessions ADD COLUMN title_by_user INTEGER NOT NULL DEFAULT 0;',
  );
}

/// A session carries its own model, so the model chip has somewhere to write
/// and the launcher has one place to read.
///
/// Nullable and undefaulted, exactly like `permission_mode` in v11 and for the
/// same reason: null is a **value** here, not a missing one. It means "nobody
/// chose a model for this session", which is what every row written before this
/// column is truthfully in — and the state a user must be able to go back to
/// once they have picked. Defaulting existing rows to any model id would be a
/// claim about what they ran under that nothing in the database can support.
void _migrateToV28(Database db) {
  db.execute('ALTER TABLE sessions ADD COLUMN model_id TEXT;');
}

/// Review comments as **durable, addressable threads**, anchored to content.
///
/// ## What this replaces, and why it was a correctness bug
///
/// `DiffAnnotationsController` held review comments in a `Notifier` — no rows,
/// no replies, no status — and keyed each one by `(repositoryId, path,
/// diffIndex)`, where `diffIndex` was the **row number of a line inside the
/// unified diff currently on screen**. That number belongs to a rendering, not
/// to the code. It moves when a hunk grows, when another hunk appears above it,
/// when git coalesces two hunks that drift within three context lines of each
/// other, and when the file is staged. So the instant the agent edited the file
/// a comment was attached to — the entire point of writing the comment — the
/// comment silently began pointing at different lines, and said nothing about
/// it. The controller also cleared every annotation on send, which is the only
/// reason the mis-anchoring was survivable: comments never lived long enough
/// for anybody to notice they had drifted.
///
/// ## Why the anchor is a blob sha
///
/// `blob_sha` is `git hash-object` of the file's bytes at the moment the thread
/// was opened, and `start_line`/`end_line` are line numbers **in that
/// content**. Together they are a claim that can be *checked*: ask git for the
/// file's current hash, and either it is the same bytes — in which case the
/// range still means what it meant — or it is not, and the thread is
/// **detached** and is rendered saying so. Nothing re-anchors by matching the
/// excerpt against the new file, and that is the deliberate part. Fuzzy
/// re-anchoring is right most of the time, and a pointer that is right most of
/// the time is the same failure `diff_index` had: the reader cannot tell which
/// case they are holding, so they cannot trust any of them.
///
/// `start_line` is nullable because a **file-level** comment is a real review
/// comment ("this file should not exist") and not a degraded line comment. Null
/// there means "about the file", never "about line 0".
///
/// `anchor_excerpt` is the text the author was looking at, kept verbatim. It is
/// evidence for the human reading a detached thread, and it is never fed back
/// into locating the line.
///
/// ## Why comments are their own table
///
/// Because a thread accepts replies, including from an agent, and the opening
/// comment and a reply are the same thing said at different times — a `body`
/// column plus a `replies` blob would have made the first message special for
/// no reason anybody could later explain. `sequence` is 1-based and unique per
/// thread, the same chain discipline `session_decisions` uses, so two writers
/// cannot both claim position 4 and a reply cannot silently overwrite one.
///
/// Comments cascade from their thread: a comment with no thread has no anchor
/// and no subject, so it is not a record of anything. The thread cascades from
/// its repository, matching `notes`, for the same reason — the path in the
/// anchor is only resolvable inside a checkout this app still knows about.
///
/// Nothing is back-filled, because there is nothing to back-fill: the
/// annotations this replaces were never written to disk in any version of the
/// schema.
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
  // The one query the diff view runs per render: every thread on a repository,
  // grouped in memory by path. Indexed on the pair rather than on
  // `repository_id` alone so a single file's threads are also a range scan for
  // the MCP tools, which ask by path.
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

/// Saved Explorer sections: live groups over facts the app already has.
///
/// **Two tables, and the split is the design.** `explorer_sections` holds what
/// the user *said* — a name, a rule, where it sits — and is the only thing
/// persisted. What is *in* a section is never written down for a rule section,
/// because it is not a fact about the section: it is what the rule says right
/// now about state that changes every couple of minutes. Storing membership
/// would create a second answer that goes stale the moment a check turns red,
/// and the app would then have to decide which of the two to draw.
/// `explorer_section_members` exists only for the groups the user fills by
/// hand, where the list *is* the definition.
///
/// **Position is priority.** A session can satisfy three rules at once, and the
/// order of these rows is what decides where it is drawn — see
/// `assignSections`. That is why `position` is stored rather than derived from
/// a name or an insertion order: the user rearranges it, and rearranging it has
/// to mean something.
///
/// **Pinned is a row like the others, and is not.** It is seeded here with
/// `kind = 'pinned'` at position 0 so that everything downstream — ordering,
/// priority, the collapse toggle — has one code path instead of a special case
/// bolted beside it. What makes it built-in is that the UI refuses to rename,
/// re-rule, reorder or delete it, and that its membership is read from
/// `Settings.pinnedSessionIds` rather than from the members table. There is one
/// pin store in this app and it is the one the pin glyph on every row already
/// writes; a second would let a row show a filled pin while sitting outside the
/// Pinned section.
///
/// **No foreign key from a member to a session**, matching `verification_runs`
/// and `session_follow_ups`: a group is the user's list, and a session deleted
/// out from under it is a stale entry the reader drops, not a constraint
/// violation that fails the delete.
///
/// **The three seeded rule sections are a suggestion, not a claim.** They are
/// written once, here, and never re-seeded: a user who deletes "Checks failing"
/// has deleted it. They are written **collapsed**, which is not cosmetic — a
/// collapsed section matches nothing and builds no rows, so a workspace that
/// upgrades into this feature and never opens one pays exactly nothing for it.
/// The order they are seeded in is the severity order a fixed priority table
/// would have imposed (a red build, then an agent holding the user up, then
/// work that died), which is the point: the default behaviour is the sensible
/// one, and it is expressed as something the user can drag.
///
/// `release/*` and "PR open" are deliberately **not** seeded. The first is
/// specific to a workspace's own branch naming and guessing at it would be
/// noise; the second is broad enough that on a busy repository it is the whole
/// session list wearing a hat. Both are one dialog away.
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

  // `INSERT OR IGNORE` rather than a plain insert: the step is required to be
  // idempotent at the DDL level (see [MigrationStep]), and a seed that threw on
  // a re-run would be the one statement in this file that could not be applied
  // twice.
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

/// Workspaces: the grouping level *above* project.
///
/// **Additive and only additive.** The owner's live database holds ~31
/// projects and thousands of sessions, and this upgrade must be something it
/// can survive while the app is open on it: one new table, one nullable
/// column, no data movement and no `DELETE`, `DROP` or `UPDATE` of any
/// existing row. Every project on the far side of it is *unassigned*, which is
/// the correct answer — nothing here knows which context a project belongs to,
/// and guessing would file 31 things wrong at once.
///
/// **Unassigned is first-class, not a hole.** `workspace_id` is nullable and
/// stays nullable: a project with no workspace is an ordinary project that
/// shows under "All", never a row waiting to be fixed. That is also why the
/// foreign key is `ON DELETE SET NULL` rather than `CASCADE` — deleting a
/// workspace must lose the *grouping*, never the projects grouped by it. A
/// cascade here would turn "I do not want these four buckets any more" into
/// "delete 31 projects and their sessions", which is the single worst thing
/// this table could do.
///
/// **Names are unique, case-insensitively.** The whole feature is a picker,
/// and two rows both called "Personal" in a picker are two answers to a
/// question with one answer. Enforced in the schema rather than in the
/// controller because the controller is not the only writer — the suggestion
/// path writes here too.
///
/// **No index on `projects.workspace_id`.** The filter never queries by it:
/// the project list is already read whole (~31 rows, `ProjectDao.getAll`) and
/// narrowed in memory, so an index would be paid for on every write and read
/// by nothing. The one scan it *would* serve is the `SET NULL` fan-out when a
/// workspace is deleted, over those same 31 rows, once.
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

/// What a context is *for*, in the user's own words.
///
/// A name is enough to pick a context and not enough to remember one: "Appwrite"
/// is either the projects that run against the owner's own Appwrite or the ones
/// that use the SDK, and only the person who made it knows which. One nullable
/// column carries that sentence to every picker of contexts — the scope bar, the
/// project's own right-click menu, the palette.
///
/// **Nullable, and staying nullable.** Nobody is going to write a sentence
/// before they are allowed to group two projects, so a context without a
/// description is complete rather than half-filled-in, and every surface falls
/// back to something it can say for free (how many projects are in it).
///
/// **Additive, like v31.** No table is rewritten and no row is touched: the
/// live database upgrades with every context intact and every description
/// empty, which is exactly what it knows.
void _migrateToV32(Database db) {
  db.execute('ALTER TABLE workspaces ADD COLUMN description TEXT;');
}

/// Saved command snippets: the commands the user keeps instead of retyping.
///
/// **One table, no foreign keys, nothing seeded.** A snippet belongs to the
/// person, not to a project, a repository or a session — the whole point is
/// that the same `flutter test --exclude-tags=live-ssh` is reachable from every
/// pane in the app — so there is nothing here to reference and nothing to
/// cascade. And nothing is seeded: a starter library is a guess about somebody
/// else's commands, and a palette that opens full of commands the user never
/// wrote is a palette they learn to ignore.
///
/// **`shell` is nullable, and nullable is the common case.** It names the shell
/// the snippet is written for (`powerShell`, `commandPrompt`, `wsl`, `posix`),
/// and NULL means "fits any pane". Stored as the enum's own name rather than an
/// integer so a row is readable in `sqlite3` and so an unrecognised tag stays
/// legible instead of becoming an out-of-range ordinal; `CommandSnippet`
/// compares it as a string, which is what makes an unknown tag match *no* pane
/// rather than every pane.
///
/// **`submit` is `NOT NULL DEFAULT 0`.** The default is the safe act — type the
/// command at the prompt and stop — and a column that defaults to running
/// somebody's saved `rm -rf` is the one mistake this schema could make that no
/// later code could undo.
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

/// Todos, and the project a todo or a note is filed under.
///
/// **Six columns, and not one of them is a feature.** The ask was for *simple*
/// todos, so what is here is identity, the line of text, whether it is done,
/// the association that was asked for, the order that was asked for, and when
/// it was written. No due date, no priority, no label, no assignee, no
/// recurrence — every one of those is a box to fill in before the list works,
/// and a todo list nobody has to learn beats a task manager nobody opens.
///
/// **`done_at` rather than a `done` flag.** It is the same boolean — null is
/// open — and it also answers "when did I finish that", which a `0` cannot and
/// which nothing else in the row records. A flag would throw the fact away and
/// save nothing.
///
/// **`position` earns its column because the request named it**: "a line of
/// text, done or not, ordered". Ordering by `created_at` would be *an* order
/// but not the user's, and the row that most needs to move to the top is
/// exactly the one that has sat there longest. Dense integers, renumbered on a
/// move, rather than fractional indices: the list is tens of rows, the
/// renumber is one transaction, and float midpoints exhaust their precision in
/// a way that is silent when it happens.
///
/// **`project_id` is nullable on both tables and stays nullable.** A todo filed
/// under nothing is an ordinary todo, not a row waiting to be fixed — the same
/// argument v31 makes for `projects.workspace_id`, and the foreign key is
/// `ON DELETE SET NULL` for the same reason it is there. Deleting a project
/// must lose the *filing*, never the writing: a project is deleted when the
/// work is over, and "the work is over" is exactly when the leftover note
/// saying what went wrong is worth the most. A cascade would turn "I am done
/// with this checkout" into "and delete everything I wrote about it".
///
/// **Why a foreign key here when `notes.source_session_id` deliberately has
/// none.** Those columns record where a note *came from*, and what they name
/// may never have been a row of ours — an imported CLI session, a transcript we
/// only read. `project_id` records where the user *filed* it, and a project is
/// a row this app creates and deletes. A dangling origin is honest history
/// ("from a session that is gone"); a dangling filing is a menu entry that
/// draws a blank.
///
/// **The one `UPDATE`, and why it is not the data movement v31 refused.** Every
/// note captured from a session already records that session's repository, and
/// a repository belongs to exactly one project — so the project a note was
/// written in is a fact *this database already holds*, not the guess v31 would
/// have had to make about thirty-one projects. The statement writes only into
/// the column created two statements above it, so there is nothing it can
/// overwrite: one `ALTER TABLE` ago that column did not exist. Without it every
/// real note the owner has would land unfiled on the day the filter shipped,
/// and the feature would look broken by its own first impression.
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
  // The list is read whole and split in memory, so this index serves exactly
  // one query: the `SET NULL` fan-out when a project is deleted. That is
  // enough — without it, deleting a project scans every todo ever written.
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

/// Per-agent permission modes: a session records the mode in **its agent's own
/// vocabulary** instead of a shared three-value enum.
///
/// The column keeps its name and its type. What changes is what the string
/// means: `ask` / `acceptEdits` / `bypass` become a canonical selection over
/// that agent's declared axes — `mode=manual` for Claude Code,
/// `approval=on-request;sandbox=workspace-write` for Codex. A NULL is left
/// NULL: it means "this session never chose" and still does.
///
/// **The rewrite is argument-preserving for two of the three agents.** Claude
/// Code and Antigravity map one-for-one onto the flags they already sent, so no
/// migrated session's command line changes by a character:
///
///   ask         -> --permission-mode manual     / (no flag)
///   acceptEdits -> --permission-mode acceptEdits / --mode accept-edits
///   bypass      -> --permission-mode bypassPermissions
///                                                / --dangerously-skip-permissions
///
/// **Codex's `ask` is the one cell that changes, by one added flag.** It used
/// to send `--ask-for-approval on-request` and no `--sandbox` at all, which the
/// descriptor itself documented as *not* an ask-every-time. It now sends
/// `--sandbox workspace-write --ask-for-approval on-request` — the same
/// approval policy, plus an explicit sandbox that matches Codex's own default.
///
/// **The caveat, for whoever finds this next:** a user whose
/// `~/.codex/config.toml` sets a different `sandbox_mode` was previously having
/// that honoured, because we passed no `--sandbox`. After this they get
/// `workspace-write` from the command line, which wins. That is deliberate —
/// the alternative was declaring a "Codex's own default" value whose
/// permissiveness we cannot state — but it is a real behaviour change for that
/// user, and the fix if it ever matters is a declared sandbox value that passes
/// no flag, once somebody has established what it permits.
///
/// Nothing is dropped, renamed or deleted: one `UPDATE` over one text column,
/// safe to run with the app open.
void _migrateToV35(Database db) {
  // (agent id, legacy value, canonical selection). The selections are the
  // canonical form `AgentPermissionSupport.normalise` produces — axis ids in
  // alphabetical order, and a superseded axis reset to its default, which is
  // why Codex's bypass still names `approval=on-request`.
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

/// Index the CLI conversation a session records.
///
/// `sessions.external_session_id` is the lookup used once per detected CLI
/// conversation by import and adoption. Including the stable ordering columns
/// lets SQLite answer both the filter and `created_at DESC, id DESC` without
/// scanning the session table or building a temporary sort.
void _migrateToV36(Database db) {
  db.execute(
    'CREATE INDEX IF NOT EXISTS idx_sessions_external '
    'ON sessions (external_session_id, created_at, id);',
  );
}

/// Index the installation a session ran under.
///
/// This serves the re-detection guard, installation repoint, and the foreign
/// key check SQLite performs when an installation is removed.
void _migrateToV37(Database db) {
  db.execute(
    'CREATE INDEX IF NOT EXISTS idx_sessions_installation '
    'ON sessions (agent_installation_id);',
  );
}

/// Saved Codex OAuth identities.
///
/// The complete token bundle is retained because a refresh token, account id
/// and access token are one credential. Nothing is logged or split into
/// independently stale columns; the display fields are denormalized only.
///
/// **Its own version, and that is not cosmetic.** This table was first written
/// into `_migrateToV36` on a branch, beside the index that version already
/// carried on `main`. A version number is not a label — it is compared against
/// the stored `PRAGMA user_version`, and only steps *greater* than it run. A
/// database that had already taken `main`'s v36 therefore stands at 36, skips
/// it forever, and never sees this table at all: the app would then query
/// `codex_accounts` on a database that has none. Two branches may not spend the
/// same number on different work.
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

/// Whether a human chose an installation's executable path.
///
/// The same distinction `sessions.title_by_user` draws, for the same reason: a
/// sweep must not overwrite an explicit choice, and *"the path differs from
/// what discovery would find"* is not a usable test for one — it cannot be
/// recovered after a restart, and inferring it that way was a real bug when the
/// title sync tried it. So it is recorded.
///
/// The rule it enables, in two halves:
///
/// * a **broken** path is repaired whoever set it — a stale path helps nobody;
/// * a **working** hand-set path is never replaced by a sweep, even when
///   discovery would now pick a different one.
///
/// Defaults to 0, so every row that already exists is what it in fact is:
/// found by discovery, and free to be moved by it.
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

/// When an installation's version was last read from the binary.
///
/// The version column was written by discovery and never revisited:
/// `discoverUnprobed` skips any pair that already has a row, so only a manual
/// "Detect agents" reached the update. The app reported Claude Code 2.1.252 for
/// a binary answering 2.1.260 and nothing on screen could say which of the two
/// it was — a bare number reads exactly like a current one.
///
/// **Nullable, and left null for every existing row.** Backfilling it from
/// `created_at` would invent a reading time for a number whose age nobody
/// recorded, which is the §19 mistake in a migration: an unknown is never a
/// zero. A null here means "we have a number and no idea when it was read", and
/// that is what gets rendered.
void _migrateToV40(Database db) {
  final columns = db
      .select('PRAGMA table_info(agent_installations);')
      .map((row) => row['name'] as String);
  if (columns.contains('version_read_at')) return;
  db.execute(
    'ALTER TABLE agent_installations ADD COLUMN version_read_at TEXT;',
  );
}
