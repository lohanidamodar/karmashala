/// What each tool does to the world: the spec's four axes plus `movesAttention`,
/// ours. Hints, never enforcement — and no `automation_*` tool is ever served.
library;

/// Tools that change something and still need no grant: the records an agent
/// keeps of its own work, and a draft the person sends or not. Everything
/// else a session may call that is not read-only acts — on other sessions,
/// terminals, the working tree, projects, devices, the browser, builds — and
/// needs the person to have let **that session** operate Karmashala.
const Set<String> kMcpUngatedWrites = {
  'checkpoint_capture',
  'todo_add',
  'todo_done',
  'note_add',
  'decision_record',
  'review_thread_add',
  'review_thread_reply',
  'review_thread_status',
  'verification_start',
  'verification_note',
  'verification_finish',
  'snippet_add',
  'session_rename',
  'session_draft',
  // Reaches only the session that started the caller, which asked for it.
  'report_to_parent',
};

/// Whether calling [tool] from a session needs the person's operator grant
/// for it (`Session.operatorGranted`, owner 2026-10-01). A tool this
/// catalogue does not know is treated as one that acts.
bool mcpToolNeedsOperatorGrant(String tool) {
  final annotations = kMcpToolAnnotations[tool];
  if (annotations == null) return true;
  return !annotations.readOnly && !kMcpUngatedWrites.contains(tool);
}

/// What an agent reads when [tool] is refused for want of the grant: what
/// happened, what still works, and how the person gives it.
String mcpOperatorRefusal(String tool) =>
    '$tool acts on Karmashala beyond this session\'s own records, and the '
    'person has not let this session operate Karmashala. NOTHING WAS DONE. '
    'Ask them to turn on "Operate Karmashala" for this session (the session '
    'bar, or its Session sheet on a phone), or to start their next message '
    'with /operator. Reading works without it — list_sessions, '
    'session_transcript, terminal_output and the other read tools — and so '
    'do your own todos, notes, decisions, verification records, checkpoint '
    'captures and session_draft.';

/// The behaviour of one tool, as `tools/list` reports it.
class McpToolAnnotations {
  /// [movesAttention] is required and the other four are not: theirs are the
  /// spec's defaults, and this one has no answer until somebody reads the code.
  const McpToolAnnotations({
    required this.movesAttention,
    this.readOnly = false,
    this.destructive = false,
    this.idempotent = false,
    this.openWorld = false,
  });

  /// Reads and changes nothing, and leaves the person where they were.
  static const McpToolAnnotations read = McpToolAnnotations(
    readOnly: true,
    idempotent: true,
    movesAttention: false,
  );

  /// Reads and changes nothing, but what it reads is outside this machine.
  static const McpToolAnnotations readOutside = McpToolAnnotations(
    readOnly: true,
    idempotent: true,
    openWorld: true,
    movesAttention: false,
  );

  final bool readOnly;
  final bool destructive;
  final bool idempotent;
  final bool openWorld;

  /// Running it changes what the person is looking at — the fifth axis.
  final bool movesAttention;

  Map<String, Object?> toJson() => <String, Object?>{
    'readOnlyHint': readOnly,
    // Always written out: it is only meaningful when the tool is not read-only,
    // and the spec's default is `true`.
    'destructiveHint': destructive,
    'idempotentHint': idempotent,
    'openWorldHint': openWorld,
    // Not one of the spec's four. A client that does not know the key ignores
    // it, which is what it would do with no key at all.
    'movesAttentionHint': movesAttention,
  };
}

