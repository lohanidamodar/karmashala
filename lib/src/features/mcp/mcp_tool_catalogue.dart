/// What each tool does to the world, declared as MCP tool annotations.
///
/// ## Why a table and not a field on each schema
///
/// The schemas are spread across three features — `launcher_control_server`,
/// `browser_tool_schemas`, `verification_tool_schemas` — and the one question a
/// reader actually arrives with is "which of these can I not undo". That
/// question is only answerable if the answers sit next to each other. Spread
/// across three files it is a survey; here it is a glance.
///
/// ## What the four hints mean, decided once
///
/// The spec defines them loosely enough that a table can drift into wishful
/// thinking, so this file uses one rule per hint and applies it everywhere:
///
/// * **`readOnlyHint`** — nothing changes. Not in the app, not on disk, not on
///   an attached device, not on a page. A tool that records a row is not
///   read-only even when it reads to decide what to record.
/// * **`destructiveHint`** — there is no undo for what it removes, overwrites
///   or ends. Ending a session is destructive. Starting one is not.
/// * **`idempotentHint`** — the same arguments twice leave the same state, and
///   a retry after a failure is safe. Anything that appends is not idempotent.
/// * **`openWorldHint`** — it reaches past this machine's own repositories: the
///   web, or an attached phone.
///
/// These are **hints**, and the spec says clients must treat them as untrusted.
/// Nothing here is enforcement. What actually keeps a destructive call from
/// happening by accident is that it is its own tool with its own required
/// arguments, never a flag on a read.
library;

/// The behaviour of one tool, as `tools/list` reports it.
class McpToolAnnotations {
  const McpToolAnnotations({
    this.readOnly = false,
    this.destructive = false,
    this.idempotent = false,
    this.openWorld = false,
  });

  /// Reads and changes nothing.
  static const McpToolAnnotations read = McpToolAnnotations(
    readOnly: true,
    idempotent: true,
  );

  /// Reads and changes nothing, but what it reads is outside this machine.
  static const McpToolAnnotations readOutside = McpToolAnnotations(
    readOnly: true,
    idempotent: true,
    openWorld: true,
  );

  final bool readOnly;
  final bool destructive;
  final bool idempotent;
  final bool openWorld;

  Map<String, Object?> toJson() => <String, Object?>{
    'readOnlyHint': readOnly,
    // Only meaningful when the tool is not read-only, and the spec's default is
    // `true` — so it is always written out rather than left to a default a
    // reader would have to remember.
    'destructiveHint': destructive,
    'idempotentHint': idempotent,
    'openWorldHint': openWorld,
  };
}

