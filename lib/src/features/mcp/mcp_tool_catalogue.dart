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

      // Sessions.
      'list_sessions': McpToolAnnotations.read,
      'list_agents': McpToolAnnotations.read,
      'get_usage': McpToolAnnotations.read,
      'open_new_session': McpToolAnnotations(),
      // Reveals a session that is already running, or resumes one that is not.
      // Twice is once, either way.
      'open_session': McpToolAnnotations(idempotent: true),
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

      // Fan-out.
      'fanout_list': McpToolAnnotations.read,
      'fanout_get': McpToolAnnotations.read,

      // Devices. Everything here touches a phone, so all of it is open-world.
      'list_devices': McpToolAnnotations.readOutside,
      'device_screenshot': McpToolAnnotations.readOutside,
      'device_logcat': McpToolAnnotations.readOutside,
      'device_ui_dump': McpToolAnnotations.readOutside,
      'device_find_elements': McpToolAnnotations.readOutside,
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