/// Every tool this app serves, and what it does. A tool missing from here is a
/// bug: `mcp_tool_catalogue_test` asserts this map against the served schemas.
const Map<String, McpToolAnnotations>
kMcpToolAnnotations = <String, McpToolAnnotations>{
  'instructions': McpToolAnnotations.read,

  // Checkpoints — a per-turn record of the working tree.
  'checkpoint_list': McpToolAnnotations.read,
  'checkpoint_diff': McpToolAnnotations.read,
  'checkpoint_capture': McpToolAnnotations(movesAttention: false),
  // Writes a PNG and a row; its browser capture resizes the page's layout for
  // a moment and puts it back, and a device is someone's real phone.
  'checkpoint_screenshot': McpToolAnnotations(
    openWorld: true,
    movesAttention: false,
  ),
  'checkpoint_screenshots': McpToolAnnotations.read,
  'checkpoint_screenshot_compare': McpToolAnnotations.read,
  // The only tool here that can throw away work nobody recorded elsewhere.
  'checkpoint_restore': McpToolAnnotations(
    destructive: true,
    movesAttention: false,
  ),

  // Workspace.
  'list_projects': McpToolAnnotations.read,
  'list_checkouts': McpToolAnnotations.read,
  'delivery_status': McpToolAnnotations.read,
  // gh reads GitHub; nothing is re-run, cancelled or commented on.
  'github_runs': McpToolAnnotations.readOutside,
  'github_run_log': McpToolAnnotations.readOutside,
  // Adds a project and discovers what is under it. Not idempotent: asked
  // twice with the same folder it files the workspace with two of them.
  'project_add': McpToolAnnotations(movesAttention: false),
  // Rewrites one project row, and with a new root the checkout rows under
  // it. Same arguments, same result — and nothing is deleted, so a move
  // that surprises is corrected by moving it back.
  'project_update': McpToolAnnotations(idempotent: true, movesAttention: false),
  // Running it twice over an unchanged directory changes nothing.
  'project_rescan': McpToolAnnotations(idempotent: true, movesAttention: false),
  // Repoints the sidebar, the diff view and the context panel together.
  'select_checkout': McpToolAnnotations(idempotent: true, movesAttention: true),
  // Not idempotent: the second call finds its own first in the way.
  'worktree_create': McpToolAnnotations(movesAttention: false),
  // The one tool here that can take a directory away.
  'worktree_remove': McpToolAnnotations(
    destructive: true,
    movesAttention: false,
  ),
  // Linking a checkout to a session changes where it works, nothing on disk;
  // with a worktree asked for it makes one, so neither call is idempotent.
  'session_checkout_attach': McpToolAnnotations(movesAttention: false),
  'session_checkout_detach': McpToolAnnotations(
    idempotent: true,
    movesAttention: false,
  ),

  // Sessions.
  'list_sessions': McpToolAnnotations.read,
  'list_agents': McpToolAnnotations.read,
  // Brings the search index up to date first, which is a cache, not the world.
  'session_search': McpToolAnnotations.read,
  'get_usage': McpToolAnnotations.read,
  // Lands in a pane, and `openAgentTab` makes that tab active and focused.
  'open_new_session': McpToolAnnotations(movesAttention: true),
  // open_new_session's launch, tab included, then a wait on its answer.
  'subagent_run': McpToolAnnotations(movesAttention: true),
  'delegation_capabilities': McpToolAnnotations.read,
  'delegations': McpToolAnnotations.read,
  'report_to_parent': McpToolAnnotations(movesAttention: false),
  'delegation_set_report': McpToolAnnotations(
    idempotent: true,
    movesAttention: false,
  ),
  // Reveals or resumes; for an imported CLI session it opens an external
  // window, one per call — a driver once opened one per `list_sessions` row.
  'open_session': McpToolAnnotations(movesAttention: true),
  'session_transcript': McpToolAnnotations.read,
  // Idempotent in the sense this file means: calling again after a timeout
  // is the intended response to one.
  'session_wait': McpToolAnnotations.read,
  // Text appears in the target's pane; no tab is switched, no pane focused.
  'session_send': McpToolAnnotations(movesAttention: false),
  // Offered, not sent: the text waits in the target's message box, or at its
  // prompt, until the person presses send. Nothing runs.
  'session_draft': McpToolAnnotations(movesAttention: false),
  // Approving grants permission for something that then happens, and
  // nothing un-happens it.
  'session_answer': McpToolAnnotations(
    destructive: true,
    movesAttention: false,
  ),
  'session_rename': McpToolAnnotations(idempotent: true, movesAttention: false),
  // The transcript survives; the turn in flight does not. Closing the last
  // pane of a tab hands the active tab and the keyboard to another.
  'session_end': McpToolAnnotations(destructive: true, movesAttention: true),
  // Both continue the work in a newly launched, focused tab. `preview:
  // true` is a read on either, and the annotation describes the worst.
  'session_handoff': McpToolAnnotations(movesAttention: true),
  'session_fork': McpToolAnnotations(movesAttention: true),
  // A fork that also rolls the working tree back, so it inherits
  // `checkpoint_restore`'s hazard: it can discard uncommitted work.
  'session_fork_from_checkpoint': McpToolAnnotations(
    destructive: true,
    movesAttention: true,
  ),

  // Terminal.
  'terminal_list': McpToolAnnotations.read,
  'terminal_output': McpToolAnnotations.read,
  // Lists processes and sockets on this machine; changes nothing.
  'terminal_ports': McpToolAnnotations.read,
  // The new tab becomes active, its group activated, its pane focused.
  'terminal_open': McpToolAnnotations(movesAttention: true),
  // Whether the command is destructive is its business, not this tool's, and
  // a tool that cannot tell must not claim it is safe.
  'terminal_run': McpToolAnnotations(destructive: true, movesAttention: false),
  // Detaches by default and can be told to kill: the annotation describes
  // the worst, since a client cannot see which argument was passed.
  'terminal_close': McpToolAnnotations(destructive: true, movesAttention: true),

  // Recording. Not destructive — it writes a new file — and not read-only
  // either: it turns capture on, over whatever is on screen.
  'terminal_record_start': McpToolAnnotations(movesAttention: false),
  'terminal_record_stop': McpToolAnnotations(movesAttention: false),
  // Reads a phone, writes this computer. It records the live view's own
  // frames and refuses when there is none, so it cannot open that pane.
  'device_record_start': McpToolAnnotations(
    openWorld: true,
    movesAttention: false,
  ),
  'device_record_stop': McpToolAnnotations(
    openWorld: true,
    movesAttention: false,
  ),

  // Saved command snippets.
  'snippets_list': McpToolAnnotations.read,
  // Appends a row to the user's own library: twice is two snippets.
  'snippet_add': McpToolAnnotations(movesAttention: false),
  // A snippet the user saved with submit=true runs on insertion, and a
  // client cannot see which one this is.
  'snippet_insert': McpToolAnnotations(
    destructive: true,
    movesAttention: false,
  ),
  // Todos: the one list a person and an agent both write to.
  'todos_list': McpToolAnnotations.read,
  'todo_add': McpToolAnnotations(movesAttention: false),
  // Not destructive: the row is still there afterwards and `done: false`
  // puts it back — the undo `destructiveHint` says does not exist.
  'todo_done': McpToolAnnotations(idempotent: true, movesAttention: false),
  'todo_delete': McpToolAnnotations(destructive: true, movesAttention: false),

  // Notes and the inbox.
  'notes_list': McpToolAnnotations.read,
  'inbox_list': McpToolAnnotations.read,
  'note_add': McpToolAnnotations(movesAttention: false),
  'note_delete': McpToolAnnotations(destructive: true, movesAttention: false),
  // Changes nothing but which session is on screen: `focusWatchedSession`
  // rewrites the selected project, repository and session together.
  'inbox_open': McpToolAnnotations(idempotent: true, movesAttention: true),
  // An item for an event is gone for good; one for a condition is re-filed
  // by the next poll, and the caller cannot know which it has.
  'inbox_dismiss': McpToolAnnotations(
    destructive: true,
    idempotent: true,
    movesAttention: false,
  ),

  // The decision record. Appends a row nothing can edit or remove, and a
  // second identical call is a second decision.
  'decision_record': McpToolAnnotations(movesAttention: false),

  // Review threads.
  'review_thread_list': McpToolAnnotations.read,
  'review_thread_get': McpToolAnnotations.read,
  // Not idempotent: a second identical call is a second comment, and
  // collapsing them would discard that it was raised twice.
  'review_thread_add': McpToolAnnotations(movesAttention: false),
  // Append-only: nothing already said can be edited or taken back.
  'review_thread_reply': McpToolAnnotations(movesAttention: false),
  // Not destructive: every comment and the anchor stay, and one more call
  // puts the status back.
  'review_thread_status': McpToolAnnotations(
    idempotent: true,
    movesAttention: false,
  ),

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
  // Reading the device, writing this computer — so not `readOnly`.
  'device_file_pull': McpToolAnnotations(
    openWorld: true,
    movesAttention: false,
  ),
  // Not destructive: it refuses rather than replacing unless `overwrite`
  // is asked for by name.
  'device_file_push': McpToolAnnotations(
    openWorld: true,
    movesAttention: false,
  ),
  // A tap lands wherever it lands, and there is no undo on the other side
  // of the wire.
  'device_tap': McpToolAnnotations(
    destructive: true,
    openWorld: true,
    movesAttention: false,
  ),
  'device_tap_element': McpToolAnnotations(
    destructive: true,
    openWorld: true,
    movesAttention: false,
  ),
  'device_type': McpToolAnnotations(
    destructive: true,
    openWorld: true,
    movesAttention: false,
  ),
  'device_key': McpToolAnnotations(
    destructive: true,
    openWorld: true,
    movesAttention: false,
  ),
  'device_stop_emulator': McpToolAnnotations(
    destructive: true,
    idempotent: true,
    openWorld: true,
    movesAttention: false,
  ),
  // Booting a device already up leaves it up; it also selects the simulator
  // in the device pane and, unless headless, opens a window.
  'device_boot': McpToolAnnotations(
    idempotent: true,
    openWorld: true,
    movesAttention: true,
  ),
  // Overwrites whatever build was there, with no undo. Idempotent because
  // installing the same artifact twice leaves the same device.
  'device_install_app': McpToolAnnotations(
    destructive: true,
    idempotent: true,
    openWorld: true,
    movesAttention: false,
  ),
  // Not idempotent: twice is two starts, and with relaunch two *cold*
  // starts, which is a different device state from one.
  'device_launch_app': McpToolAnnotations(
    openWorld: true,
    movesAttention: false,
  ),
  // Ends a running process, and anything it had not saved goes with it.
  'device_terminate_app': McpToolAnnotations(
    destructive: true,
    idempotent: true,
    openWorld: true,
    movesAttention: false,
  ),
  // Not idempotent: two opens are two navigations on the app's back stack.
  'device_open_url': McpToolAnnotations(openWorld: true, movesAttention: false),
  // Every setting it changes can be set back, and setting it twice is once.
  'device_set_state': McpToolAnnotations(
    idempotent: true,
    openWorld: true,
    movesAttention: false,
  ),
  // A revoke ends the app's process on both platforms.
  'device_app_permission': McpToolAnnotations(
    destructive: true,
    idempotent: true,
    openWorld: true,
    movesAttention: false,
  ),
  'device_clear_app_data': McpToolAnnotations(
    destructive: true,
    idempotent: true,
    openWorld: true,
    movesAttention: false,
  ),

  // Browser. The page is someone's real logged-in session.
  'browser_find': McpToolAnnotations.readOutside,
  'browser_screenshot': McpToolAnnotations.readOutside,
  // Not read-only: the page is laid out at each width and the window's own
  // size put back, which a page listening for resizes does see.
  'browser_screenshot_sizes': McpToolAnnotations(
    openWorld: true,
    idempotent: true,
    movesAttention: false,
  ),
  'browser_capture': McpToolAnnotations.readOutside,
  // Reads a click out of a person: it fronts their Chrome and blocks for
  // up to two minutes — read-only and the most interrupting tool here.
  'browser_pick': McpToolAnnotations(
    readOnly: true,
    idempotent: true,
    openWorld: true,
    movesAttention: true,
  ),
  // Attaches to a Chrome already listening, and **launches one** when none
  // is. `browser_navigate` inherits that: it connects first when detached.
  'browser_connect': McpToolAnnotations(
    idempotent: true,
    openWorld: true,
    movesAttention: true,
  ),
  'browser_navigate': McpToolAnnotations(
    idempotent: true,
    openWorld: true,
    movesAttention: true,
  ),
  // `open` puts a new tab in front in the person's own browser.
  'browser_tabs': McpToolAnnotations(openWorld: true, movesAttention: true),
  'browser_fill': McpToolAnnotations(
    idempotent: true,
    openWorld: true,
    movesAttention: false,
  ),
  'browser_type': McpToolAnnotations(openWorld: true, movesAttention: false),
  'browser_click': McpToolAnnotations(
    destructive: true,
    openWorld: true,
    movesAttention: false,
  ),
  'browser_key': McpToolAnnotations(
    destructive: true,
    openWorld: true,
    movesAttention: false,
  ),
  'browser_evaluate': McpToolAnnotations(
    destructive: true,
    openWorld: true,
    movesAttention: false,
  ),
  // Reads the DOM with Karmashala's own script; `reload` reloads the page,
  // which is why it is not read-only.
  'browser_audit': McpToolAnnotations(openWorld: true, movesAttention: false),

  // Open-world for the same reason the device tools are: the app is a
  // process on a desktop, a phone or a simulator.
  'flutter_apps': McpToolAnnotations.read,
  'flutter_logs': McpToolAnnotations.readOutside,
  // Puts the app into Flutter's widget-select mode and back; the developer's
  // taps stop doing what taps do for up to ten minutes.
  'flutter_pick_widget': McpToolAnnotations(
    readOnly: true,
    idempotent: true,
    openWorld: true,
    movesAttention: true,
  ),
  // Attaching twice to the same app is the same as attaching once.
  'flutter_attach': McpToolAnnotations(
    idempotent: true,
    openWorld: true,
    movesAttention: false,
  ),
  // `fullRestart` re-runs main() and the app loses its state, with no
  // undo; the annotation describes the worse of the two arguments.
  'flutter_reload': McpToolAnnotations(
    destructive: true,
    openWorld: true,
    movesAttention: false,
  ),
  // `stop` ends a running app and anything unsaved goes with it, and the
  // annotation describes the worst action a caller can pass.
  'flutter_run': McpToolAnnotations(
    destructive: true,
    openWorld: true,
    movesAttention: true,
  ),
  'flutter_run_configs': McpToolAnnotations.read,
  // A save replaces a configuration of the same name wholesale and a delete
  // has no undo; both leave the same rows when repeated.
  'flutter_run_config': McpToolAnnotations(
    destructive: true,
    idempotent: true,
    movesAttention: false,
  ),
  // A build overwrites the artifact with no undo and resolves dependencies
  // from the network; only "build" opens and focuses a tab.
  'project_build': McpToolAnnotations(
    destructive: true,
    idempotent: true,
    openWorld: true,
    movesAttention: true,
  ),

  // Verification runs.
  // Runs the user's own configured commands in panes it opens; each run is a
  // new record, so not idempotent.
  'checks_run': McpToolAnnotations(movesAttention: true),
  'checks_results': McpToolAnnotations.read,
  'verification_list': McpToolAnnotations.read,
  'verification_get': McpToolAnnotations.read,
  // A `url` run connects a browser before it records anything, which lands
  // on `browser_connect`'s launch path; a diff run touches neither.
  'verification_start': McpToolAnnotations(movesAttention: true),
  'verification_note': McpToolAnnotations(movesAttention: false),
  // Writes the report and the evidence; it opens no pane to show them.
  'verification_finish': McpToolAnnotations(movesAttention: false),

  // App stores. None changes a listing, release or review; the two that can
  // read the stores themselves reach Apple and Google.
  'store_apps': McpToolAnnotations.readOutside,
  'store_app': McpToolAnnotations.read,
  'store_reviews': McpToolAnnotations.read,
  'store_refresh': McpToolAnnotations.readOutside,
};

