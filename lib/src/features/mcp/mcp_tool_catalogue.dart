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