/// Every tool this app serves, and what it does.
///
/// A tool missing from here is a bug, not a default: `mcp_tool_catalogue_test`
/// asserts this map and the served schemas name exactly the same set, so a new
/// tool cannot ship without someone deciding whether it can be undone.
const Map<String, McpToolAnnotations> kMcpToolAnnotations =
    <String, McpToolAnnotations>{
      // The guides. Reads a table compiled into the binary; touches nothing.
      'instructions': McpToolAnnotations.read,

      // Checkpoints — a per-turn record of the working tree.
      'checkpoint_list': McpToolAnnotations.read,
      'checkpoint_diff': McpToolAnnotations.read,
      'checkpoint_capture': McpToolAnnotations(),
      // Overwrites the working tree with an older one. The only tool here that
      // can throw away work nobody recorded anywhere else.
      'checkpoint_restore': McpToolAnnotations(destructive: true),

      // Workspace.
      'list_projects': McpToolAnnotations.read,
      'list_checkouts': McpToolAnnotations.read,
      'delivery_status': McpToolAnnotations.read,
      // Reads the directory and records what it finds. Running it twice over
      // an unchanged directory changes nothing the first run did not.
      'project_rescan': McpToolAnnotations(idempotent: true),
      'select_checkout': McpToolAnnotations(idempotent: true),
      // Makes a directory and a branch. Not idempotent: the second call finds
      // its own first call in the way and is refused.
      'worktree_create': McpToolAnnotations(),
      // Deletes a working tree. The one tool here that can take a directory
      // away, which is why it refuses on anything it cannot read.
      'worktree_remove': McpToolAnnotations(destructive: true),

      // Sessions.
      'list_sessions': McpToolAnnotations.read,
      'list_agents': McpToolAnnotations.read,
      'get_usage': McpToolAnnotations.read,
      'open_new_session': McpToolAnnotations(),
      // Reveals a session that is already running, or resumes one that is not
      // — and for an *imported* CLI session, opens an external terminal window
      // to resume it in. Twice is twice on that branch: a second call opens a
      // second window, and nothing in this surface closes one. It was annotated
      // idempotent, which is the hint a client reads before deciding it is safe
      // to repeat or to run over a list, and a driver walking `list_sessions`
      // opened a window per row on the owner's desktop.
      'open_session': McpToolAnnotations(),
      'session_transcript': McpToolAnnotations.read,
      // Watches, and changes nothing. Idempotent in the sense this file means —
      // the same call twice leaves the same state — even though the two answers
      // may differ, because that difference is the session moving rather than
      // this tool doing anything. Calling it again after a timeout is not
      // merely safe, it is the intended response to one.
      'session_wait': McpToolAnnotations.read,
      'session_send': McpToolAnnotations(),
      // Presses the agent's own approve/deny key. Approving is granting
      // permission for something that then happens, and nothing un-happens it.
      'session_answer': McpToolAnnotations(destructive: true),
      'session_rename': McpToolAnnotations(idempotent: true),
      // Ends the agent process. The transcript survives; the turn in flight
      // does not, and nothing brings it back.
      'session_end': McpToolAnnotations(destructive: true),
      'session_handoff': McpToolAnnotations(),
      'session_fork': McpToolAnnotations(),
      'open_sessions_in_tmux': McpToolAnnotations(),

      // Terminal.
      'terminal_list': McpToolAnnotations.read,
      'terminal_output': McpToolAnnotations.read,
      'terminal_open': McpToolAnnotations(),
      // Types a command the caller composed into a live shell. Whether that is
      // destructive is the command's business, not this tool's, and a tool that
      // cannot tell must not claim it is safe.
      'terminal_run': McpToolAnnotations(destructive: true),
      // Detaches by default and can be told to kill. The annotation describes
      // the worst it does, because a client deciding whether to confirm cannot
      // see which argument was passed.
      'terminal_close': McpToolAnnotations(destructive: true),

      // Recording. None of it is destructive — a recording writes a new file
      // and takes nothing away — but none of it is read-only either: it turns
      // capture on, and what it captures is whatever is on screen.
      'terminal_record_start': McpToolAnnotations(),
      'terminal_record_stop': McpToolAnnotations(),
      // Reads a phone, writes this computer, the way `device_file_pull` does.
      'device_record_start': McpToolAnnotations(openWorld: true),
      'device_record_stop': McpToolAnnotations(openWorld: true),

      // Saved command snippets.
      'snippets_list': McpToolAnnotations.read,
      // Appends a row to the user's own library. Not idempotent: twice is two
      // snippets.
      'snippet_add': McpToolAnnotations(),
      // Types a saved command into a live shell. Read-only it is not, and the
      // annotation describes the worst it does — the same rule `terminal_close`
      // states: a snippet the user saved with submit=true runs on insertion,
      // and a client deciding whether to confirm cannot see which one this is.
      'snippet_insert': McpToolAnnotations(destructive: true),
      // Todos: the one list a person and an agent both write to.
      'todos_list': McpToolAnnotations.read,
      'todo_add': McpToolAnnotations(),
      // Sets one field and only that field. Idempotent — finishing a finished
      // todo leaves the same todo. **Not** destructive: the row is still there
      // afterwards, and `done: false` puts it back, which is exactly the undo
      // `destructiveHint` says does not exist. Same call as
      // `review_thread_status`.
      'todo_done': McpToolAnnotations(idempotent: true),
      'todo_delete': McpToolAnnotations(destructive: true),

      // Notes and the inbox.
      'notes_list': McpToolAnnotations.read,
      'inbox_list': McpToolAnnotations.read,
      'note_add': McpToolAnnotations(),
      'note_delete': McpToolAnnotations(destructive: true),
      'inbox_open': McpToolAnnotations(idempotent: true),
      // An item for an event is gone for good; one for a condition that still
      // holds is re-filed by the next poll. The annotation describes the worse
      // of the two, because the caller cannot know which it has.
      'inbox_dismiss': McpToolAnnotations(destructive: true, idempotent: true),

      // The decision record. Appends a row nothing can edit or remove, which
      // is not idempotent — a second identical call is a second decision, and
      // the record's job is to say that it was made twice.
      'decision_record': McpToolAnnotations(),

      // Review threads. A comment somebody can come back to: an anchor, a
      // status, and replies.
      'review_thread_list': McpToolAnnotations.read,
      'review_thread_get': McpToolAnnotations.read,
      // Opens a thread and writes its first comment. Not idempotent, for the
      // same reason `decision_record` is not: a second identical call is a
      // second comment, and collapsing them would silently discard the fact
      // that it was raised twice. Not destructive — it removes nothing, and an
      // agent's thread lands as `open`, which is a claim rather than an
      // instruction.
      'review_thread_add': McpToolAnnotations(),
      // Appends to a thread. Append-only, so not idempotent and not
      // destructive: nothing already said can be edited or taken back by it.
      'review_thread_reply': McpToolAnnotations(),
      // Overwrites one field and only that field. Idempotent — the same status
      // twice leaves the same thread. **Not** destructive, and that was the
      // close call: moving a thread to `dismissed` or `resolved` takes it out
      // of the set that gets sent to an agent, which feels like ending
      // something. But nothing is removed — every comment and the anchor stay
      // exactly as they were, and one more call puts the status back, which is
      // precisely the undo `destructiveHint` says does not exist. `inbox_dismiss`
      // is marked destructive because for an event-derived item nothing re-files
      // it; a review thread is a row that is still there afterwards. Same call
      // as `session_rename`, which also overwrites a field and is not marked.
      'review_thread_status': McpToolAnnotations(idempotent: true),

      // Fan-out.
      'fanout_list': McpToolAnnotations.read,
      'fanout_get': McpToolAnnotations.read,

      // Devices. Everything here touches a phone, so all of it is open-world.
      'list_devices': McpToolAnnotations.readOutside,
      'device_screenshot': McpToolAnnotations.readOutside,
      'device_logcat': McpToolAnnotations.readOutside,
      'device_ui_dump': McpToolAnnotations.readOutside,
      'device_find_elements': McpToolAnnotations.readOutside,
      'device_files_list': McpToolAnnotations.readOutside,
      // Reading the device, writing this computer — so not `readOnly`, even
      // though nothing on the phone changes.
      'device_file_pull': McpToolAnnotations(openWorld: true),
      // Writing someone's device. Not marked destructive because it refuses
      // rather than replacing unless `overwrite` is asked for, and a new file
      // where there was none is not a loss — but `overwrite: true` is a
      // deliberate one, which is why it has to be asked for by name.
      'device_file_push': McpToolAnnotations(openWorld: true),
      // A tap lands wherever it lands. On someone's own phone that includes
      // "confirm delete", and there is no undo on the other side of the wire.
      'device_tap': McpToolAnnotations(destructive: true, openWorld: true),
      'device_tap_element': McpToolAnnotations(
        destructive: true,
        openWorld: true,
      ),
      'device_type': McpToolAnnotations(destructive: true, openWorld: true),
      'device_key': McpToolAnnotations(destructive: true, openWorld: true),
      'device_stop_emulator': McpToolAnnotations(
        destructive: true,
        idempotent: true,
        openWorld: true,
      ),
      // Starting something is not destructive — see the rule at the top of this
      // file — and asking twice for a device that is already up leaves it up,
      // which is what idempotent means here.
      'device_boot': McpToolAnnotations(idempotent: true, openWorld: true),
      // Overwrites whatever build of the same app was on the device, with no
      // undo: the previous binary is gone. Idempotent because installing the
      // same artifact twice leaves the same device.
      'device_install_app': McpToolAnnotations(
        destructive: true,
        idempotent: true,
        openWorld: true,
      ),
      // A launch runs somebody's code on a device. Not idempotent: launching
      // twice is two starts, and with relaunch it is two *cold* starts, which
      // is a different device state from one.
      'device_launch_app': McpToolAnnotations(openWorld: true),
      // Ends a running process, and anything it had not saved goes with it.
      'device_terminate_app': McpToolAnnotations(
        destructive: true,
        idempotent: true,
        openWorld: true,
      ),

      // Browser. The page is someone's real logged-in session, so the same
      // reasoning as devices applies to anything that acts on it.
      'browser_find': McpToolAnnotations.readOutside,
      'browser_screenshot': McpToolAnnotations.readOutside,
      'browser_capture': McpToolAnnotations.readOutside,
      'browser_pick': McpToolAnnotations.readOutside,
      'browser_connect': McpToolAnnotations(idempotent: true, openWorld: true),
      'browser_navigate': McpToolAnnotations(idempotent: true, openWorld: true),
      'browser_tabs': McpToolAnnotations(openWorld: true),
      'browser_fill': McpToolAnnotations(idempotent: true, openWorld: true),
      'browser_type': McpToolAnnotations(openWorld: true),
      'browser_click': McpToolAnnotations(destructive: true, openWorld: true),
      'browser_key': McpToolAnnotations(destructive: true, openWorld: true),
      'browser_evaluate': McpToolAnnotations(
        destructive: true,
        openWorld: true,
      ),

      // The Flutter app the developer is running. Open-world for the same
      // reason the device tools are: the app is a process on a desktop, a
      // phone or a simulator, and not this machine's repositories.
      'flutter_apps': McpToolAnnotations.read,
      'flutter_logs': McpToolAnnotations.readOutside,
      // Reads what the developer points at. It puts the app into Flutter's own
      // widget-select mode and takes it back out; nothing in the app is
      // changed by the round trip.
      'flutter_pick_widget': McpToolAnnotations.readOutside,
      // Attaching twice to the same app is the same as attaching once.
      'flutter_attach': McpToolAnnotations(idempotent: true, openWorld: true),
      // Destructive because `fullRestart` re-runs main() and the app loses the
      // state it had — no undo — and the annotation describes the worse case: a
      // client deciding whether to confirm cannot see which argument was
      // passed. Same rule as `terminal_close`.
      'flutter_reload': McpToolAnnotations(destructive: true, openWorld: true),
      // Starts and stops builds, apps and gates. Destructive because `stop`
      // ends a running app and anything it had not saved goes with it, and
      // because the annotation describes the worst the tool does — a client
      // deciding whether to confirm cannot see which action was passed. Not
      // idempotent: two `run`s are two launches, and `pubGet` twice is twice.
      // Open-world for the same reason the device tools are — a launch puts an
      // app on a phone, and a gate is a process on somebody's machine.
      'flutter_run': McpToolAnnotations(destructive: true, openWorld: true),

      // Verification runs.
      'verification_list': McpToolAnnotations.read,
      'verification_get': McpToolAnnotations.read,
      'verification_start': McpToolAnnotations(),
      'verification_note': McpToolAnnotations(),
      'verification_finish': McpToolAnnotations(),
    };

