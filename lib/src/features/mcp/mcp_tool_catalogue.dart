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
/// ## What the five axes mean, decided once
///
/// The spec defines its four loosely enough that a table can drift into wishful
/// thinking, so this file uses one rule per axis and applies it everywhere:
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
/// * **`movesAttention`** — running it changes what the person is looking at:
///   a window raised or created, the tab, pane or selection on screen switched,
///   or the tool stopping to ask them to point at something. Ours, not the
///   spec's. It is **orthogonal to the other four** and that is the whole
///   point: `open_session` changes nothing and moves everything, `note_add`
///   changes something and moves nothing.
///
/// The fifth axis needed two boundaries drawn, because without them it either
/// marks nothing or marks everything:
///
/// * **Driving a surface the caller was pointed at is not moving attention.**
///   Tapping a phone, scrolling a page into view, typing into the pane the
///   caller named — the person handed that surface over, and the agent working
///   inside it is the job rather than an interruption. What is not the job is a
///   new window, the front-most window changing, this app's own selection
///   moving under them, or being asked to click something.
/// * **A tool whose payload is the caller's own command describes the
///   delivery, not the payload.** `terminal_run`, `snippet_insert` and
///   `browser_evaluate` all carry something a caller wrote that could open
///   anything; they are marked `destructiveHint` for exactly that reason, and
///   deliberately not marked here. A hint that reads "possibly" on every one of
///   them tells a client nothing it can act on.
///
/// These are **hints**, and the spec says clients must treat them as untrusted.
/// Nothing here is enforcement. What actually keeps a destructive call from
/// happening by accident is that it is its own tool with its own required
/// arguments, never a flag on a read.
///
/// ## What is never served here at all
///
/// **No automation tool.** Scheduled automations have no `automation_*` tool
/// and never will: create, run, pause and delete would let an agent schedule
/// an agent, and the invariant the whole feature is built on is that *nothing
/// starts an agent the user did not authorise*. An automation is that
/// authorisation, given in advance, **by a person, in the UI, at arming** — a
/// tool that could arm one would be the same act with the person taken out of
/// it. `automations_page.dart` is the only place it happens, and
/// `no_automation_tools_test.dart` fails if any served name so much as begins
/// with `automation`.
///
/// This is a rule about the surface, not a fifth annotation. Reading an
/// automation's record is not carved out either — a read tool would be the
/// obvious next step and it is not one taken here, because the argument above
/// is about the family, and the day a read is wanted it should be argued for
/// on its own.
///
/// It is the same question `movesAttention` answers, asked one step earlier.
/// Arming an automation is a person deciding, in the UI, that something may
/// start without them; a tool that could arm one would take the person out of
/// their own decision, so there is no such tool. A tool that takes their
/// *screen* is allowed — a person asked for the agent, and showing them what it
/// is talking about is often the point — but it has to say so. **Arming is
/// never a tool, and a tool that moves attention says so.**
library;

/// The behaviour of one tool, as `tools/list` reports it.
class McpToolAnnotations {
  /// [movesAttention] is required and the other four are not, because the four
  /// are the spec's and their defaults are its defaults, while this one is
  /// ours and has no answer until somebody reads the implementation.
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

  /// Running it changes what the person is looking at. See the fifth rule at
  /// the top of this file.
  final bool movesAttention;

  Map<String, Object?> toJson() => <String, Object?>{
    'readOnlyHint': readOnly,
    // Only meaningful when the tool is not read-only, and the spec's default is
    // `true` — so it is always written out rather than left to a default a
    // reader would have to remember.
    'destructiveHint': destructive,
    'idempotentHint': idempotent,
    'openWorldHint': openWorld,
    // Not one of the spec's four. It travels with them because the reader it
    // is written for is the same one: a client deciding whether to run this
    // over a list. A client that does not know the key ignores it, which is
    // the same thing it would do with no key at all.
    'movesAttentionHint': movesAttention,
  };
}