/// The families the tools are shown in, in the order Settings draws them. A
/// fixed set, not a name prefix: `list_devices` and `get_usage` defeat prefixes.
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
  appProjects(
    'App projects',
    'What a checkout is, and the artifact its own toolchain builds.',
  ),
  stores(
    'App stores',
    'How each app is doing on the App Store and Google Play, read-only.',
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

/// One tool as a person reads it — prose for whoever opens Settings, where
/// [McpToolAnnotations] is the hints a *client* acts on.
class McpToolListing {
  const McpToolListing(this.category, this.summary);

  final McpToolCategory category;

  /// One line, compressed from the tool's own schema description. Never
  /// invented: if the schema does not say it, this does not either.
  final String summary;

  /// The cap `mcp_tool_catalogue_test` enforces; past it the settings line
  /// wraps and stops being something an eye can skip down.
  static const int summaryLimit = 80;
}

/// Every served tool, in its family, in one line. Grouped rather than kept in
/// [kMcpToolAnnotations]'s order, so a mis-filed tool is visible at a glance.
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
  'session_search': McpToolListing(
    McpToolCategory.sessions,
    'Search what was said in every conversation; a session per result.',
  ),
  'open_new_session': McpToolListing(
    McpToolCategory.sessions,
    'Start a new agent session in a project, as a tab in Karmashala.',
  ),
  'subagent_run': McpToolListing(
    McpToolCategory.sessions,
    'Run a subagent on any agent and model; get its answer, then it ends.',
  ),
  'delegation_capabilities': McpToolListing(
    McpToolCategory.sessions,
    'The agents and models you can delegate to, and whether you still may.',
  ),
  'delegations': McpToolListing(
    McpToolCategory.sessions,
    'The sessions you started and where each stands, without polling.',
  ),
  'delegation_set_report': McpToolListing(
    McpToolCategory.sessions,
    'Change what you hear of a session you started: final, each turn, none.',
  ),
  'report_to_parent': McpToolListing(
    McpToolCategory.sessions,
    'Tell the session that started yours you are done, blocked or need it.',
  ),
  'open_session': McpToolListing(
    McpToolCategory.sessions,
    'Reattach to a session or resume it; an imported one opens a window.',
  ),
  'session_transcript': McpToolListing(
    McpToolCategory.sessions,
    'What a session has said: its recorded turns and its current screen.',
  ),
  'session_send': McpToolListing(
    McpToolCategory.sessions,
    'Send a message to a session; queued at the server while it works.',
  ),
  'session_draft': McpToolListing(
    McpToolCategory.sessions,
    'Put a message in a session\'s message box for the person to send.',
  ),
  'session_wait': McpToolListing(
    McpToolCategory.sessions,
    'Block until a session settles — finished, blocked on a person, or ended.',
  ),
  'session_answer': McpToolListing(
    McpToolCategory.sessions,
    'Approve or deny a session\'s on-screen prompt — a menu by its yes/no option.',
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
  'session_fork_from_checkpoint': McpToolListing(
    McpToolCategory.sessions,
    'Fork a session and roll its files back to a checkpoint; not its '
    'conversation.',
  ),
  'get_usage': McpToolListing(
    McpToolCategory.sessions,
    'An agent\'s usage against its limit, where the agent reports one.',
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
  'terminal_ports': McpToolListing(
    McpToolCategory.terminals,
    'The ports dev servers started in Karmashala\'s panes listen on.',
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
  'project_add': McpToolListing(
    McpToolCategory.workspace,
    'Add a project: adopt a folder, or clone a repository into one.',
  ),
  'project_update': McpToolListing(
    McpToolCategory.workspace,
    'Rename a project, move its root folder, or set its default checkout.',
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
  'github_runs': McpToolListing(
    McpToolCategory.workspace,
    'The newest GitHub Actions runs on a checkout\'s branch, through gh.',
  ),
  'github_run_log': McpToolListing(
    McpToolCategory.workspace,
    'A failed Actions run\'s log: its last 300 lines and its error lines.',
  ),
  'worktree_create': McpToolListing(
    McpToolCategory.workspace,
    'Add a git worktree on a new branch, beside the checkout.',
  ),
  'worktree_remove': McpToolListing(
    McpToolCategory.workspace,
    'Delete a worktree — only when it is clean, merged and pushed.',
  ),
  'session_checkout_attach': McpToolListing(
    McpToolCategory.workspace,
    'Attach a checkout — or a new worktree of one — to a session.',
  ),
  'session_checkout_detach': McpToolListing(
    McpToolCategory.workspace,
    'Detach an additional checkout from a session; nothing on disk changes.',
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
  'checkpoint_screenshot': McpToolListing(
    McpToolCategory.checkpoints,
    'File a browser or device screenshot against a checkpoint, at set widths.',
  ),
  'checkpoint_screenshots': McpToolListing(
    McpToolCategory.checkpoints,
    'The screenshots filed against a checkpoint or a session.',
  ),
  'checkpoint_screenshot_compare': McpToolListing(
    McpToolCategory.checkpoints,
    'Two checkpoints\' screenshots compared: changed-pixel percent and a diff.',
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
  'checks_run': McpToolListing(
    McpToolCategory.verification,
    "Run the repository's configured checks and record each exit code.",
  ),
  'checks_results': McpToolListing(
    McpToolCategory.verification,
    'Parsed diagnostics and test results, and what this session broke.',
  ),
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
    // The ninth claiming tool: it claims after the already-stopped early
    // return, so it is missing from the driver's call sites.
    'Shut down a running emulator or simulator. One session drives at a time.',
  ),
  // The eight tools below take the device for their caller: a second session's
  // call is refused by name while somebody is driving. Reads are not.
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
  'device_open_url': McpToolListing(
    McpToolCategory.devices,
    'Open a link or deep link on a device. One session drives at a time.',
  ),
  'device_set_state': McpToolListing(
    McpToolCategory.devices,
    'Set appearance, font scale, locale, rotation or network on a device.',
  ),
  'device_app_permission': McpToolListing(
    McpToolCategory.devices,
    'Grant or revoke an app\'s permission; a revoke ends the app.',
  ),
  'device_clear_app_data': McpToolListing(
    McpToolCategory.devices,
    'Wipe an Android app back to first launch. No undo.',
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
  // The one device tool with a refusal of its own: it re-reads the screen first,
  // so a coordinate from a hierarchy that has since moved does not go out.
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
  'browser_screenshot_sizes': McpToolListing(
    McpToolCategory.browser,
    'See the page at compact, medium and expanded widths in one call.',
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
  'browser_audit': McpToolListing(
    McpToolCategory.browser,
    'Accessibility and quality checks of the page; evaluate\'s grant.',
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
  'flutter_run_configs': McpToolListing(
    McpToolCategory.flutterApps,
    'Named run setups: flavor, entrypoint, defines, build mode, device.',
  ),
  'flutter_run_config': McpToolListing(
    McpToolCategory.flutterApps,
    'Save or delete a named run setup; a save replaces it whole.',
  ),
  'project_build': McpToolListing(
    McpToolCategory.appProjects,
    'What a checkout is, and the artifact its own toolchain builds.',
  ),

  // App stores.
  'store_apps': McpToolListing(
    McpToolCategory.stores,
    'Every app on both stores: live version, releases in flight, rating, vitals.',
  ),
  'store_app': McpToolListing(
    McpToolCategory.stores,
    'One app in full: releases per track, rating, vitals, downloads per day.',
  ),
  'store_reviews': McpToolListing(
    McpToolCategory.stores,
    'An app\'s store reviews, newest first, by rating or unanswered only.',
  ),
  'store_refresh': McpToolListing(
    McpToolCategory.stores,
    'Read the App Store and Google Play again; takes tens of seconds.',
  ),

  // Guides.
  'instructions': McpToolListing(
    McpToolCategory.guides,
    'Karmashala\'s operating guides, one topic at a time.',
  ),
};

/// [kMcpToolListings] grouped for display, in category order. A lazy top-level
/// `final`: nothing computes it until a page asks, and nothing computes it twice.
final Map<McpToolCategory, List<String>> kMcpToolsByCategory =
    <McpToolCategory, List<String>>{
      for (final category in McpToolCategory.values)
        category: <String>[
          for (final entry in kMcpToolListings.entries)
            if (entry.value.category == category) entry.key,
        ],
    };

/// The served tool list: each schema with its annotations attached. Merged here
/// because the bespoke `/rpc` envelope has no field to put them in.
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