/// The families the tools are shown in, in the order Settings draws them.
///
/// A fixed set rather than a name prefix: `list_devices` is a device tool and
/// `get_usage` is a session one, and a grouping computed from prefixes puts
/// both in a bucket of their own. The order is what a person scans — what
/// happens inside Karmashala first, then what reaches outside it, then the
/// guides about the rest.
enum McpToolCategory {
  sessions(
    'Sessions and agents',
    'Start, read, message and end the agent sessions Karmashala runs.',
  ),
  terminals(
    'Terminals',
    'Open tabs, run commands, and read what a pane is showing.',
  ),
  snippets(
    'Saved commands',
    'The commands the user keeps, and putting one at a prompt.',
  ),
  workspace(
    'Projects and worktrees',
    'The projects, their checkouts, and the worktrees work runs in.',
  ),
  checkpoints(
    'Checkpoints',
    'The per-turn record of the working tree, and putting it back.',
  ),
  records(
    'Notes, todos and the inbox',
    'The written things a person reads, plus the decision record.',
  ),
  review(
    'Review threads',
    'Comments raised against a file, anchored so they outlive the turn.',
  ),
  verification(
    'Verification runs',
    'The durable record that a change was driven and actually worked.',
  ),
  fanout(
    'Fan-out comparisons',
    'One prompt run on several agents at once, and how they compared.',
  ),
  devices(
    'Devices and simulators',
    'Android devices, emulators and iOS simulators this machine can drive.',
  ),
  browser(
    'Browser',
    'A real Chrome or Edge — the developer\'s own logged-in window.',
  ),
  flutterApps(
    'Flutter apps',
    'Starting a Flutter project, and the app once it is running.',
  ),
  guides(
    'Guides',
    'Karmashala\'s own notes on what a tool proves and what has no undo.',
  );