/// Every tool this app serves, and what it does.
///
/// A tool missing from here is a bug, not a default: `mcp_tool_catalogue_test`
/// asserts this map and the served schemas name exactly the same set, so a new
/// tool cannot ship without someone deciding whether it can be undone — and,
/// since `movesAttention` has no default to fall through to, whether it takes
/// the person's screen with it.
const Map<String, McpToolAnnotations> kMcpToolAnnotations =
    <String, McpToolAnnotations>{
      // The guides. Reads a table compiled into the binary; touches nothing.
      'instructions': McpToolAnnotations.read,

      // Checkpoints — a per-turn record of the working tree.
      'checkpoint_list': McpToolAnnotations.read,
      'checkpoint_diff': McpToolAnnotations.read,
      'checkpoint_capture': McpToolAnnotations(movesAttention: false),
      // Overwrites the working tree with an older one. The only tool here that
      // can throw away work nobody recorded anywhere else.
      'checkpoint_restore': McpToolAnnotations(
        destructive: true,
        movesAttention: false,
      ),

      // Workspace.
      'list_projects': McpToolAnnotations.read,
      'list_checkouts': McpToolAnnotations.read,
      'delivery_status': McpToolAnnotations.read,
      // Reads the directory and records what it finds. Running it twice over
      // an unchanged directory changes nothing the first run did not.
      'project_rescan': McpToolAnnotations(
        idempotent: true,
        movesAttention: false,
      ),
      // Through the same `CheckoutPicker` the side panel's own picker calls, so
      // the Explorer, the diff view and the side panel all repoint.
      'select_checkout': McpToolAnnotations(
        idempotent: true,
        movesAttention: true,
      ),
      // Makes a directory and a branch. Not idempotent: the second call finds
      // its own first call in the way and is refused.
      'worktree_create': McpToolAnnotations(movesAttention: false),
      // Deletes a working tree. The one tool here that can take a directory
      // away, which is why it refuses on anything it cannot read.
      'worktree_remove': McpToolAnnotations(
        destructive: true,
        movesAttention: false,
      ),

      // Sessions.
      'list_sessions': McpToolAnnotations.read,
      'list_agents': McpToolAnnotations.read,
      'get_usage': McpToolAnnotations.read,
      // Lands in a pane by default, and `openAgentTab` makes that the active
      // tab and focuses it — whatever the person was reading is now behind it.
      'open_new_session': McpToolAnnotations(movesAttention: true),
      // Reveals a session that is already running, or resumes one that is not
      // — and for an *imported* CLI session, opens an external terminal window
      // to resume it in. Twice is twice on that branch: a second call opens a
      // second window, and nothing in this surface closes one. It was annotated
      // idempotent, which is the hint a client reads before deciding it is safe
      // to repeat or to run over a list, and a driver walking `list_sessions`
      // opened a window per row on the owner's desktop. That incident is the
      // reason the fifth axis exists: revealing is all this tool does, and it
      // was the one thing the annotations could not say.
      'open_session': McpToolAnnotations(movesAttention: true),
      'session_transcript': McpToolAnnotations.read,
      // Watches, and changes nothing. Idempotent in the sense this file means —
      // the same call twice leaves the same state — even though the two answers
      // may differ, because that difference is the session moving rather than
      // this tool doing anything. Calling it again after a timeout is not
      // merely safe, it is the intended response to one.
      'session_wait': McpToolAnnotations.read,
      // Text appears in the target's pane and nothing else moves: no tab is
      // switched, no pane focused, and `wait` blocks the caller, not a person.
      'session_send': McpToolAnnotations(movesAttention: false),
      // Presses the agent's own approve/deny key. Approving is granting
      // permission for something that then happens, and nothing un-happens it.
      // A close call on the fifth axis: it makes a prompt the person might have
      // wanted disappear from a pane they may be watching. That is a screen
      // changing under them, not their attention being taken somewhere.
      'session_answer': McpToolAnnotations(
        destructive: true,
        movesAttention: false,
      ),
      'session_rename': McpToolAnnotations(
        idempotent: true,
        movesAttention: false,
      ),
      // Ends the agent process. The transcript survives; the turn in flight
      // does not, and nothing brings it back. It moves attention by taking
      // something away rather than putting something in front: closing the last
      // pane of a tab hands the active tab and the keyboard to another one.
      'session_end': McpToolAnnotations(
        destructive: true,
        movesAttention: true,
      ),
      // Both continue the work in a newly launched session, which arrives as a
      // focused tab. `preview: true` is a read on either — and the annotation
      // describes the worst, as `terminal_close`'s does.
      'session_handoff': McpToolAnnotations(movesAttention: true),
      'session_fork': McpToolAnnotations(movesAttention: true),
      // Spawns an external terminal window running the generated tmux script.
      'open_sessions_in_tmux': McpToolAnnotations(movesAttention: true),

      // Terminal.
      'terminal_list': McpToolAnnotations.read,
      'terminal_output': McpToolAnnotations.read,
      // Three moves in one call: the new tab becomes active, its group is
      // activated, and its pane is given the keyboard.
      'terminal_open': McpToolAnnotations(movesAttention: true),
      // Types a command the caller composed into a live shell. Whether that is
      // destructive is the command's business, not this tool's, and a tool that
      // cannot tell must not claim it is safe. The fifth axis goes the other
      // way for the same reason — see the second boundary at the top: this
      // types into the pane the caller named and moves nothing itself.
      'terminal_run': McpToolAnnotations(
        destructive: true,
        movesAttention: false,
      ),
      // Detaches by default and can be told to kill. The annotation describes
      // the worst it does, because a client deciding whether to confirm cannot
      // see which argument was passed. Closing the tab in front reassigns the
      // active one, and the keyboard follows it.
      'terminal_close': McpToolAnnotations(
        destructive: true,
        movesAttention: true,
      ),

      // Recording. None of it is destructive — a recording writes a new file
      // and takes nothing away — but none of it is read-only either: it turns
      // capture on, and what it captures is whatever is on screen.
      'terminal_record_start': McpToolAnnotations(movesAttention: false),
      'terminal_record_stop': McpToolAnnotations(movesAttention: false),
      // Reads a phone, writes this computer, the way `device_file_pull` does.
      // It cannot open the device pane: it records the live view's own frames
      // and refuses when there is none, so it needs the person to have gone
      // there first — the opposite of moving them.
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
      // Appends a row to the user's own library. Not idempotent: twice is two
      // snippets.
      'snippet_add': McpToolAnnotations(movesAttention: false),
      // Types a saved command into a live shell. Read-only it is not, and the
      // annotation describes the worst it does — the same rule `terminal_close`
      // states: a snippet the user saved with submit=true runs on insertion,
      // and a client deciding whether to confirm cannot see which one this is.
      // The closest call on the fifth axis: it parks a command at a live prompt
      // for the person to press enter on. But it switches nothing — it types
      // where the caller pointed, which by default is the pane they are already
      // in — so what it does is put words in front of them, not move them.
      'snippet_insert': McpToolAnnotations(
        destructive: true,
        movesAttention: false,
      ),
      // Todos: the one list a person and an agent both write to.
      'todos_list': McpToolAnnotations.read,
      'todo_add': McpToolAnnotations(movesAttention: false),
      // Sets one field and only that field. Idempotent — finishing a finished
      // todo leaves the same todo. **Not** destructive: the row is still there
      // afterwards, and `done: false` puts it back, which is exactly the undo
      // `destructiveHint` says does not exist. Same call as
      // `review_thread_status`.
      'todo_done': McpToolAnnotations(idempotent: true, movesAttention: false),
      'todo_delete': McpToolAnnotations(
        destructive: true,
        movesAttention: false,
      ),

      // Notes and the inbox.
      'notes_list': McpToolAnnotations.read,
      'inbox_list': McpToolAnnotations.read,
      'note_add': McpToolAnnotations(movesAttention: false),
      'note_delete': McpToolAnnotations(
        destructive: true,
        movesAttention: false,
      ),
      // Changes nothing but which session is on screen: `focusWatchedSession`
      // rewrites the selected project, repository and session together — the
      // clearest case there is for an axis of its own.
      'inbox_open': McpToolAnnotations(idempotent: true, movesAttention: true),
      // An item for an event is gone for good; one for a condition that still
      // holds is re-filed by the next poll. The annotation describes the worse
      // of the two, because the caller cannot know which it has.
      'inbox_dismiss': McpToolAnnotations(
        destructive: true,
        idempotent: true,
        movesAttention: false,
      ),

      // The decision record. Appends a row nothing can edit or remove, which
      // is not idempotent — a second identical call is a second decision, and
      // the record's job is to say that it was made twice.
      'decision_record': McpToolAnnotations(movesAttention: false),

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
      'review_thread_add': McpToolAnnotations(movesAttention: false),
      // Appends to a thread. Append-only, so not idempotent and not
      // destructive: nothing already said can be edited or taken back by it.
      'review_thread_reply': McpToolAnnotations(movesAttention: false),
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
      // Reading the device, writing this computer — so not `readOnly`, even
      // though nothing on the phone changes.
      'device_file_pull': McpToolAnnotations(
        openWorld: true,
        movesAttention: false,
      ),
      // Writing someone's device. Not marked destructive because it refuses
      // rather than replacing unless `overwrite` is asked for, and a new file
      // where there was none is not a loss — but `overwrite: true` is a
      // deliberate one, which is why it has to be asked for by name.
      'device_file_push': McpToolAnnotations(
        openWorld: true,
        movesAttention: false,
      ),
      // A tap lands wherever it lands. On someone's own phone that includes
      // "confirm delete", and there is no undo on the other side of the wire.
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
      // Starting something is not destructive — see the rule at the top of this
      // file — and asking twice for a device that is already up leaves it up,
      // which is what idempotent means here. The one device tool that reaches
      // back into this app: booting a simulator selects it in the device pane's
      // picker, and unless the person turned headless on it also runs
      // `open -a Simulator`, which is a window. The Android path never does
      // either, and the annotation describes the worse of the two platforms.
      'device_boot': McpToolAnnotations(
        idempotent: true,
        openWorld: true,
        movesAttention: true,
      ),
      // Overwrites whatever build of the same app was on the device, with no
      // undo: the previous binary is gone. Idempotent because installing the
      // same artifact twice leaves the same device.
      'device_install_app': McpToolAnnotations(
        destructive: true,
        idempotent: true,
        openWorld: true,
        movesAttention: false,
      ),
      // A launch runs somebody's code on a device. Not idempotent: launching
      // twice is two starts, and with relaunch it is two *cold* starts, which
      // is a different device state from one.
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

      // Browser. The page is someone's real logged-in session, so the same
      // reasoning as devices applies to anything that acts on it.
      'browser_find': McpToolAnnotations.readOutside,
      'browser_screenshot': McpToolAnnotations.readOutside,
      'browser_capture': McpToolAnnotations.readOutside,
      // Reads a click out of a person. It fronts their Chrome and then blocks
      // for up to two minutes waiting for them — read-only and the most
      // interrupting tool in the table: the pair the fifth axis exists for.
      'browser_pick': McpToolAnnotations(
        readOnly: true,
        idempotent: true,
        openWorld: true,
        movesAttention: true,
      ),
      // Attaches to a Chrome that is already listening, and **launches one**
      // when none is: a new, visible window. `browser_navigate` inherits it,
      // because it connects first when nothing is attached.
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
      // `open` puts a new tab in front in the person's own browser. Nothing
      // here activates it; Chrome does, and the result is the same for them.
      'browser_tabs': McpToolAnnotations(
        openWorld: true,
        movesAttention: true,
      ),
      'browser_fill': McpToolAnnotations(
        idempotent: true,
        openWorld: true,
        movesAttention: false,
      ),
      'browser_type': McpToolAnnotations(
        openWorld: true,
        movesAttention: false,
      ),
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

      // The Flutter app the developer is running. Open-world for the same
      // reason the device tools are: the app is a process on a desktop, a
      // phone or a simulator, and not this machine's repositories.
      'flutter_apps': McpToolAnnotations.read,
      'flutter_logs': McpToolAnnotations.readOutside,
      // Reads what the developer points at. It puts the app into Flutter's own
      // widget-select mode and takes it back out; nothing in the app is
      // changed by the round trip. Their taps stop doing what taps do while it
      // waits, for up to ten minutes: `browser_pick`'s twin, minus the part
      // that fronts the window they are meant to be looking at.
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
      // Destructive because `fullRestart` re-runs main() and the app loses the
      // state it had — no undo — and the annotation describes the worse case: a
      // client deciding whether to confirm cannot see which argument was
      // passed. Same rule as `terminal_close`.
      'flutter_reload': McpToolAnnotations(
        destructive: true,
        openWorld: true,
        movesAttention: false,
      ),
      // Starts and stops builds, apps and gates. Destructive because `stop`
      // ends a running app and anything it had not saved goes with it, and
      // because the annotation describes the worst the tool does — a client
      // deciding whether to confirm cannot see which action was passed. Not
      // idempotent: two `run`s are two launches, and `pubGet` twice is twice.
      // Open-world for the same reason the device tools are — a launch puts an
      // app on a phone, and a gate is a process on somebody's machine. Every
      // action but `status` runs in a terminal tab it opens and focuses.
      'flutter_run': McpToolAnnotations(
        destructive: true,
        openWorld: true,
        movesAttention: true,
      ),

      // Verification runs.
      'verification_list': McpToolAnnotations.read,
      'verification_get': McpToolAnnotations.read,
      // A `url` run connects a browser before it records anything, which lands
      // on `browser_connect`'s launch path — so starting one can put a Chrome
      // window on the person's screen. A diff run touches neither.
      'verification_start': McpToolAnnotations(movesAttention: true),
      'verification_note': McpToolAnnotations(movesAttention: false),
      // Writes the report and the evidence; it does not open the pane that
      // shows them. Nothing in this family reaches the side panel.
      'verification_finish': McpToolAnnotations(movesAttention: false),
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