  const McpToolCategory(this.label, this.blurb);

  /// The heading Settings draws.
  final String label;

  /// One line under the heading: what the family is about.
  final String blurb;
}

/// One tool as a person reads it: which family it is in, and what it does.
///
/// Separate from [McpToolAnnotations] rather than folded into it because the
/// two answer different questions for different readers. The annotations are
/// hints a *client* acts on — whether to confirm, whether a retry is safe —
/// and every tool that behaves alike shares one const. A summary is prose
/// nobody can share, written for whoever opens Settings and asks what the
/// thing they installed can actually do.
class McpToolListing {
  const McpToolListing(this.category, this.summary);

  final McpToolCategory category;

  /// One line, compressed from the tool's own schema description. Never
  /// invented: if the schema does not say it, this does not either.
  final String summary;

  /// The cap `mcp_tool_catalogue_test` enforces. Past this the line wraps in
  /// the settings list and stops being something an eye can skip down.
  static const int summaryLimit = 80;
}

/// Every served tool, in its family, in one line.
///
/// Grouped rather than kept in [kMcpToolAnnotations]'s order so that a reader
/// can see at a glance which family a new tool was filed under — the decision
/// most likely to be got wrong. `mcp_tool_catalogue_test` holds this against
/// the served schemas in both directions, so a tool cannot ship listed as a
/// bare name.
const Map<String, McpToolListing> kMcpToolListings = <String, McpToolListing>{
  // Sessions and agents.
  'list_sessions': McpToolListing(
    McpToolCategory.sessions,
    'Agent sessions, running here or imported from a CLI store.',
  ),
  'list_agents': McpToolListing(
    McpToolCategory.sessions,
    'The installed agents a new session can be started with.',
  ),
  'open_new_session': McpToolListing(
    McpToolCategory.sessions,
    'Start a new agent session in a project, as a tab in Karmashala.',
  ),
  'open_session': McpToolListing(
    McpToolCategory.sessions,
    'Reattach to a session or resume it; an imported one opens a window.',
  ),
  'open_sessions_in_tmux': McpToolListing(
    McpToolCategory.sessions,
    'Open several sessions as tmux windows in one terminal tab (WSL).',
  ),
  'session_transcript': McpToolListing(
    McpToolCategory.sessions,
    'What a session has said: its recorded turns and its current screen.',
  ),
  'session_send': McpToolListing(
    McpToolCategory.sessions,
    'Send a message to a session, as typing into its message box would.',
  ),
  'session_wait': McpToolListing(
    McpToolCategory.sessions,
    'Block until a session settles — finished, blocked on a person, or ended.',
  ),
  'session_answer': McpToolListing(
    McpToolCategory.sessions,
    'Press a session\'s own approve or deny key on its on-screen prompt.',
  ),
  'session_rename': McpToolListing(
    McpToolCategory.sessions,
    'Rename a session — the title every list and tab shows.',
  ),
  'session_end': McpToolListing(
    McpToolCategory.sessions,
    'Stop the agent process behind a session; the turn in flight is lost.',
  ),
  'session_handoff': McpToolListing(
    McpToolCategory.sessions,
    'Continue a session in a different agent, on the same branch.',
  ),
  'session_fork': McpToolListing(
    McpToolCategory.sessions,
    'Branch a session into one that shares its history and then diverges.',
  ),
  'get_usage': McpToolListing(
    McpToolCategory.sessions,
    'An agent\'s usage against its limit, as percentages.',
  ),

  // Terminals.
  'terminal_list': McpToolListing(
    McpToolCategory.terminals,
    'The layout: tabs, panes, focus, detached panes, shell profiles.',
  ),
  'terminal_open': McpToolListing(
    McpToolCategory.terminals,
    'Open a terminal tab the user can watch and take over.',
  ),
  'terminal_run': McpToolListing(
    McpToolCategory.terminals,
    'Run a command in a pane and wait for its output and exit code.',
  ),
  'terminal_output': McpToolListing(
    McpToolCategory.terminals,
    'Read a pane\'s recent output — the screen as it stands, not a log.',
  ),
  'terminal_close': McpToolListing(
    McpToolCategory.terminals,
    'Close a tab; a busy pane detaches and keeps running unless killed.',
  ),
  'terminal_record_start': McpToolListing(
    McpToolCategory.terminals,
    'Record a pane. Everything printed is captured, nothing redacted.',
  ),
  'terminal_record_stop': McpToolListing(
    McpToolCategory.terminals,
    'Stop the recording and render it to mp4, gif or numbered pictures.',
  ),

  // Saved commands.
  'snippets_list': McpToolListing(
    McpToolCategory.snippets,
    'The commands this person keeps, and whether each fits a given pane.',
  ),
  'snippet_add': McpToolListing(
    McpToolCategory.snippets,
    'Save a command as a snippet, tagged for the shell it is written for.',
  ),
  'snippet_insert': McpToolListing(
    McpToolCategory.snippets,
    'Type a saved snippet at a pane\'s prompt and stop, for the user to run.',
  ),

  // Projects and worktrees.
  'list_projects': McpToolListing(
    McpToolCategory.workspace,
    'The projects Karmashala knows: name, environment and path.',
  ),
  'list_checkouts': McpToolListing(
    McpToolCategory.workspace,
    'A project\'s checkouts: the branch each is on, and who works in it.',
  ),
  'project_rescan': McpToolListing(
    McpToolCategory.workspace,
    'Re-read a project\'s directory for checkouts not known about yet.',
  ),
  'select_checkout': McpToolListing(
    McpToolCategory.workspace,
    'Point the Explorer, diff view and side panel at a checkout.',
  ),
  'delivery_status': McpToolListing(
    McpToolCategory.workspace,
    'What a checkout still owes: ahead, behind, dirty, unpushed, its PR.',
  ),
  'worktree_create': McpToolListing(
    McpToolCategory.workspace,
    'Add a git worktree on a new branch, beside the checkout.',
  ),
  'worktree_remove': McpToolListing(
    McpToolCategory.workspace,
    'Delete a worktree — only when it is clean, merged and pushed.',
  ),

  // Checkpoints.
  'checkpoint_list': McpToolListing(
    McpToolCategory.checkpoints,
    'A session\'s checkpoints, and what changed since the one before.',
  ),
  'checkpoint_capture': McpToolListing(
    McpToolCategory.checkpoints,
    'Record the working tree as it is now, staging and committing nothing.',
  ),
  'checkpoint_diff': McpToolListing(
    McpToolCategory.checkpoints,
    'The diff between a checkpoint and the checkpoint before it.',
  ),
  'checkpoint_restore': McpToolListing(
    McpToolCategory.checkpoints,
    'Put the working tree back to a checkpoint, discarding edits since.',
  ),

  // Notes, todos and the inbox.
  'notes_list': McpToolListing(
    McpToolCategory.records,
    'The notes kept in Karmashala, newest first.',
  ),
  'note_add': McpToolListing(
    McpToolCategory.records,
    'Write a note, kept exactly as given and filed under a project.',
  ),
  'note_delete': McpToolListing(
    McpToolCategory.records,
    'Delete a note. Notes are not versioned and there is no undo.',
  ),
  'todos_list': McpToolListing(
    McpToolCategory.records,
    'The written todo list a person reads: open first, then finished.',
  ),
  'todo_add': McpToolListing(
    McpToolCategory.records,
    'Add one todo to the bottom of the list, kept as one line.',
  ),
  'todo_done': McpToolListing(
    McpToolCategory.records,
    'Tick a todo off, or reopen it. The row stays either way.',
  ),
  'todo_delete': McpToolListing(
    McpToolCategory.records,
    'Delete a todo. todo_done finishes one and keeps the row.',
  ),
  'inbox_list': McpToolListing(
    McpToolCategory.records,
    'What is waiting on somebody: approvals, failures, unread turns, PRs.',
  ),
  'inbox_open': McpToolListing(
    McpToolCategory.records,
    'Bring an inbox item\'s session to the front and mark the item seen.',
  ),
  'inbox_dismiss': McpToolListing(
    McpToolCategory.records,
    'Take an item off the inbox without opening it.',
  ),
  'decision_record': McpToolListing(
    McpToolCategory.records,
    'Write down a decision so it reaches the next agent. Append-only.',
  ),

  // Review threads.
  'review_thread_list': McpToolListing(
    McpToolCategory.review,
    'The review threads on a checkout, and whether each still anchors.',
  ),
  'review_thread_get': McpToolListing(
    McpToolCategory.review,
    'One thread: every comment, and whether it still anchors to the file.',
  ),
  'review_thread_add': McpToolListing(
    McpToolCategory.review,
    'Raise a review comment against a file, for a human to triage.',
  ),
  'review_thread_reply': McpToolListing(
    McpToolCategory.review,
    'Answer a review comment in its own thread. Append-only.',
  ),
  'review_thread_status': McpToolListing(
    McpToolCategory.review,
    'Move a thread between open, shouldFix, dismissed and resolved.',
  ),

  // Verification runs.
  'verification_start': McpToolListing(
    McpToolCategory.verification,
    'Begin recording a run against a URL, a device, or a diff.',
  ),
  'verification_note': McpToolListing(
    McpToolCategory.verification,
    'Add a step of your own: what you are checking, or what you saw.',
  ),
  'verification_finish': McpToolListing(
    McpToolCategory.verification,
    'Close the run with a verdict, collect the evidence, write the report.',
  ),
  'verification_list': McpToolListing(
    McpToolCategory.verification,
    'The recorded runs, newest first, one line each.',
  ),
  'verification_get': McpToolListing(
    McpToolCategory.verification,
    'One run: its verdict, its steps, and what it captured.',
  ),

  // Fan-out comparisons.
  'fanout_list': McpToolListing(
    McpToolCategory.fanout,
    'The comparisons: one prompt run on several agents in parallel.',
  ),
  'fanout_get': McpToolListing(
    McpToolCategory.fanout,
    'One comparison in full: every candidate, its diff and its verdict.',
  ),

  // Devices and simulators.
  'list_devices': McpToolListing(
    McpToolCategory.devices,
    'Everything this machine can drive, and what is wrong with the rest.',
  ),
  'device_boot': McpToolListing(
    McpToolCategory.devices,
    'Start a virtual device headless and wait until it answers.',
  ),
  'device_stop_emulator': McpToolListing(
    McpToolCategory.devices,
    // The ninth claiming tool: it takes the device after the already-stopped
    // early returns, so it is missing from the driver's call sites.
    'Shut down a running emulator or simulator. One session drives at a time.',
  ),
  // The eight tools below take the device for their caller: a second session's
  // call is refused by name while somebody is driving. Reads are not, which is
  // why only these eight say so.
  'device_install_app': McpToolListing(
    McpToolCategory.devices,
    'Install an .apk or simulator .app over any copy. One session drives at a '
        'time.',
  ),
  'device_launch_app': McpToolListing(
    McpToolCategory.devices,
    'Launch an app by application or bundle id. One session drives at a time.',
  ),
  'device_terminate_app': McpToolListing(
    McpToolCategory.devices,
    'Force-stop a running app on a device. One session drives at a time.',
  ),
  'device_screenshot': McpToolListing(
    McpToolCategory.devices,
    'Capture the current screen as a PNG.',
  ),
  'device_ui_dump': McpToolListing(
    McpToolCategory.devices,
    'The screen\'s accessibility tree: what is on it, and where to tap.',
  ),
  'device_find_elements': McpToolListing(
    McpToolCategory.devices,
    'Find elements by text, id, description or class, with a point to tap.',
  ),
  'device_tap_element': McpToolListing(
    McpToolCategory.devices,
    'Tap what a query matches, not a coordinate. One session drives at a time.',
  ),
  // The one device tool with a refusal of its own. It re-reads the screen
  // before it acts, so a coordinate taken from a hierarchy that has since
  // moved does not go out — which is worth the line more than the pixels-vs-
  // points note it replaces, now that the policy says to prefer the element.
  'device_tap': McpToolListing(
    McpToolCategory.devices,
    'Tap a coordinate; refused if the screen moved (verify: false) or in use.',
  ),
  'device_type': McpToolListing(
    McpToolCategory.devices,
    'Type into the field with focus. One session drives at a time.',
  ),
  'device_key': McpToolListing(
    McpToolCategory.devices,
    'Press back, home, recents, power or volume. One session drives at a time.',
  ),
  'device_logcat': McpToolListing(
    McpToolCategory.devices,
    'Recent device log output, filtered by app and by level.',
  ),
  'device_files_list': McpToolListing(
    McpToolCategory.devices,
    'The storage a device lets us reach, or one directory on it.',
  ),
  'device_file_pull': McpToolListing(
    McpToolCategory.devices,
    'Copy a file off the device onto this computer.',
  ),
  'device_file_push': McpToolListing(
    McpToolCategory.devices,
    'Push a file, replacing one only if told to. One session drives at a time.',
  ),
  'device_record_start': McpToolListing(
    McpToolCategory.devices,
    'Record the device screen from the live view\'s own frames.',
  ),
  'device_record_stop': McpToolListing(
    McpToolCategory.devices,
    'Stop that recording and say what file it produced, if any.',
  ),

  // Browser.
  'browser_connect': McpToolListing(
    McpToolCategory.browser,
    'Attach to a Chrome or Edge already listening on a debugging port.',
  ),
  'browser_navigate': McpToolListing(
    McpToolCategory.browser,
    'Go to a URL in the attached page and report where it ended up.',
  ),
  'browser_tabs': McpToolListing(
    McpToolCategory.browser,
    'List the drivable tabs, open one, or switch which is being driven.',
  ),
  'browser_find': McpToolListing(
    McpToolCategory.browser,
    'Find elements by CSS selector or by the text a person sees.',
  ),
  'browser_click': McpToolListing(
    McpToolCategory.browser,
    'Click an element, checking first what is really at that point.',
  ),
  'browser_type': McpToolListing(
    McpToolCategory.browser,
    'Type with real key events, so a page filtering on keydown behaves.',
  ),
  'browser_fill': McpToolListing(
    McpToolCategory.browser,
    'Replace a field\'s contents, then read the value back.',
  ),
  'browser_key': McpToolListing(
    McpToolCategory.browser,
    'Press a key in the page: enter, tab, escape, the arrows, and more.',
  ),
  'browser_screenshot': McpToolListing(
    McpToolCategory.browser,
    'See the page as an image: the viewport, all of it, or one element.',
  ),
  'browser_capture': McpToolListing(
    McpToolCategory.browser,
    'One element in full: its markup, the styles that matter, and a crop.',
  ),
  'browser_pick': McpToolListing(
    McpToolCategory.browser,
    'Ask the developer to click the element they mean. Blocks until they do.',
  ),
  'browser_evaluate': McpToolListing(
    McpToolCategory.browser,
    'Run JavaScript in the page. Needs a one-time grant, per project.',
  ),

  // Flutter: starting a project, and the app once it is running.
  'flutter_apps': McpToolListing(
    McpToolCategory.flutterApps,
    'Every running app this can reach, and how to name each one.',
  ),
  'flutter_attach': McpToolListing(
    McpToolCategory.flutterApps,
    'Attach to a running app by the address "flutter run" printed.',
  ),
  'flutter_reload': McpToolListing(
    McpToolCategory.flutterApps,
    'Hot reload the running app, or hot restart it and lose its state.',
  ),
  'flutter_logs': McpToolListing(
    McpToolCategory.flutterApps,
    'The debug console: stdout, log() records, and caught exceptions.',
  ),
  'flutter_pick_widget': McpToolListing(
    McpToolCategory.flutterApps,
    'Ask the developer to tap a widget; get the file and line it came from.',
  ),
  'flutter_run': McpToolListing(
    McpToolCategory.flutterApps,
    'Start a project: pub get, launch on a device, and run its gates.',
  ),

  // Guides.
  'instructions': McpToolListing(
    McpToolCategory.guides,
    'Karmashala\'s operating guides, one topic at a time.',
  ),
};

/// [kMcpToolListings] grouped for display, in category order and then in the
/// order the listing declares them.
///
/// A lazy top-level `final`: nothing computes it until a page asks, and nothing
/// computes it twice.
final Map<McpToolCategory, List<String>> kMcpToolsByCategory =
    <McpToolCategory, List<String>>{
      for (final category in McpToolCategory.values)
        category: <String>[
          for (final entry in kMcpToolListings.entries)
            if (entry.value.category == category) entry.key,
        ],
    };

/// The served tool list: each schema with its annotations attached.
///
/// Annotations are merged here rather than written into the schemas because
/// `/rpc` and the stdio bridge serve the same schemas and have no field to put
/// them in — the bespoke envelope predates tool annotations existing.
List<Map<String, dynamic>> annotatedToolSchemas(
  List<Map<String, dynamic>> schemas,
) => <Map<String, dynamic>>[
  for (final schema in schemas)
    <String, dynamic>{
      ...schema,
      if (kMcpToolAnnotations[schema['name']] case final annotations?)
        'annotations': annotations.toJson(),
    },
];
