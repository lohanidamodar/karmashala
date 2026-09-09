import '../../settings/domain/permission_risk.dart';
import 'agent_descriptor.dart';
import 'agent_kind.dart';
import 'agent_plan.dart';
import 'agent_permission_support.dart';
import 'agent_skill_support.dart';
import 'agent_status.dart';

/// The agents Karmashala ships knowledge of.
///
/// This list is **data**: everything the app needs to find, launch and observe
/// these agents is here rather than spread through discovery, store location
/// and terminal code. The three entries also have protocol adapters, which is
/// why each carries an [AgentKind]; a fourth agent added here without one is
/// discovered, persisted, listed and openable just the same — it simply gets
/// the generic adapter and no rich chat.
///
/// Order matters: it is the order agents are probed and listed in.
const List<AgentDescriptor> builtInAgentDescriptors = [
  _claudeCode,
  _codex,
  _antigravity,
];

const _claudeCode = AgentDescriptor(
  id: 'claudeCode',
  displayName: 'Claude Code',
  kind: AgentKind.claudeCode,
  // `%USERPROFILE%\.local\bin\claude.exe` is where Claude Code's own native
  // Windows installer puts the binary. It is listed because on the machine this
  // was reported from that file exists and that directory is on neither the
  // user nor the machine PATH, so `where claude` returns "Could not find files
  // for the given pattern(s)" and the Windows installation is invisible.
  binaries: AgentBinaries(
    windows: ['claude'],
    posix: ['claude'],
    windowsInstallPaths: [r'%USERPROFILE%\.local\bin\claude.exe'],
  ),
  launch: AgentLaunchSpec(
    baseArguments: [
      '--input-format',
      'stream-json',
      '--output-format',
      'stream-json',
      '--verbose',
    ],
    // Claude Code has **six** permission modes, not three, and the CLI enforces
    // the list at parse time — so this is the whole set rather than a sample.
    //
    //   $ claude --permission-mode bogus --help
    //   error: option '--permission-mode <mode>' argument 'bogus' is invalid.
    //     Allowed choices are acceptEdits, auto, bypassPermissions, manual,
    //     dontAsk, plan.
    //
    // Identical on both installations on this machine: 2.1.245 (the Windows
    // `.local\bin\claude.exe`) and 2.1.259 (the WSL one). Each description
    // below is the binary's own label for that mode, read out of 2.1.245's
    // string table where the six sit as consecutive strings.
    permission: AgentPermissionSupport.axes(
      evidence:
          'claude --permission-mode bogus --help on 2.1.245 and 2.1.259: '
          '"Allowed choices are acceptEdits, auto, bypassPermissions, manual, '
          'dontAsk, plan"; descriptions from the 2.1.245 mode-cycler string '
          'table',
      legacyAliases: {
        'ask': 'mode=manual',
        'acceptEdits': 'mode=acceptEdits',
        'bypass': 'mode=bypassPermissions',
      },
      axes: [
        AgentPermissionAxis(
          id: 'mode',
          label: 'Permission mode',
          description: 'How much Claude Code may do without asking.',
          defaultValueId: 'manual',
          values: [
            AgentPermissionValue(
              id: 'plan',
              label: 'Plan mode',
              shortLabel: 'Plan',
              description:
                  'Research and propose changes without making them.',
              arguments: ['--permission-mode', 'plan'],
              permits: PermissionRisk.readOnly,
              evidence:
                  '2.1.245 string table: "plan mode (research and propose '
                  'changes without making them)"',
            ),
            AgentPermissionValue(
              id: 'dontAsk',
              label: "Don't ask",
              shortLabel: "Don't ask",
              description: 'Auto-deny anything that would prompt.',
              arguments: ['--permission-mode', 'dontAsk'],
              permits: PermissionRisk.readOnly,
              evidence:
                  '2.1.245 string table: "don\'t ask (auto-deny anything that '
                  'would prompt)"; the binary also classifies it as '
                  '"restricts" beside permissions.defaultMode',
            ),
            AgentPermissionValue(
              id: 'manual',
              label: 'Ask every time',
              shortLabel: 'Ask',
              description: 'Ask each time, before edits and commands.',
              arguments: ['--permission-mode', 'manual'],
              permits: PermissionRisk.ask,
              evidence:
                  '2.1.245 string table: "default (ask each time)". `manual` '
                  'is the flag spelling of the config value `default`. Passing '
                  'no flag is NOT this: 2.1.228+ starts Pro/Max/Team sessions '
                  'in `auto`.',
            ),
            AgentPermissionValue(
              id: 'acceptEdits',
              label: 'Accept edits',
              shortLabel: 'Accept edits',
              description:
                  'Auto-approve file edits and common file commands.',
              arguments: ['--permission-mode', 'acceptEdits'],
              permits: PermissionRisk.acceptEdits,
              evidence:
                  '2.1.245 string table: "accept edits (auto-approve file '
                  'edits and common file commands)"',
            ),
            AgentPermissionValue(
              id: 'auto',
              label: 'Automatic',
              shortLabel: 'Automatic',
              description:
                  'No routine prompts; a reviewer model screens actions.',
              arguments: ['--permission-mode', 'auto'],
              permits: PermissionRisk.autoRun,
              evidence:
                  '2.1.245 string table: "auto (no routine prompts; a '
                  'reviewer model screens actions)"',
            ),
            AgentPermissionValue(
              id: 'bypassPermissions',
              label: 'Bypass (full autonomy)',
              shortLabel: 'Bypass',
              description: 'No further prompts of any kind.',
              arguments: ['--permission-mode', 'bypassPermissions'],
              permits: PermissionRisk.bypass,
              isDangerous: true,
              evidence:
                  '2.1.245 string table: "BYPASS PERMISSIONS (no further '
                  'prompts)"; the binary classifies it as "bypass"',
            ),
          ],
        ),
      ],
    ),
    resume: AgentResume.flag('--resume'),
    interactiveResume: AgentResume.flag('--resume'),
    // **The store is cwd-keyed and the resume is not**, and the gap between
    // those two sentences is the whole of this entry.
    //
    // The store really is keyed by the launch directory: a transcript is
    // written to `<config>/projects/<key>/<id>.jsonl` where the key is the
    // process's own project root put through `e.replace(/[^a-zA-Z0-9]/g,"-")`
    // (truncated at 200 characters plus a hash). Read out of the 2.1.258
    // binary — `function k(e){return e.replace(/[^a-zA-Z0-9]/g,"-")}`, wrapped
    // by `WA`, joined in `Yo`'s `transcript` case — and confirmed against the
    // owner's own store, where all eight top-level buckets are exactly that
    // encoding of the `cwd` recorded inside their files (`G:\dev\godot\
    // sampada_trails` → `G--dev-godot-sampada-trails`, underscore included).
    //
    // cmux stops there and concludes that a resume from elsewhere "fails with
    // 'No conversation found'". It does not, because the CLI does not stop
    // there either. `--resume <id>` resolves through three lookups in order:
    // the cwd-keyed path, then a **git-worktree fallback** that runs
    // `git worktree list --porcelain` in the launch directory and tries every
    // sibling worktree's bucket, then a **full id scan** of every top-level
    // bucket that accepts the file when exactly one bucket holds it and it
    // contains at least one user or assistant line. The two fallbacks announce
    // themselves in the binary's own telemetry names,
    // `tengu_resume_worktree_fallback` and `tengu_transcript_id_scan_fallback`,
    // and both are present in 2.1.252, 2.1.257, 2.1.258 and the Windows
    // `claude.exe` this machine launches. Both lanes reach them: the TTY resume
    // and the `stream-json` one both call the loader with no explicit file.
    //
    // So a resume by id is directory-independent, and `ConversationStoreIndex`
    // already agrees by construction — it scans every project bucket rather
    // than deriving one, which is the same answer the CLI's own scan gives.
    //
    // What is **not** covered by this: `--continue`, which has no id to scan
    // for and is genuinely scoped to the directory. Karmashala never passes it.
    resumeLocality: AgentResumeLocality.anyDirectory(
      evidence:
          'claude 2.1.258 (and the Windows claude.exe): `--resume <id>` falls '
          'back through a git-worktree sweep (tengu_resume_worktree_fallback) '
          'and then a scan of every <config>/projects/* bucket for <id>.jsonl '
          '(tengu_transcript_id_scan_fallback) when the cwd-keyed path misses',
    ),
    // `claude --session-id <uuid>` pins the CLI's session id to one we choose.
    // Karmashala's own session ids are already RFC-4122 v4, so one string is
    // both — which is what makes a PTY-hosted Claude session's transcript
    // locatable at launch instead of guessed at afterwards.
    sessionIdAssignment: AgentSessionIdAssignment.flag('--session-id'),
    prompt: AgentPromptSupport.positional(
      evidence: 'claude --help (2.1.251): "Usage: claude [options] [prompt]"',
    ),
    // **The handoff packet's way in that is not a paste.** Claude Code
    // collapses any paste over 800 characters or three lines into
    // `[Pasted text #N]`, so a packet delivered as text is the difference
    // between the next agent reading the brief and reading a placeholder. A
    // path has no size.
    //
    // Recorded against what the flag *did*, not against what is documented:
    // 2.1.263's option list does not name it, and `--bare`'s own text does.
    systemPromptFile: AgentSystemPromptFileSupport.append(
      '--append-system-prompt-file',
      evidence:
          'claude 2.1.263 (Windows claude.exe): --help names it only inside '
          '--bare\'s text ("Explicitly provide context via: '
          '--system-prompt[-file], --append-system-prompt[-file], …"), and the '
          'flag validates its argument — `--append-system-prompt-file '
          'C:\\kw\\nope-does-not-exist.md -p hi` answers "Error: Append system '
          'prompt file not found: C:\\kw\\nope-does-not-exist.md"',
    ),
    // Verified, not assumed: two panes were given `--resume` on the same
    // session id with the first still live (`integration_test/
    // resume_conflict_test.dart`). The second opened on the same conversation,
    // history and all, and stayed usable. The only thing it declined was its
    // remote control, which it says in a line of its own — "another Claude Code
    // on this machine (started 4s ago) already has Remote Control for this
    // conversation". Nothing about the session itself was refused.
    allowsConcurrentResume: true,
    // Captured from the owner's own pane, verbatim, after the app resumed a
    // session id it had assigned to a conversation Claude never wrote:
    //
    //   No conversation found with session ID: 4b13c55e-ec74-4c0b-ac63-…
    //   [process exited with code 1]
    //
    // The id is dropped from the marker because it is different every time.
    missingConversation: AgentMissingConversationRules(
      markers: [GridMatcher('No conversation found with session ID')],
    ),
    // `--fork-session` is a *modifier on a resume*, not a mode of its own, so
    // the arguments are `--resume <id> --fork-session`. The forked process
    // loads the original's history and writes its own session id from the first
    // turn on, which is precisely what "shares history up to now, then
    // diverges" has to mean for the original to be left alone.
    fork: AgentForkSupport.native(
      resume: AgentResume.flag('--resume'),
      extraArguments: ['--fork-session'],
      evidence:
          'claude 2.1.251 --help: "--fork-session  When resuming, create a new '
          'session ID instead of reusing the original (use with --resume or '
          '--continue)"',
    ),
    // `--mcp-config` **merges** with the user's own servers; it does not
    // replace them. That is the whole reason this is safe to pass on every
    // launch, and it is verified rather than assumed — the sibling flag says
    // so in its own words ("--strict-mcp-config  Only use MCP servers from
    // --mcp-config, ignoring all other MCP configurations"), and a real run
    // shows it:
    //
    //   $ claude --mcp-config=/tmp/c.json --output-format stream-json \
    //       --verbose -p 'Reply with the single word OK'
    //   …"mcp_servers":[{"name":"agent-browser"…},{"name":"dart"…},
    //     {"name":"grafana"…},{"name":"karmashala"…},
    //     {"name":"claude.ai Google Drive"…}]
    //
    // Four of the user's five servers plus ours. `--strict-mcp-config` is
    // therefore never passed: it would silently drop the user's MCP setup for
    // every session Karmashala opens.
    mcp: AgentMcpSupport.configFile(
      flag: '--mcp-config',
      evidence:
          'claude 2.1.251 --help: "--mcp-config <configs...>  Load MCP servers '
          'from JSON files or strings (space-separated)"; merge verified by '
          'the init message above listing our server alongside the four '
          'already configured',
    ),
    // **Both halves verified against 2.1.258, and they are different claims.**
    //
    // The launch flag is the easy one: `--model <model>  Model for the current
    // session. Provide an alias for the latest model (e.g. 'fable', 'opus', or
    // 'sonnet') or a model's full name (e.g. 'claude-fable-5').`
    //
    // The in-session command is the half worth writing down, because a slash
    // command that opens a *picker* and one that takes an argument look alike
    // from outside and only the second can be sent by a program. This one takes
    // an argument, and the bundle says so in its own dispatch:
    //
    //   if(Ne==="/model"||Ne.startsWith("/model ")){ … m.getSnapshot()
    //     .query.trim().slice(6) … }
    //
    // — matched with and without a trailing argument, and the argument read off
    // the query. The CLI's own onboarding names the four: "Run /model to switch
    // models. Fable for the hardest problems, Opus for complex work, Sonnet for
    // most tasks, Haiku for quick questions."
    //
    // The ids are aliases rather than dated model names on purpose. The same
    // bundle carries the allowlist `["sonnet","opus","haiku","fable","best",
    // "sonnet[1m]","opus[1m]","fable[1m]","opusplan"]` and resolves each to the
    // latest build of that family, so an alias cannot go stale the way
    // `claude-opus-4-1` does — and a stale id is a session that comes up on a
    // model the chip is not naming.
    model: AgentModelSupport.liveAndAtLaunch(
      flag: '--model',
      slashCommand: '/model',
      models: [
        AgentModel(
          id: 'fable',
          label: 'Fable',
          summary: 'The hardest problems. Slowest, and the most capable.',
        ),
        AgentModel(id: 'opus', label: 'Opus', summary: 'Complex work.'),
        AgentModel(id: 'sonnet', label: 'Sonnet', summary: 'Most tasks.'),
        AgentModel(
          id: 'haiku',
          label: 'Haiku',
          summary: 'Quick questions. Fastest, and the least capable.',
        ),
      ],
      evidence:
          'claude 2.1.258 --help: "--model <model>  Model for the current '
          'session. Provide an alias for the latest model (e.g. \'fable\', '
          '\'opus\', or \'sonnet\')"; the in-session form from the same '
          'bundle\'s dispatch — `Ne==="/model"||Ne.startsWith("/model ")` with '
          'the argument read off the query; alias list from that bundle\'s '
          '["sonnet","opus","haiku","fable","best",…] allowlist',
    ),
  ),
  store: AgentStoreSpec(
    homeDirectoryName: '.claude',
    format: AgentStoreFormat.claudeJsonl,
  ),
  statusStrategy: AgentStatusStrategy.hooks,
  hooks: AgentHookSpec(
    configFileName: 'settings.json',
    // **Two keys, because Claude Code's prose lives under two names.**
    //
    // `Notification` carries a `message` describing what it wants. It was
    // decoded for the session id and dropped, which is why the app could say an
    // approval was pending and never what for.
    //
    // `Stop`, `StopFailure` and `SubagentStop` carry `last_assistant_message`
    // instead, and 2.1.260's own schema says why it is there: *"Text content of
    // the last assistant message before stopping. Avoids the need to read and
    // parse the transcript file."* That is the answer to "what finished", and
    // reading only `message` meant every completion toast was a session name
    // and nothing else. Captured whole on 2026-09-04 from a real `-p` turn:
    //
    //   {"hook_event_name":"Stop","stop_hook_active":false,
    //    "last_assistant_message":"I ran the echo command, which printed
    //      \"hi\" to the terminal.",
    //    "background_tasks":[],"session_crons":[]}
    //
    // No event carries both, so the order is a fallback and not a precedence.
    messagePaths: [
      ['message'],
      ['last_assistant_message'],
    ],
    // The prose fallback, kept only for a CLI whose payload carries no
    // `notification_type` — see [eventKindMeaning], which is the field this was
    // guessing at.
    messageWaiting: {
      'needs your permission': AgentWaitKind.approval,
      'waiting for your input': AgentWaitKind.input,
    },
    // **`Notification` is not a status.** Claude Code fires it for sixteen
    // unrelated things and says which in a required `notification_type` field.
    // **Re-read against the installed 2.1.260**, whose own allowlist is
    //
    //   ["permission_prompt","idle_prompt","auth_success",
    //    "elicitation_dialog","agent_needs_input","agent_completed",
    //    "elicitation_url_dialog","worker_permission_prompt",
    //    "push_notification","computer_use_enter","computer_use_exit",
    //    "quota_auto_resume_fired","quota_auto_resume_stale",
    //    "quota_auto_resume_disabled"]
    //
    // plus `elicitation_complete` and `elicitation_response`, which the
    // `Notification` event's own `matcherMetadata` appends to it. Six of those
    // are newer than the ten this comment used to list. Messages, off the
    // binary's `notificationType:` call sites and its dialog table:
    //
    //   permission_prompt         "Claude needs your permission to use ${tool}"
    //   worker_permission_prompt  "${worker} needs permission for ${tool}"
    //   idle_prompt               "Claude is waiting for your input"
    //   elicitation_dialog        "Claude Code needs your input"
    //   elicitation_url_dialog    "An MCP server needs your input"
    //   quota_auto_resume_stale   "Usage limit reset — press enter to continue"
    //   quota_auto_resume_disabled  "Automatic continue was turned off — the
    //                               task will not resume on its own"
    //   quota_auto_resume_fired   "Usage limit available — Claude is
    //                               continuing your task"
    //   agent_needs_input         "${label} needs your input"       (fleet)
    //   agent_completed           "${label} finished" / "failed"    (fleet)
    //   auth_success              "Claude Code login successful"
    //   elicitation_complete      "MCP server "X" confirmed elicitation …"
    //   elicitation_response      "Elicitation response for server "X": accept"
    //   computer_use_exit         "Claude is done using your computer"
    //   push_notification         whatever a remote sent
    //
    // Every one of them used to arrive as `awaitingApproval`. What is declared
    // below is what says **this** session is stopped and cannot go on without
    // the user; everything else resolves to `unknown`, which is not recorded
    // and therefore leaves the session saying whatever it last said.
    //
    // **One correction worth keeping.** This comment used to say the two
    // `agent_*` types are about a different session in the roster. That is
    // true of the fleet call sites, and *not* the whole story: 2.1.260's dialog
    // table also raises `agent_needs_input` for this session's own "Teammate
    // setup needs your input" and "File sync is offline — your message is
    // waiting". Overloaded across two meanings, one of which would be a lie
    // here, it stays undeclared — but for the new reason, not the old one.
    eventKindPath: ['notification_type'],
    eventKindMeaning: {
      'permission_prompt': AgentHookMeaning(
        AgentActivityStatus.awaitingApproval,
        waiting: AgentWaitKind.approval,
      ),
      // A *worker's* prompt, drawn somewhere this session's Enter does not
      // land, so it stops the session without offering a key for it.
      'worker_permission_prompt': AgentHookMeaning(
        AgentActivityStatus.awaitingApproval,
      ),
      // The 60-second nudge after a turn ends. Still holding the user up —
      // that is what `awaitingApproval` answers — but with nothing to confirm.
      'idle_prompt': AgentHookMeaning(
        AgentActivityStatus.awaitingApproval,
        waiting: AgentWaitKind.input,
      ),
      // **An MCP server is asking the user something, and nothing moves until
      // it is answered.** The CLI's own dialog table is unambiguous about which
      // side is blocked: both kinds carry `waitingFor: "input needed"`, against
      // the `"dialog open"` its passive dialogs get. Undeclared, a session sat
      // on one of these read `working` for as long as the dialog stayed up.
      //
      // `input`, not `approval`, because an elicitation is a **form** — free
      // text, a schema, or a link to open — and the Enter/Esc pair below
      // answers a list with something highlighted. Nothing here has seen one of
      // these on screen, and a key we are not sure lands on a prompt is a key
      // we do not send.
      'elicitation_dialog': AgentHookMeaning(
        AgentActivityStatus.awaitingApproval,
        waiting: AgentWaitKind.input,
      ),
      'elicitation_url_dialog': AgentHookMeaning(
        AgentActivityStatus.awaitingApproval,
        waiting: AgentWaitKind.input,
      ),
      // **The usage limit reset and the session did not restart itself.** Its
      // message says so in the imperative — "Usage limit reset — press enter to
      // continue" — and its two siblings are the same state reached another
      // way: "Automatic continue was turned off — the task will not resume on
      // its own", and the same sentence for a limit that now resets more than
      // 24 hours out. A turn parked like this is indistinguishable from a
      // working one to every other source we have, so without these the app's
      // answer was whatever the session last said, for as long as it sat there.
      //
      // Still `input`. The CLI names Enter, which is the Approve key — but not
      // what Esc would do, and `approval` offers both. The third sibling,
      // `quota_auto_resume_fired` ("Claude is continuing your task"), is the
      // opposite state and is deliberately left undeclared: it is news that
      // nobody is held up, which is not a status this app records.
      'quota_auto_resume_stale': AgentHookMeaning(
        AgentActivityStatus.awaitingApproval,
        waiting: AgentWaitKind.input,
      ),
      'quota_auto_resume_disabled': AgentHookMeaning(
        AgentActivityStatus.awaitingApproval,
        waiting: AgentWaitKind.input,
      ),
    },
    // **`Stop` does not always mean the turn is over.** Claude Code 2.1.260
    // runs a `Task` subagent as *background* work: the main thread fires a real
    // `Stop` the moment the worker is launched, and a fresh `UserPromptSubmit`
    // carrying a `<task-notification>` wakes it when the worker reports back.
    // Captured whole on 2026-09-04 by pointing a `--settings` file's hooks at a
    // scratch directory and running one `-p` turn that used the `Task` tool
    // (session `95355021-…`, ~13 s end to end):
    //
    //   09:59:17.6  PreToolUse   Task           (main thread)
    //   09:59:19.7  PreToolUse   Bash           agent_id=a8989a29…
    //   09:59:22.1  Stop         background_tasks:[{type:"subagent",
    //                              status:"running",…}]
    //                            last_assistant_message:"Agent launched to run
    //                              the command—waiting for completion."
    //   09:59:23.7  SubagentStop agent_id=a8989a29…
    //   09:59:23.8  UserPromptSubmit  prompt:"<task-notification>…"
    //   09:59:25.3  Stop         background_tasks:[]
    //
    // The 09:59:22 `Stop` is the main thread's, carries no `agent_id`, and is
    // three seconds into a turn that had thirteen to run. Read as `idle` it
    // fires "Agent finished" — and the message it would quote to say *what*
    // finished is "waiting for completion". The CLI's own wake-up note spells
    // the rule out: *"A task-notification fires each time this agent stops with
    // no live background children of its own."* On a real `Task` that window is
    // the subagent's whole run.
    //
    // `background_tasks` is the field the CLI provides for exactly this, and
    // only it: `session_crons` is deliberately **not** consulted, because a
    // session with a `/loop` scheduled has genuinely finished its turn and is
    // waiting on a clock, not on work.
    inFlightPath: {'Stop': ['background_tasks']},
    eventStatus: {
      'UserPromptSubmit': AgentActivityStatus.working,
      'PreToolUse': AgentActivityStatus.working,
      'PostToolUse': AgentActivityStatus.working,
      'Notification': AgentActivityStatus.awaitingApproval,
      'Stop': AgentActivityStatus.idle,
      'SessionEnd': AgentActivityStatus.idle,
      // **The direct failure signal, and it needs no interpretation.** Read out
      // of the installed 2.1.258 binary's own hook-event table:
      //
      //   StopFailure: {summary: "When the turn ends due to an API error",
      //     description: "Fires instead of Stop when an API error (rate limit,
      //     auth failure, etc.) ended the turn. Fire-and-forget — hook output
      //     and exit codes are ignored.",
      //     matcherMetadata: {fieldToMatch: "error", values: ["rate_limit",
      //     "overloaded","authentication_failed","oauth_org_not_allowed",
      //     "account_on_hold","billing_error","invalid_request",
      //     "model_not_found","server_error","max_output_tokens","unknown"]}}
      //
      // Two properties make this the one hook worth adding without a live run
      // behind it. **"Fires instead of Stop"** means a broken turn no longer
      // reports idle, rather than reporting both. **"Fire-and-forget — hook
      // output and exit codes are ignored"** means it carries none of the
      // stdout risk that keeps `PermissionRequest` undeclared: there is no
      // decision for an empty reply to be misread as.
      //
      // Its `error` values are the same vocabulary the transcript's own
      // top-level `error` field uses (`stateFile.failed` above), so hook and
      // state file agree about what a failure is. An older CLI that does not
      // know the event simply never fires it.
      'StopFailure': AgentActivityStatus.failed,
    },
    // **The two events that speak for the session rather than the turn.**
    // `SessionEnd` is the CLI on its way out, and `StopFailure` is the CLI
    // naming an API error as the reason a turn stopped — the only failure word
    // Claude Code ever gives us that we did not infer. `Stop` is deliberately
    // absent: it fires once per turn, many times a session.
    eventEnding: {
      'SessionEnd': AgentSessionEnding.completed,
      'StopFailure': AgentSessionEnding.failed,
    },
    // **What is left out, and why — checked against 2.1.260's own hook-event
    // table, which lists 33 events.** Each installed event is a process the
    // user's agent spawns on every firing, so the bar is a question this app
    // asks that nothing already answers.
    //
    // * `SubagentStop` — "Right before a subagent (Agent tool call) concludes
    //   its response. Input to command is JSON with agent_id, agent_type, and
    //   agent_transcript_path." It is **not this session stopping**: the
    //   captured payload carries the parent's `session_id` with an `agent_id`
    //   beside it, so `idle` would be a false completion and `working` says
    //   nothing new — the worker's own `PreToolUse`/`PostToolUse` already fire
    //   under the parent's `session_id` and keep it reading `working`. The
    //   transcript-looks-idle problem it was raised for is fixed in
    //   `stateFile` below (`tool_use` before the assistant record, and an aged
    //   `working` record becoming `unknown` rather than `idle`), and the
    //   mid-turn `Stop` it also touches is fixed by `inFlightPath` above. What
    //   it *would* buy is a toast when a long worker returns, and the parent
    //   resumes at that instant — so nobody is unblocked and nothing is
    //   actionable.
    //
    // * `SessionStart` — a flat status would be wrong. Its `source` matcher is
    //   `["startup","resume","clear","compact","fork"]`, and `compact` fires
    //   mid-turn on a session that is working, so `idle` would report a busy
    //   session as finished. Telling them apart needs a *per-event* subtype
    //   path, and `eventKindPath` is one path for the whole spec — spent on
    //   `notification_type`, which answers a question nothing else can.
    //
    // * `PreCompact` — `working`, which every surrounding tool event already
    //   says. Its stdout contract is also live: "Exit code 0 - stdout appended
    //   as custom compact instructions", so the callback would be one edit away
    //   from writing into the user's compaction.
    //
    // * `PermissionRequest` — still no. 2.1.260 words it exactly as before:
    //   "Output JSON with hookSpecificOutput containing decision to allow or
    //   deny. Exit code 0 - use hook decision if provided." An empty reply
    //   risks being read as a decision on somebody's permission prompt, and
    //   `Notification`'s `permission_prompt` already reports the same moment
    //   with a message that names the tool.
  ),
  // A transcript ending in an assistant record is a finished turn; one ending
  // in a user record (a prompt or a tool result) means the agent is mid-turn.
  //
  // **Unless that assistant record is a tool call.** Claude Code writes one as
  // an assistant record whose `message.content` holds a `tool_use` block, and
  // the `tool_result` answering it only arrives in a later user record — so
  // while a `Task` subagent, a long `Bash`, or an `AskUserQuestion` is
  // outstanding, the file's last record has the shape of a finished turn.
  // Replaying the owner's own transcript found 6,291 such points, 18 hours of
  // wall time reported as idle, the longest window 25 minutes.
  //
  // **And unless the turn ended in an API error.** Claude Code writes a broken
  // turn as an *assistant* record too — same `type`, one `text` block — marked
  // only by the boolean `isApiErrorMessage: true` and a top-level `error`
  // naming the reason. Read off the owner's own store, e.g.
  // `~/.claude/projects/G--dev-godot-proc-nepal/bbde0f77-…/subagents/
  // agent-a4772db3a758e9504.jsonl`, whose last record is:
  //
  //   {"type":"assistant","error":"server_error","isApiErrorMessage":true,
  //    "message":{"model":"<synthetic>","content":[{"type":"text",
  //    "text":"API Error: Unable to connect to API (FailedToOpenSocket)"}]}}
  //
  // and, three times in another session, `"error":"authentication_failed"` /
  // "Failed to authenticate: OAuth session expired and could not be refreshed".
  // Ten transcripts across the owner's two stores end on one of these, and
  // every one of them read `idle` — which is what fires the *finished*
  // notification. An authentication failure telling the user their work is done
  // is the worst answer this pipeline can give, and it is the same family of
  // bug as claiming a completion we cannot see.
  //
  // `isApiErrorMessage` rather than `message.model == '<synthetic>'`: the
  // synthetic model is also how the CLI writes its 35 "No response requested."
  // placeholders, which carry `isApiErrorMessage: false` and are not failures.
  // The boolean is the field that means only this, which is why
  // `StateRecordMatcher` now compares values other than strings.
  //
  // Terminal, not transient: of the 45 such records in the owner's store, every
  // one is followed by a `system`/`turn_duration` record, by a fresh user turn,
  // or by nothing at all — never by the turn continuing. The separate
  // `{"type":"system","subtype":"api_error","retryAttempt":n}` record is the
  // retry, and it is deliberately not matched here.
  stateFile: AgentStateFileRules(
    idle: [
      StateRecordMatcher(['type'], 'assistant'),
    ],
    working: [
      StateRecordMatcher(['type'], 'user'),
      StateRecordMatcher.anyIn(['message', 'content'], 'type', 'tool_use'),
    ],
    failed: [
      StateRecordMatcher(['isApiErrorMessage'], true),
    ],
  ),
  // Read off Claude Code v2.1.251's own footer, captured from a real PTY run
  // (`test/features/agents/fixtures/claude-code-*.raw`). Working and idle differ
  // by one segment of the same line, which is why the order matters more than
  // the patterns: `esc to interrupt` is checked before the footer that is always
  // there.
  grid: AgentGridRules(
    awaitingApproval: [
      // The workspace-trust modal's footer, captured whole in
      // `claude-code-trust-prompt.raw`: `Enter to confirm · Esc to cancel`.
      GridMatcher('Enter to confirm'),
      // The **tool**-permission modal names no confirm key at all. v2.1.258's
      // ends `Esc to cancel · Tab to amend` (captured in
      // `claude-code-permission-modal.raw`), and the amend half is conditional,
      // so `Esc to cancel` on its own is the only thing left to match — which
      // is why these two are an either/or and not a pair.
      //
      // On its own that phrase is far too loose: the CLI also prints it on its
      // rate-limit banner, its login screens and its menus, and an agent can
      // simply write it in a message. What keeps it honest is the composer
      // check in `TerminalGridStatusSource`, not this list.
      GridMatcher('Esc to cancel'),
    ],
    working: [GridMatcher('esc to interrupt')],
    // Two footers, because the hint segment is mode-dependent: a session in
    // bypass mode drops `(shift+tab to cycle)` entirely and reads
    // `bypass permissions on · 1 shell · ← for agents · ↓ to manage`. That screen
    // matched nothing, so the source declined and the grid could not say the
    // session was merely sitting at its prompt.
    idle: [
      GridMatcher('shift+tab to cycle'),
      GridMatcher('bypass permissions on'),
    ],
  ),
  // Both keys are read off the same footer the matchers above fire on —
  // `Enter to confirm · Esc to cancel` — so we are sending keys the agent
  // itself advertises rather than ones we assumed.
  approval: AgentApprovalRules(
    approve: AgentApprovalKey(
      keys: '\r',
      label: 'Approve',
      effect:
          'Sends Enter, which confirms whichever option Claude Code currently '
          'has highlighted.',
    ),
    deny: AgentApprovalKey(
      keys: '\x1b',
      label: 'Deny',
      effect: 'Sends Esc, which cancels the prompt.',
    ),
  ),
  // Claude Code reads a picture off a path a prompt names — measured in this
  // repo rather than read off `--help`: `SessionMediaOrigin.read` exists
  // because real transcripts here carry `Read` tool calls whose input is an
  // image file, and `TranscriptImagePreview` draws them from that path. That
  // is the one door open to a *running* session, which is what matters:
  // Karmashala delivers a message by typing it into the session's PTY, so a
  // launch flag is not reachable once the session is up.
  //
  // The four types are `kMediaTypeExtensions` minus the two the desktop's own
  // media panel accepts but no phone camera produces.
  attachments: AgentAttachmentSupport.byPath(
    ['image/png', 'image/jpeg', 'image/gif', 'image/webp'],
    evidence:
        'Karmashala transcripts, 2026-09: Read tool calls naming .png/.jpg '
        'files, drawn by TranscriptImagePreview from that path',
  ),
  // The whole declaration, with the counts it was read off, is at
  // [kClaudeCodeTodoWrite]. It is not inlined here because the transcript
  // reader looks the same value up by tool name, and two copies of a schema is
  // how one of them goes stale.
  plan: kClaudeCodeTodoWrite,
  skills: AgentSkillSupport.homeDirectory(
    ['.claude', 'skills'],
    evidence:
        'claude 2.1.263: --safe-mode names skills among the customizations it '
        'disables, and ~/.claude/skills/pinokio/SKILL.md is one already '
        'installed at user level on this machine. Read 2026-09-09.',
  ),
);

const _codex = AgentDescriptor(
  id: 'codex',
  displayName: 'Codex CLI',
  kind: AgentKind.codex,
  // The OpenAI Codex Windows installer's own target directory, which it also
  // adds to the user PATH. Listed anyway because PATH only helps a process
  // started *after* the install: the app inherits its PATH once, at launch.
  binaries: AgentBinaries(
    windows: ['codex'],
    posix: ['codex'],
    windowsInstallPaths: [
      r'%LOCALAPPDATA%\Programs\OpenAI\Codex\bin\codex.exe',
    ],
  ),
  launch: AgentLaunchSpec(
    baseArguments: ['app-server'],
    // **Codex is two axes, not one**, and squeezing them into a single picker
    // is what made "accept edits" an approximation with an apology attached. A
    // *sandbox* decides what may be written; an *approval policy* decides what
    // must be asked. They are independent flags and they compose.
    //
    //   $ codex --help
    //     -s, --sandbox <SANDBOX_MODE>
    //          [possible values: read-only, workspace-write, danger-full-access]
    //     -a, --ask-for-approval <APPROVAL_POLICY>
    //          - untrusted:  Only run "trusted" commands … escalate …
    //          - on-request: The model decides when to ask the user for approval
    //          - never:      Never ask for user approval …
    //
    // **Declared from the latest Codex only**, which is also the set both
    // installations on this machine accept:
    //
    //   Windows 0.145.0  $ codex --ask-for-approval on-failure --help
    //     [possible values: untrusted, on-request, never]
    //   WSL     0.151.0  $ codex --ask-for-approval on-failure --help
    //     [possible values: on-request, never]
    //
    // `untrusted` is deliberately **not** declared. It exists on 0.145.0 and
    // 0.151.0 rejects it, and offering a value the installed binary refuses is
    // how a launch fails outright — which has now happened twice to this one
    // flag (`on-failure` on 0.145.0, `untrusted` on 0.151.0). The latest set is
    // a subset of the older one, so declaring it is safe on both.
    //
    // The cost is stated rather than hidden: **Codex has no "ask before
    // anything" left**. Nothing here reaches `PermissionRisk.ask`, and a
    // handoff of an ask-every-time session onto Codex therefore falls to a
    // read-only sandbox and says so, instead of pretending.
    //
    // `permits` is a **cap**, and the axes compose by `min`: `on-request` and
    // `never` impose no guaranteed cap of their own (the model may simply not
    // ask), so the sandbox is what bounds them — which is why read-only+never
    // is readOnly and danger-full-access+on-request is a bypass.
    permission: AgentPermissionSupport.axes(
      evidence:
          'codex --help and the rejection messages of '
          '`--sandbox bogus` / `--ask-for-approval on-failure` on 0.145.0 '
          '(Windows) and 0.151.0 (WSL)',
      legacyAliases: {
        'ask': 'approval=on-request;sandbox=workspace-write',
        'acceptEdits': 'approval=on-request;sandbox=workspace-write',
        'bypass': 'approval=on-request;sandbox=bypass-all',
      },
      axes: [
        AgentPermissionAxis(
          id: 'sandbox',
          label: 'Sandbox',
          description: 'What Codex may write without escalating.',
          defaultValueId: 'workspace-write',
          values: [
            AgentPermissionValue(
              id: 'read-only',
              label: 'Read-only',
              shortLabel: 'Read-only',
              description: 'Codex cannot write. It reads and proposes.',
              arguments: ['--sandbox', 'read-only'],
              permits: PermissionRisk.readOnly,
              evidence:
                  'codex --sandbox bogus --help: "[possible values: '
                  'read-only, workspace-write, danger-full-access]"',
            ),
            AgentPermissionValue(
              id: 'workspace-write',
              label: 'Write in the workspace',
              shortLabel: 'Workspace',
              description:
                  'Codex may write inside the working tree without asking.',
              arguments: ['--sandbox', 'workspace-write'],
              permits: PermissionRisk.acceptEdits,
              evidence:
                  'codex --sandbox bogus --help: "[possible values: '
                  'read-only, workspace-write, danger-full-access]"',
            ),
            AgentPermissionValue(
              id: 'danger-full-access',
              label: 'No sandbox',
              shortLabel: 'No sandbox',
              description:
                  'Codex may write anywhere. Only the approval policy is '
                  'left between it and the machine.',
              arguments: ['--sandbox', 'danger-full-access'],
              permits: PermissionRisk.bypass,
              evidence:
                  'codex --sandbox bogus --help: "[possible values: '
                  'read-only, workspace-write, danger-full-access]"',
            ),
            AgentPermissionValue(
              id: 'bypass-all',
              label: 'Bypass approvals and sandbox',
              shortLabel: 'Bypass',
              description:
                  'Skip all confirmation prompts and execute commands '
                  'without sandboxing. Codex calls this EXTREMELY DANGEROUS.',
              arguments: ['--dangerously-bypass-approvals-and-sandbox'],
              permits: PermissionRisk.bypass,
              isDangerous: true,
              // One flag replaces both, so the approval picker has nothing left
              // to say and contributes no arguments.
              supersedes: ['approval'],
              evidence:
                  'codex --help: "--dangerously-bypass-approvals-and-sandbox  '
                  'Skip all confirmation prompts and execute commands without '
                  'sandboxing. EXTREMELY DANGEROUS."',
            ),
          ],
        ),
        AgentPermissionAxis(
          id: 'approval',
          label: 'Approval policy',
          description: 'When Codex stops to ask.',
          defaultValueId: 'on-request',
          values: [
            AgentPermissionValue(
              id: 'on-request',
              label: 'Codex decides when to ask',
              shortLabel: 'On request',
              description:
                  'The model decides when to ask. The sandbox, not this, is '
                  'what bounds it.',
              arguments: ['--ask-for-approval', 'on-request'],
              permits: PermissionRisk.bypass,
              evidence:
                  'codex --help: "on-request: The model decides when to ask '
                  'the user for approval"',
            ),
            AgentPermissionValue(
              id: 'never',
              label: 'Never ask',
              shortLabel: 'Never ask',
              description:
                  'Never ask. Execution failures go straight back to the '
                  'model. The sandbox is the only thing left.',
              arguments: ['--ask-for-approval', 'never'],
              permits: PermissionRisk.bypass,
              evidence:
                  'codex --help: "never: Never ask for user approval '
                  'Execution failures are immediately returned to the model"',
            ),
          ],
        ),
      ],
    ),
    resume: AgentResume.flag('--resume'),
    // Interactively Codex resumes with a subcommand, not a flag.
    interactiveResume: AgentResume.subcommand('resume'),
    // Nothing about Codex's store mentions the working directory. A thread is
    // `~/.codex/sessions/<YYYY>/<MM>/<DD>/rollout-<timestamp>-<id>.jsonl` —
    // keyed by the date it was started — and the cwd is a field *inside* it,
    // in the `session_meta` record on the first line. There is a global
    // `~/.codex/session_index.jsonl` mapping id to thread name beside it. This
    // is cmux's `cwdInFile` shape exactly, and it is the one claim of cmux's
    // this machine confirms outright rather than qualifies.
    resumeLocality: AgentResumeLocality.anyDirectory(
      evidence:
          r'~/.codex/sessions/2026/07/31/rollout-2026-07-31T07-46-11-<id>.jsonl'
          ' opens with {"type":"session_meta","payload":{"session_id":"<id>",'
          '…,"cwd":"/mnt/c/Users/dlohani/projects/popupbits",…}} — the path '
          'is date-keyed, the cwd is content, and ~/.codex/session_index.jsonl '
          'indexes ids globally',
    ),
    prompt: AgentPromptSupport.positional(
      evidence: 'codex --help (0.146): "Usage: codex [OPTIONS] [PROMPT]"',
    ),
    // Checked and absent, which is a different fact from unchecked. Codex has
    // config keys in this area — `model_instructions_file`,
    // `developer_instructions` — reachable through `-c`, and they are
    // deliberately not used: the first **replaces** Codex's own base
    // instructions rather than appending to them, so delivering a handoff
    // through it would strip the agent's system prompt to hand it a brief. A
    // typed packet is the weaker delivery; an agent with no instructions is a
    // worse one.
    systemPromptFile: AgentSystemPromptFileSupport.absent(
      evidence:
          'codex 0.153.4 --help: the whole option list is -c/--enable/'
          '--disable/--remote/--remote-auth-token-env/--strict-config/-i/-m/'
          '--oss/--local-provider/-p/-s/--approve-for-me/'
          '--dangerously-bypass-approvals-and-sandbox/'
          '--dangerously-bypass-hook-trust/-C/--add-dir/-a/--search/'
          '--no-alt-screen — no system-prompt or instructions file among them',
    ),
    // Left at the default (false): Codex enforces **one writer per thread**.
    // The lock is real and inspectable — a live Codex holds an flock on
    // `~/.codex/thread-writer-locks/<thread-id>.lock` — and a second resume of
    // a held thread exits with
    // `thread <id> already has an active writer (code -32600)`.
    //
    // Version-dependent, and the safe answer wins: 0.151 enforces it, 0.145 has
    // no such lock and lets a second resume through (both observed, see the
    // loop report). We do not model per-version behaviour, and being wrong here
    // in the permissive direction means two processes appending to one rollout
    // JSONL, so the newest behaviour is the one recorded.
    resumeConflict: AgentResumeConflictRules(
      markers: [GridMatcher('already has an active writer')],
    ),
    // **The safety net for the axes above being wrong about this binary.**
    // Mode support is a property of the *installation*, and the two Codex
    // builds on this machine disagree: 0.145.0 offers `untrusted`, 0.151.0 does
    // not. Only the newest set is declared, which is right until the day an
    // installation is older or newer than the one that was read — and on that
    // day the launch dies at argv-parse time, before Codex draws anything.
    //
    // It refuses generously, naming the whole valid set, and identically on
    // both versions:
    //
    //   $ codex --ask-for-approval on-failure --help          # 0.151.0, WSL
    //   error: invalid value 'on-failure' for '--ask-for-approval
    //     <APPROVAL_POLICY>'
    //     [possible values: on-request, never]
    //
    //   $ codex --sandbox bogus --help
    //   error: invalid value 'bogus' for '--sandbox <SANDBOX_MODE>'
    //     [possible values: read-only, workspace-write, danger-full-access]
    //
    // Three groups: the refused value, the flag, the set offered instead. The
    // `[^\]]*` between the flag and the bracket is what steps over clap's
    // `<APPROVAL_POLICY>` placeholder and the closing quote, and the whole
    // thing is matched against the screen with the whitespace taken out, so the
    // two lines may wrap anywhere.
    //
    // **Claude Code's equivalent is deliberately not declared.** Its refusal
    // has a different shape — `error: option '--permission-mode <mode>'
    // argument 'bogus' is invalid. Allowed choices are …` — and, unlike Codex,
    // both installations here enforce the *same* six modes, so nothing has ever
    // been seen to disagree with what is declared for it. A pattern with no
    // observed failure behind it is a guess with a regular expression in it.
    rejectedValue: AgentRejectedValueRules.pattern(
      pattern:
          r"invalidvalue'([^']+)'for'(-{1,2}[A-Za-z0-9][A-Za-z0-9-]*)"
          r"[^\]]*\[possiblevalues:([^\]]+)\]",
      evidence:
          "codex 0.151.0: `codex --ask-for-approval on-failure --help` prints "
          "\"error: invalid value 'on-failure' for '--ask-for-approval "
          "<APPROVAL_POLICY>'\\n  [possible values: on-request, never]\"; "
          '`codex --sandbox bogus --help` prints the same shape for '
          '`--sandbox`. 0.145.0 (Windows) prints it identically, with '
          '`untrusted` still in the set.',
    ),
    // **Codex can fork**, contrary to the assumption this feature was designed
    // under. 0.151.0 has a `fork` subcommand alongside `resume`, taking the
    // same `[SESSION_ID] [PROMPT]` arguments, so the fork is expressed exactly
    // like the interactive resume with one word changed.
    //
    // The picker forms (`--last`, no argument) are deliberately not used: they
    // choose a session by recency within a working directory, which is a guess
    // about which conversation the user meant, and the app already knows the
    // id whenever it has one. When it does *not* — a native Codex row whose
    // thread id was never discovered, which Loop 46 §6 leaves as an open gap —
    // there is nothing truthful to pass, and `SessionForkPlan` degrades that
    // session to a handoff rather than letting a picker guess.
    fork: AgentForkSupport.native(
      resume: AgentResume.subcommand('fork'),
      evidence:
          'codex-cli 0.151.0 --help: "fork  Fork a previous interactive '
          'session (picker by default; use --last to fork the most recent)"; '
          'codex fork --help: "Usage: codex fork [OPTIONS] [SESSION_ID] '
          '[PROMPT]"',
    ),
    // Codex has no `--mcp-config`. It has `-c <dotted.key>=<value>`, which
    // overrides one value that would otherwise come from `~/.codex/config.toml`
    // and leaves the rest of that file — and the user's own servers — alone:
    //
    //   $ codex mcp list -c mcp_servers.karmashala.url=http://…/mcp/TOK
    //   Name           Command …
    //   agent-browser  …/agent-browser.exe  mcp  …  enabled
    //
    //   Name         Url                       …
    //   karmashala  http://…/mcp/TOK          …  enabled
    //
    // **Writing the block into `config.toml` instead was rejected**, and not
    // only because editing a user's config file is invasive. That file holds
    // one `[mcp_servers.karmashala]` for the whole machine, so it can carry
    // exactly one URL — and the URL is what says *which session* is calling.
    // Every Codex session would have spoken as whichever one wrote last, which
    // is the one property this whole mechanism exists to provide.
    //
    // The cost, stated plainly: the session's capability token is in the
    // process command line, where anything that can enumerate processes can
    // read it (`/proc/<pid>/cmdline` inside a WSL distro is world-readable).
    // Claude's file avoids that. Codex would too via
    // `bearer_token_env_var`, which reads the credential from the environment
    // — `/proc/<pid>/environ` is owner-only — but that needs the launch to
    // carry an extra variable onto the agent process, which is
    // `AgentPaneLaunch`'s to give and not this descriptor's.
    mcp: AgentMcpSupport.inlineUrl(
      flag: '-c',
      urlKey: 'mcp_servers.karmashala.url',
      evidence:
          'codex-cli 0.151.0 --help: "-c, --config <key=value>  Override a '
          'configuration value that would otherwise be loaded from '
          '`~/.codex/config.toml`"; `codex mcp add --url` documents `url` as '
          'the streamable-HTTP key, and `codex mcp list -c '
          'mcp_servers.karmashala.url=…` lists it beside the user\'s own',
    ),
    // **Codex takes a model at launch and cannot be moved mid-session**, which
    // is the opposite of the assumption this feature was designed under and the
    // whole reason the capability is declared per agent rather than assumed.
    //
    // The launch half is ordinary: `-m, --model <MODEL>  Model the agent should
    // use`. The in-session half is simply not there. 0.151.0's slash-command
    // list describes `/model` as "choose what model and reasoning effort to
    // use", and it is drawn by `tui/src/chatwidget/model_popups.rs` — a
    // **picker**. No `/model <arg>` form appears anywhere in the binary, and
    // the commands that do take an argument advertise it in their own
    // description ("let sandbox read a directory: /sandbox-add-read-dir
    // <absolute_path>", "list configured MCP tools; use /mcp verbose for
    // details"). So typing `/model gpt-5.6-sol` into a live Codex would open a
    // popup and drop the name — the silent no-op the model control exists to
    // avoid — and Codex is declared launch-only instead.
    //
    // The slugs are **this machine's** `$CODEX_HOME/models_cache.json`, which
    // `app-server/src/models_refresh_worker.rs` keeps per account, read on
    // 2026-09-02; the two entries it marks `"visibility":"hide"`
    // (`gpt-reserve`, `codex-auto-review`) are left out. That file is the
    // refresh instruction as much as the source: another account's list will
    // differ, and an id this list does not carry is still passed to the CLI
    // rather than dropped — see [AgentModelSupport.argumentsFor].
    model: AgentModelSupport.atLaunchOnly(
      flag: '--model',
      models: [
        AgentModel(
          id: 'gpt-5.6-sol',
          label: 'GPT-5.6-Sol',
          summary: 'Latest frontier agentic coding model.',
        ),
        AgentModel(
          id: 'gpt-5.6-terra',
          label: 'GPT-5.6-Terra',
          summary: 'Sibling of Sol in the 5.6 family.',
        ),
        AgentModel(
          id: 'gpt-5.6-luna',
          label: 'GPT-5.6-Luna',
          summary: 'Sibling of Sol in the 5.6 family.',
        ),
        AgentModel(
          id: 'gpt-5.5',
          label: 'GPT-5.5',
          summary: 'The previous generation.',
        ),
        AgentModel(
          id: 'gpt-5.4',
          label: 'GPT-5.4',
          summary: 'Older, and still listed by the account.',
        ),
        AgentModel(
          id: 'gpt-5.4-mini',
          label: 'GPT-5.4-Mini',
          summary: 'Smallest and fastest of the listed models.',
        ),
      ],
      evidence:
          'codex-cli 0.151.0 --help: "-m, --model <MODEL>  Model the agent '
          'should use"; no in-session form declared because that build\'s '
          '/model is a picker ("choose what model and reasoning effort to '
          'use", drawn by tui/src/chatwidget/model_popups.rs) with no argument '
          'form anywhere in the binary; slugs read from '
          '\$CODEX_HOME/models_cache.json on 2026-09-02',
    ),
  ),
  store: AgentStoreSpec(
    homeDirectoryName: '.codex',
    format: AgentStoreFormat.codexRollout,
  ),
  // **Codex has hooks**, and they are the only source that can say a turn
  // started. The backlog recorded this agent as configurable only through TOML;
  // it also reads `$CODEX_HOME/hooks.json`, in the same shape this app already
  // writes for Claude Code, behind a per-entry trust grant — see [hooks].
  statusStrategy: AgentStatusStrategy.hooks,
  // **Every hook entry is trust-gated on a hash of the entry itself**, so the
  // command must be identical on every launch and the callback address lives in
  // a script the installer rewrites instead. The whole argument, and the source
  // it was established from, is on [AgentHookSpec.trustsCommandByHash].
  //
  // Five events, and only five. The 0.145.0 installed here knows eleven
  // (`config/src/hook_config.rs`, `HookEventsToml`), and the six left out are
  // left out for reasons rather than for brevity:
  //
  //  * `SubagentStart` / `SubagentStop` describe a *different* agent inside
  //    this session, exactly like Claude Code's, and neither is declared there
  //    either;
  //  * `PreCompact` / `PostCompact` happen inside a turn `PreToolUse` has
  //    already reported as working, so they would restate it;
  //  * `SessionStart` fires before the user has done anything, and "the CLI is
  //    open" is not a status this app has a use for;
  //  * `Interrupt` **does not exist in 0.145.0** — it is a twelfth event on the
  //    project's `main`, and `HooksFile` is `deny_unknown_fields`, so naming it
  //    here would make this CLI discard the entire file and every hook in it,
  //    ours and the user's alike, with only a warning.
  //
  // **`PermissionRequest` is the sixth, and it is the one worth explaining.**
  // It is the event this integration was wanted for: `awaitingApproval` is
  // unreachable for Codex from the rollout by construction, because
  // `should_persist_event_msg` drops approval requests as transient. The hook
  // exists, it is safe to install — an observational handler is genuinely
  // neutral, and the empty-stdout branch of `parse_completed` in
  // `hooks/src/events/permission_request.rs` is a literally empty block — and
  // it is still **not declared, because it does not mean what its name
  // suggests**.
  //
  // It fires when an approval *decision* is being made, not when the user is
  // being asked one. The session approval cache is consulted **inside**
  // `start_approval_async`, which runs after the hook has already fired, so a
  // user who approved `npm test` for the session gets `PermissionRequest` on
  // every later `npm test`, a cache hit in microseconds, and no prompt at all.
  // That is not an exotic configuration; it is what an ordinary session looks
  // like after its first approval. The same is true of a guardian-reviewed
  // call. Declaring this event would light up "Awaiting input" and fire an
  // attention notification for calls the user never sees — the exact bug
  // `cff3eca4` removed, arriving through a new transport.
  //
  // Nothing in the payload separates the two: there is no reviewer field, no
  // cache-hit field, and `permission_mode` is a turn-level policy label that
  // reads `"default"` for a cached approval, a guardian review and a real
  // prompt alike. No other hook fires when the prompt is actually drawn — that
  // is a protocol `EventMsg`, which the hook system does not observe. The
  // source that *could* answer it is the app-server event stream, and reaching
  // it means owning the process rather than watching a terminal the user types
  // into, which is the one thing this app is built not to do.
  //
  // So `awaitingApproval` stays unreachable for Codex, and the terminal grid
  // stays its only route to that state. Anyone revisiting this needs a signal
  // that the turn is still *parked* some seconds after the request — not
  // another reading of this payload.
  //
  // **And there is no failure event to declare.** `AgentActivityStatus.failed`
  // stays unreachable for Codex through hooks as well as through the rollout,
  // which is worth writing down so the next person does not go looking:
  // `run_turn_stop_hooks` is called from one place, inside the success branch
  // of `core/src/session/turn.rs`, so a turn that ends in an API error or an
  // abort fires **no hook at all** — not `Stop` with a reason, but nothing.
  // The only event that still arrives is `SessionEnd`, whose `reason` is the
  // hard-coded constant `"other"` (`hooks/src/events/session_end.rs`). There is
  // no Codex analogue of Claude Code's `StopFailure`.
  hooks: AgentHookSpec(
    // Beside `config.toml`, in the config folder Codex reads its user layer
    // from (`hooks/src/engine/discovery.rs`, `load_hooks_json`). The trust
    // grant is written to `[hooks.state]` in `config.toml` — by the CLI, never
    // by us — so that file, which on a real machine carries `notify`, plugins,
    // MCP servers and per-project trust levels, is never opened by this app.
    configFileName: 'hooks.json',
    // `configKey` and `entryStyle` are left at their defaults because Codex's
    // file is Claude Code's shape exactly: a `hooks` object of event names, each
    // a list of `{matcher?, hooks: [{type, command}]}` groups
    // (`config/src/hook_config.rs`, `HooksFile` / `MatcherGroup`). A `matcher`
    // is omitted, which selects every tool.
    trustsCommandByHash: true,
    // Codex hook input is `snake_case` and flat, one struct per event
    // (`hooks/src/schema.rs`). `session_id` and `cwd` are the defaults, and
    // both are present on every event declared below.
    //
    // There is **no message field anywhere in the payload** — no prose the
    // agent wrote about what it is doing. `tool_name` is the closest thing that
    // exists, and it is a name (`shell`, `apply_patch`), not a sentence, so it
    // is quoted as evidence for the two tool events that carry it and
    // contributes nothing to the other three, whose payloads have no such
    // field. Composing a description out of the rest of the payload is what
    // `evidence` exists to prevent.
    messagePaths: [
      ['tool_name'],
    ],
    eventStatus: {
      'UserPromptSubmit': AgentActivityStatus.working,
      'PreToolUse': AgentActivityStatus.working,
      'PostToolUse': AgentActivityStatus.working,
      'Stop': AgentActivityStatus.idle,
      // The CLI is exiting. Its hook budget is **one second**, clamped to three
      // (`discovery.rs`, `normalize_command_hook`), against every other event's
      // ten minutes — so this is the one callback that can be killed before it
      // lands. The `curl -m 2` in the script is bounded well inside the clamp
      // and a local connection either completes or is refused immediately, so
      // the cost of losing this race is one missed `idle`, not a stalled exit.
      'SessionEnd': AgentActivityStatus.idle,
    },
    // One entry, and the gap above it is the measured fact: Codex fires no hook
    // at all for a turn that ended in an API error or an abort, so `failed` has
    // no spelling here to declare. A Codex session that broke keeps whatever
    // its row last said rather than being given a word nobody sent.
    eventEnding: {'SessionEnd': AgentSessionEnding.completed},
  ),
  // The rollout stays as the fallback the hooks above do not
  // cover, and as the only source for a session started before the
  // hook entry was trusted.
  // **Rewritten against the owner's own 52 rollouts** (`~/.codex/sessions`,
  // 2025 and 2026, ~46,000 records). The rules before this matched neither of
  // the two records that bracket a turn, so replaying them gave 39 `unknown`,
  // 13 `idle` and — for a set of matchers three quarters of which claim
  // `working` — not one `working`. The most common terminal record in the whole
  // store was the one that means *the turn finished, here is how long it took*:
  //
  //   {"type":"event_msg","payload":{"type":"task_complete",
  //    "turn_id":"019ca351-…","last_agent_message":"Third pass completed…",
  //    "started_at":…,"completed_at":…,"duration_ms":35968}}
  //
  // 27 of 52 files end on one, and every one of them read `unknown` — so most
  // Codex turns raised no "finished" notification at all.
  //
  // **What this cannot buy, at any quality of matcher.** Codex's own
  // `should_persist_event_msg` drops `Error`, `ExecApprovalRequest`,
  // `ApplyPatchApprovalRequest`, `RequestPermissions` and `StreamError` from the
  // rollout as "transient, non-durable events"
  // (codex-rs/rollout/src/policy.rs), and `TurnAbortReason` has no failure
  // variant at all — only `{Interrupted, Replaced, ReviewEnded, BudgetLimited}`
  // (codex-rs/protocol/src/protocol.rs). `awaitingApproval` and `failed` are
  // therefore *structurally* absent from this format, not merely unmatched, and
  // no rule below should be added in the hope of finding them.
  stateFile: AgentStateFileRules(
    idle: [
      // The turn's closing bracket, and the single most common last record in
      // the store (27 of 52 files).
      StateRecordMatcher(['payload', 'type'], 'task_complete'),
      StateRecordMatcher(['payload', 'role'], 'assistant'),
      // A turn the user stopped. `TurnAbortReason` has no failure variant, and
      // the user who pressed Esc is already looking at the session — so this is
      // an ending, not a failure. 4 files end here.
      StateRecordMatcher(['payload', 'type'], 'turn_aborted'),
      // The 2025 envelope, before rollouts wrapped everything in `payload`:
      // `{"type":"message","role":"assistant","content":[…]}`. 4 archived files
      // end on one; no record in the current format carries a top-level `role`.
      StateRecordMatcher(['role'], 'assistant'),
    ],
    working: [
      // The turn's opening bracket, carrying `turn_id` and `started_at`.
      StateRecordMatcher(['payload', 'type'], 'task_started'),
      StateRecordMatcher(['payload', 'role'], 'user'),
      // A tool call, its result, or the model thinking — 6,202 / 6,202 / 6,491
      // records here, plus 1,700 apiece of the custom-tool pair and 462 web
      // searches. All mean the same thing: a turn is in flight.
      StateRecordMatcher(['payload', 'type'], 'function_call'),
      StateRecordMatcher(['payload', 'type'], 'function_call_output'),
      StateRecordMatcher(['payload', 'type'], 'custom_tool_call'),
      StateRecordMatcher(['payload', 'type'], 'custom_tool_call_output'),
      StateRecordMatcher(['payload', 'type'], 'web_search_call'),
      StateRecordMatcher(['payload', 'type'], 'reasoning'),
      StateRecordMatcher(['payload', 'type'], 'agent_reasoning'),
    ],
    // **`token_count` is why.** 9,650 of them, more than any other record type,
    // written between the records above whenever a rate-limit update arrives —
    // including as the very last record of two stored sessions. Enumerating
    // every bookkeeping record Codex will ever write is the game this avoids;
    // the walk is bounded to eight records so it stays a step past noise rather
    // than a search for any older record that says something.
    looksPastUnclassifiedRecords: true,
  ),
  // Codex 0.145's own screen, read off real PTY runs. `working` comes from its
  // status line (`• Working (3s • esc to interrupt)`, captured in
  // `test/features/agents/fixtures/codex-tui.raw`); `awaitingApproval` from its
  // modal footer, observed live when Codex blocked on the directory-trust
  // question before it would start at all.
  //
  // No `idle` marker is declared: an idle Codex screen has nothing this source
  // could tell apart from a busy one. That is not a gap to paper over — the
  // rollout file already answers idle, and an undeclared state resolves to
  // `unknown` rather than to a guess.
  grid: AgentGridRules(
    awaitingApproval: [GridMatcher('Press enter to continue')],
    working: [GridMatcher('esc to interrupt')],
  ),
  // Only half of one. Codex's prompt says `Press enter to continue` and names
  // no way to decline, so `deny` stays null and the UI sends the user to the
  // terminal for that rather than guessing that Esc backs out. Enter is the key
  // Loop 41 actually drove a real Codex trust modal with.
  approval: AgentApprovalRules(
    approve: AgentApprovalKey(
      keys: '\r',
      label: 'Continue',
      effect: 'Sends Enter, the key this prompt names.',
    ),
  ),
  // **Codex has images, and not through this door.** `codex --help` and
  // `codex exec --help` (codex-cli 0.153.4) both carry `-i, --image <FILE>...
  // Optional image(s) to attach to the initial prompt` — so pictures are
  // plainly in its model — but that is a *launch* flag, spent on the opening
  // prompt of a new process. Karmashala types into a session that is already
  // running, and nothing was found that makes Codex open an image named in a
  // typed prompt. Refused rather than guessed at: an attachment that crosses
  // the link and is never looked at is worse than a button that is not there.
  attachments: AgentAttachmentSupport.none(
    refusal:
        'Codex only takes a picture on the command line that starts it '
        '(--image), so a running session cannot be handed one.',
  ),
  plan: kCodexUpdatePlan,
  skills: AgentSkillSupport.homeDirectory(
    ['.codex', 'skills'],
    evidence:
        'codex-cli 0.153.4: `codex features list` reports skill_search as '
        'stable, and the bundled skill-installer skill installs into '
        '\$CODEX_HOME/skills — ~/.codex/skills/.system/<name>/SKILL.md on '
        'disk. Read 2026-09-09.',
  ),
);

const _antigravity = AgentDescriptor(
  id: 'antigravity',
  displayName: 'Antigravity',
  kind: AgentKind.antigravity,
  // **The executable is `agy`, not `antigravity`.** Everything in this entry
  // used to be inherited from Loop 10, which built the adapter against a fake
  // process and never ran the CLI; the binary name was the load-bearing part of
  // that guess, because discovery probes by name and so never found a real
  // installation. `agy --version` reports 1.1.22, and the CLI is a separately
  // distributed self-updating Go binary that puts itself on PATH with
  // `agy install` — the Antigravity IDE does not ship or launch it.
  //
  // No `windowsInstallPaths`: `agy install` is what puts the binary somewhere,
  // and nobody here has watched it do that on Windows. A guessed path would be
  // a probe that can only ever fail, so the honest entry is an empty one.
  binaries: AgentBinaries(windows: ['agy'], posix: ['agy']),
  launch: AgentLaunchSpec(
    // Deliberately empty. The previous `--stdio` does not exist in this CLI at
    // all, and while `agy --print --input-format stream-json --output-format
    // stream-json` is a documented headless protocol, nothing here has run it:
    // the tolerant line parser in `data/antigravity_adapter.dart` reads plain
    // text, so declaring stream-json would pair a JSON protocol with a parser
    // that does not speak it. Launching bare is also how the CLI is actually
    // invoked in practice. The adapter is an enhancement layer and never
    // load-bearing — every in-app session runs in a PTY — so an unverified
    // protocol is left unclaimed rather than half-wired.
    baseArguments: [],
    // All three modes now map, and all three are exact. Read off
    // `agy --help` (1.1.22):
    //
    //   --dangerously-skip-permissions  Auto-approve all tool permission
    //                                   requests without prompting
    //   --mode                          Set the agent execution mode for this
    //                                   session (accept-edits, plan)
    //
    // This replaces a single `bypass: ['--yolo']` mapping. `--yolo` is not a
    // flag this CLI has, so the one mode Antigravity claimed to support was the
    // one that would have failed — and it was the dangerous one.
    // `agy` 1.1.24 has **plan mode too**, and its `--help` names the values:
    //
    //   --mode                          Set the agent execution mode for this
    //                                   session (accept-edits, plan)
    //   --dangerously-skip-permissions  Auto-approve all tool permission
    //                                   requests without prompting
    //
    // That last line is also the evidence for the unflagged value: prompting is
    // what `agy` does unless it is told not to. The long-standing note that
    // "Antigravity's acceptEdits was empty because we have no idea how to ask"
    // is retired by the first line.
    //
    // **`agy` does not validate `--mode` at parse time** (Go's `flag` package
    // prints help and carries on), so only the two values its help names are
    // declared — an unknown one has never been run and would not announce
    // itself.
    //
    // **`--sandbox` is still not declared, and now for a measured reason
    // rather than an absent one.** It was run on 2026-09-03, which is what the
    // note here used to ask for, and on this machine it does not restrict the
    // terminal — it removes it.
    //
    // What it is *meant* to do is well documented inside the binary. The
    // bundled `run_command` instructions say: "**Standard Sandbox Mode
    // (BypassSandbox: false)**: By default has read/write access to your
    // workspace, but no network access and no access to files outside the
    // workspace unless added explicitly by the user… The main purpose of the
    // sandbox is to auto-run commands without needing the user's approval",
    // with an escape hatch ("**Bypass Sandbox Mode (BypassSandbox: true)**:
    // Disables isolation, allowing network and full filesystem access.
    // **Requires manual user approval.**") whose prompt is "Allow sandbox
    // bypass for command execution?". The bundled product docs call the same
    // setting "**Terminal Sandbox**: Run agent commands inside a restricted
    // sandbox environment for added security". It is a real Linux jail —
    // `google3/devtools/ai/sandbox/exebox`, with `loadSeccompFilter`,
    // `pivotroot` and its own loopback.
    //
    // What it actually did here, both headless and in a PTY:
    //
    //   $ agy --sandbox --dangerously-skip-permissions -p '…'
    //   Encountered error in tool execution: connecting to sandbox server:
    //   read unix @->@: recvmsg: connection reset by peer
    //
    // for **every** command, because the jail aborts while setting itself up —
    // the log carries `--sandbox: enabling terminal sandbox for this session`
    // (`overrides.go:70`; print mode logs it from `session.go:76`) followed by
    // `sbox: installing certificate: open /etc/ssl/cert.pem: read-only file
    // system`. Without `--dangerously-skip-permissions` the same run never got
    // that far: headless auto-denied the "command" permission, so `--sandbox`
    // is not an auto-run policy of its own either.
    //
    // A rung is a promise about what the agent may do. Declaring this one would
    // promise "auto-run, screened by a sandbox" and deliver an agent that
    // cannot run anything, on the platform half our sessions launch into. See
    // docs/BACKLOG.md.
    permission: AgentPermissionSupport.axes(
      evidence: 'agy 1.1.24 --help (WSL ~/.local/bin/agy)',
      legacyAliases: {
        'ask': 'mode=prompt',
        'acceptEdits': 'mode=accept-edits',
        'bypass': 'mode=skip-permissions',
      },
      axes: [
        AgentPermissionAxis(
          id: 'mode',
          label: 'Execution mode',
          description: 'How much Antigravity may do without asking.',
          defaultValueId: 'prompt',
          values: [
            AgentPermissionValue(
              id: 'plan',
              label: 'Plan mode',
              shortLabel: 'Plan',
              description: 'Plan the work rather than carry it out.',
              arguments: ['--mode', 'plan'],
              permits: PermissionRisk.readOnly,
              evidence:
                  'agy 1.1.24 --help: "--mode  Set the agent execution mode '
                  'for this session (accept-edits, plan)"',
            ),
            AgentPermissionValue(
              id: 'prompt',
              label: 'Ask every time',
              shortLabel: 'Ask',
              description:
                  'Antigravity prompts before tool use. This is what an '
                  'unflagged session does, so it needs no flag.',
              arguments: [],
              permits: PermissionRisk.ask,
              evidence:
                  'agy 1.1.24 --help: "--dangerously-skip-permissions  '
                  'Auto-approve all tool permission requests without '
                  'prompting" — which makes prompting the unflagged behaviour '
                  "in the CLI's own words",
            ),
            AgentPermissionValue(
              id: 'accept-edits',
              label: 'Accept edits',
              shortLabel: 'Accept edits',
              description: 'Apply edits without asking.',
              arguments: ['--mode', 'accept-edits'],
              permits: PermissionRisk.acceptEdits,
              evidence:
                  'agy 1.1.24 --help: "--mode  Set the agent execution mode '
                  'for this session (accept-edits, plan)"',
            ),
            AgentPermissionValue(
              id: 'skip-permissions',
              label: 'Bypass (full autonomy)',
              shortLabel: 'Bypass',
              description:
                  'Auto-approve all tool permission requests without '
                  'prompting.',
              arguments: ['--dangerously-skip-permissions'],
              permits: PermissionRisk.bypass,
              isDangerous: true,
              evidence:
                  'agy 1.1.24 --help: "--dangerously-skip-permissions  '
                  'Auto-approve all tool permission requests without '
                  'prompting"',
            ),
          ],
        ),
      ],
    ),
    // `--conversation  Resume a previous conversation by ID`. One convention
    // for both launches: unlike Codex there is no separate subcommand form, so
    // the headless and interactive resumes are the same flag.
    //
    // Interactive resume is the entry that was missing rather than wrong.
    // `interactiveResume` is what `agentPaneArguments` reads, and left at the
    // default it meant a pane could never continue an Antigravity conversation
    // at all, whatever the rest of the registry said.
    resume: AgentResume.flag('--conversation'),
    interactiveResume: AgentResume.flag('--conversation'),
    // Flat by id: `conversations/<uuid>.db` (and the `.pb` beside it), with
    // nothing in the path naming a directory. `agy --conversation=<id>` names
    // the file, so it opens from anywhere.
    //
    // The directory-keyed half of this store is `cache/last_conversations.json`
    // — a `{directory: conversation id}` map — and that is what `--continue`
    // resolves through, which is why [continueLatest] below declares
    // [AgentContinueScope.workingDirectory] and why `AntigravityResumePlan`
    // deliberately spells even its fallback as `--conversation <id>` rather
    // than `-c`. The cwd-scoped path exists here; it is simply never taken.
    resumeLocality: AgentResumeLocality.anyDirectory(
      evidence:
          '~/.gemini/antigravity-cli/conversations/<uuid>.db is flat by id; '
          'the only directory key in the store is '
          r'cache/last_conversations.json, e.g. {"C:\\Users\\dlohani": '
          '"0dee27dc-…"}, which indexes --continue and not --conversation',
    ),
    // **`agy` says which conversation it was.** The 2026-08-31 note recorded
    // that it "announces the id nowhere", which is why resume was left with a
    // flag nothing could supply a value for, and it is wrong: the CLI prints
    // its own resume command as it exits.
    //
    //   Resume with -c (or command below):
    //   agy --conversation=<uuid>
    //
    // Read out of the 1.1.22 binary as one format string, beside the
    // `entrypoints.printResumeHint` symbol that emits it. It is matched only in
    // the `=` form the CLI itself prints: this app passes `--conversation` and
    // the id as two arguments, so our own echoed command line cannot be
    // mistaken for the agent's statement about itself.
    sessionIdAnnouncement: AgentSessionIdAnnouncement.pattern(
      pattern:
          r'agy\s+--conversation=([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-'
          r'[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})',
      evidence:
          'agy 1.1.22 binary: "\\nResume with -c (or command below):\\n'
          'agy --conversation=%s\\n", emitted by '
          'entrypoints.printResumeHint',
    ),
    // `-c  Short alias for --continue` / `--continue  Continue the most recent
    // conversation`. "Most recent" is scoped to the **working directory**, and
    // that is read rather than assumed: `--continue` resolves through
    // `entrypoints.resolveContinuedConversationID` →
    // `store.Manager.GetLastConversation`, which reads
    // `cache/last_conversations.json` — a flat `{directory: conversation id}`
    // map. On a live store that file held one entry per directory and named the
    // exact conversation each `agy -c` there would reopen.
    //
    // That readability is the whole reason this is declared, and the reason it
    // does not contradict the `fork` note above, where Codex's `--last` picker
    // is refused for being a recency guess. `AntigravityResumePlan` will only
    // reach for `--continue` when it has no id at all, and only after reading
    // which conversation the entry names — so the app can say what it is about
    // to continue instead of hoping.
    continueLatest: AgentContinueSupport.flag(
      '--continue',
      scope: AgentContinueScope.workingDirectory,
      evidence:
          'agy 1.1.22 --help: "--continue  Continue the most recent '
          'conversation"; scope read from cache/last_conversations.json, the '
          '{directory: conversation id} map store.Manager.GetLastConversation '
          'resolves it through',
    ),
    // The long form, not `-i`, for the reason `--continue` is preferred over
    // its own `-c` alias above: this line is echoed into panes and copied into
    // external terminals, where a reader has to recognise it.
    //
    // Two argv entries. `agy` parses with Go's `flag` package, and passing the
    // pair joined is what the descriptor could not previously express at all —
    // the whole of this backlog item. Re-checked live rather than inherited:
    // 1.1.23's `--help` names the flag, and `agy --prompt-interactive` with no
    // value exits on `flag needs an argument: -prompt-interactive`, which is
    // what proves it carries one.
    prompt: AgentPromptSupport.flag(
      '--prompt-interactive',
      evidence:
          'agy 1.1.23 --help: "--prompt-interactive  Run an initial prompt '
          'interactively and continue the session" / "-i  Short alias for '
          '--prompt-interactive"; value-carrying confirmed by '
          '`agy --prompt-interactive` exiting on '
          '"flag needs an argument: -prompt-interactive"',
    ),
    // Checked and absent. `agy`'s only prompt options carry the text itself.
    systemPromptFile: AgentSystemPromptFileSupport.absent(
      evidence:
          'agy 1.1.27 --help: the prompt options are --prompt/--print/'
          '--prompt-interactive, each taking the text; no system-prompt or '
          'instructions file is named anywhere in the option list',
    ),
    // Left false, and now with the CLI's own words behind it rather than the
    // default. `agy` does *not* refuse a second opener — it warns, and carries
    // on: "When you opened this conversation it was already open in another CLI
    // instance on this machine. Sending messages from both may cause conflicts.
    // Use /fork to continue here separately." (1.1.22 binary.)
    //
    // A CLI that names the conflict itself is not one to opt into, so this
    // stays at the safe answer for the reason the field documents: being wrong
    // permissively means two processes writing one conversation. It is recorded
    // as *false on evidence* rather than false for want of a test.
    //
    // `resumeConflict` stays empty on purpose, and that is not the same
    // decision. Those markers are a **post-mortem for a refusal** — Codex's
    // "already has an active writer", printed as it exits. Antigravity's line
    // is a warning inside a session that goes on working, so listing it there
    // would report a live session as a failed resume.
    //
    // `missingConversation` is undeclared for the same reason, and it is the
    // near miss worth writing down. The 1.1.22 binary does carry the strings
    // `conversation not found` and "GetConversationDetail: conversation %s not
    // found locally, searching fallback import dirs" — but whether either
    // reaches the pane, and in what form, has not been observed, and the one
    // run that would settle it (`agy --conversation=<bogus uuid>`) risks
    // leaving a junk conversation in the user's own store if the CLI starts
    // fresh instead of failing. A marker that never matches costs an
    // explanation; one that matches a live session reports it as dead.
    allowsConcurrentResume: false,
    // `fork` stays unsupported, now on evidence rather than on the default:
    // `agy --help` lists every subcommand it has (agent, changelog, help,
    // install, mcp, mic-serve, models, plugin, update) and none of them forks.
    // `--continue` and `--conversation` both continue a conversation in place.
    // The CLI does carry a `/fork` **slash command** — its own warning about a
    // conversation being open twice recommends it — but a slash command is
    // typed into a running TUI, which is not something a launch can reach, so
    // it changes nothing here. The handoff route is closed too, because a
    // packet is quoted from a transcript and this agent's messages stay
    // unreadable — see `store` below.
    //
    // `mcp` stays unsupported for the same kind of reason, and stating it is
    // the point of this note. The CLI *has* MCP — `agy --help` lists an `mcp`
    // subcommand, "Manage MCP servers (add, remove, list, enable, disable)" —
    // but that edits its own config, and nothing in the option list (checked in
    // full: --add-dir, --agent, -c/--continue, --conversation,
    // --dangerously-skip-permissions, --disable-slash-commands, --effort,
    // -i/--prompt-interactive, --input-format, --json-schema, --log-file,
    // --mode, --model, --new-project, --output-format, -p/--print,
    // --print-timeout, --project, --prompt, --sandbox) points a single launch
    // at a server. Adding the block to the user's own config would be a machine
    // -wide entry that cannot name a session, which is the same thing that
    // ruled `config.toml` out for Codex. So Antigravity is launched exactly as
    // it is today — a flag invented here is how this descriptor was wrong for
    // months.
    // **Antigravity does take an in-session `/model <name>`**, and the note
    // above about `/fork` is why that has to be said explicitly: a slash
    // command the CLI has is not automatically one a program can send, and this
    // one is. The CLI's own changelog, embedded in the 1.1.23 binary, is where
    // it is stated:
    //
    //   ## 1.1.22
    //   - Added a `/model <name>` argument that switches to a model by name,
    //     slug or label and saves it as your default in one step … `/model` on
    //     its own still opens the picker, and an unrecognized name prints the
    //     valid ones.
    //
    // Corroborated by the command registry inside the same binary, where
    // `commands/model.go` declares a `CompleteArg` — the argument-completion
    // hook, which a picker-only command has no use for.
    //
    // Two properties of that sentence are load-bearing here. It "saves it as
    // your default", so a live switch and the next launch agree even before
    // this app writes the row; and an unrecognized name *prints the valid ones*
    // rather than silently doing nothing, which is the failure mode a curated
    // list has to be able to survive.
    //
    // The slugs are `agy models` ("List available models") on 2026-09-02 — the
    // one shipped agent with a first-party listing command, and the way to
    // refresh this list. They are account-specific, so an id this list does not
    // carry is still passed through rather than dropped.
    model: AgentModelSupport.liveAndAtLaunch(
      flag: '--model',
      slashCommand: '/model',
      models: [
        AgentModel(
          id: 'gemini-3.1-pro-high',
          label: 'Gemini 3.1 Pro (High)',
          summary: 'The most capable Gemini listed, at the most reasoning.',
        ),
        AgentModel(
          id: 'gemini-3.1-pro-low',
          label: 'Gemini 3.1 Pro (Low)',
          summary: 'The same model with reasoning turned down.',
        ),
        AgentModel(
          id: 'gemini-3.7-flash-high',
          label: 'Gemini 3.7 Flash (High)',
          summary: 'Newest Flash, at the most reasoning.',
        ),
        AgentModel(
          id: 'gemini-3.7-flash-medium',
          label: 'Gemini 3.7 Flash (Medium)',
          summary: 'Newest Flash, balanced.',
        ),
        AgentModel(
          id: 'gemini-3.7-flash-low',
          label: 'Gemini 3.7 Flash (Low)',
          summary: 'Newest Flash, fastest.',
        ),
        AgentModel(
          id: 'gemini-3.6-flash-high',
          label: 'Gemini 3.6 Flash (High)',
          summary: 'Previous Flash, at the most reasoning.',
        ),
        AgentModel(
          id: 'gemini-3.6-flash-medium',
          label: 'Gemini 3.6 Flash (Medium)',
          summary: 'Previous Flash, balanced.',
        ),
        AgentModel(
          id: 'gemini-3.6-flash-low',
          label: 'Gemini 3.6 Flash (Low)',
          summary: 'Previous Flash, fastest.',
        ),
        AgentModel(
          id: 'claude-opus-4-6-thinking',
          label: 'Claude Opus 4.6 (Thinking)',
          summary: 'Anthropic\'s model, served through Antigravity.',
        ),
        AgentModel(
          id: 'claude-sonnet-4-6',
          label: 'Claude Sonnet 4.6 (Thinking)',
          summary: 'Anthropic\'s model, served through Antigravity.',
        ),
        AgentModel(
          id: 'gpt-oss-120b-medium',
          label: 'GPT-OSS 120B (Medium)',
          summary: 'The open-weights option.',
        ),
      ],
      evidence:
          'agy 1.1.23 --help: "--model  Model for the current CLI session"; '
          'the in-session form from the changelog inside that binary (1.1.22: '
          '"Added a `/model <name>` argument that switches to a model by name, '
          'slug or label … `/model` on its own still opens the picker"), '
          'corroborated by commands/model.go declaring a CompleteArg; slugs '
          'from `agy models` on 2026-09-02',
    ),
  ),
  // Where the CLI keeps its data, confirmed against a live install on both
  // sides of this machine. It is **not** `.antigravity`, which is the IDE's
  // VS Code-style extensions directory; the CLI writes
  // `~/.gemini/antigravity-cli`, beside the IDE's own `antigravity-ide` — the
  // `app_data_dir` that tells them apart is visible in each one's own logs.
  //
  // The format was `none` on a finding drawn from one file. "We cannot read
  // them" was concluded from `conversations/<id>.db`, whose payload columns
  // really are protobuf in an unpublished schema, and generalised to the
  // directory. The directory also holds `cache/last_conversations.json`
  // (`{directory: conversation id}`), `annotations/<id>.pbtxt` (what `/rename`
  // wrote) and a readable `conversation_summaries.db`, and
  // `data/antigravity_store_reader.dart` reads all three.
  //
  // Leaving it at `none` after that had a cost the owner reported: detection
  // skipped this store entirely, so no Antigravity conversation could be found
  // by a store sweep, matched to a session row, or asked about before a resume.
  // `antigravityStore` is the value for a store that yields *identity* without
  // *content* — which is exactly this one.
  //
  // What remains true is the part that gates the *chat view*: message content
  // is unreadable, so there is no transcript to show, quote into a handoff
  // packet, or seed a resume from. `agentSupportsChatView` is an allowlist of
  // the two transcript formats, so declaring this one turns none of that on.
  store: AgentStoreSpec(
    homeDirectoryName: '.gemini/antigravity-cli',
    format: AgentStoreFormat.antigravityStore,
  ),
  // **Antigravity has hooks.** "Nothing can observe what a session is doing"
  // stood here until a live run disproved it, and the reason it survived so
  // long is that the CLI's `--help` says nothing about them: they are
  // documented in a skill the CLI itself ships, at
  // `~/.gemini/antigravity-cli/builtin/skills/agy-customizations/docs/hooks.md`,
  // and configured in a file no option ever names.
  //
  // Run against a throwaway `HOME` with `agy` 1.1.23, every event below fired,
  // and the payload landed on stdin as protojson:
  //
  //   {"conversationId":"594f1ab1-f352-4ce1-b92a-85dce890fcdd",
  //    "terminationReason":"NO_TOOL_CALL","fullyIdle":true,
  //    "transcriptPath":"…","workspacePaths":[]}
  //
  // The very command this app already generates for Claude Code works here
  // unaltered — it was run verbatim in that session, the payload arrived at a
  // local server, and the `{"ok":true,…}` it printed back on stdout disturbed
  // nothing. A dead port cost the agent nothing either, which is the property
  // `-s … || true` exists for.
  hooks: AgentHookSpec(
    // Not in the store home. `~/.gemini/antigravity-cli` is where the CLI keeps
    // its data; `~/.gemini/config` is the machine-local **customization root**
    // it reads hooks, MCP servers and skills from. A `hooks.json` written into
    // the store would be a file the CLI never opens.
    configFileName: '../config/hooks.json',
    // This file's top level is a map of hook *names*, not of events, so our
    // name is the key — which leaves every other tool's hooks in sibling keys
    // the splice never touches, without needing the per-event merge Claude's
    // shared `hooks` block does.
    configKey: 'karmashala',
    // `PreInvocation`, `PostInvocation` and `Stop` take the handler object
    // itself. The `{matcher, hooks}` wrapper is for the tool events, which have
    // something to match on; using it here installs a hook that never fires.
    entryStyle: AgentHookEntryStyle.flat,
    // protojson, so camelCase — nothing like Claude Code's `session_id`, and
    // this is the id `--conversation` resumes.
    sessionIdPath: ['conversationId'],
    // `workspacePaths` arrives as a list of paths; _stringAt unwraps the first
    // element when matching the candidate pane.
    cwdPath: ['workspacePaths'],
    // Descriptions for notifications and inbox: prefer error message on
    // failure, finalModelOutput on completion, or lastUserInput.
    messagePaths: [
      ['error'],
      ['finalModelOutput'],
      ['lastUserInput'],
    ],
    // **No `PreToolUse`, and that is measured rather than cautious.** A status
    // callback has no permission decision to make, so the only honest thing it
    // can answer is `{}` — and with `{}` a live run refused the tool outright:
    //
    //   Encountered error in tool execution: tool call denied by pre-tool hook
    //
    // The same session with only these three events installed called the same
    // tool and got its result back. `PreToolUse` and `PostToolUse` would be the
    // finest-grained signal available and they are left undeclared anyway: a
    // hook that changes what the agent is allowed to do is not a status hook.
    //
    // What is lost with them is `awaitingApproval`. Antigravity announces a
    // pending permission nowhere this app can hear, so that state stays
    // unreachable for this agent — see `grid`, which is empty for the same
    // reason.
    // **`Stop` is not the same thing as "finished".** Its payload carries a
    // `terminationReason`, and while this mapped `Stop` to `idle`
    // unconditionally, an `agy` run that died on an error, ran out of
    // invocations or blew its token budget arrived as "your agent finished".
    //
    // The wire spelling is prefix-stripped SCREAMING_SNAKE, established from
    // the 1.1.23 binary rather than guessed:
    //
    //  * `StopHookArgs` declares `termination_reason` as a **string** field
    //    (`protobuf:"bytes,2,opt,name=termination_reason,
    //    json=terminationReason,proto3"`), not as the enum — so the enum is
    //    converted to text before it is sent;
    //  * the enum's twelve value names are in the descriptor blob in full, all
    //    spelled `EXECUTOR_TERMINATION_REASON_*` (`…_UNSPECIFIED`, `…_ERROR`,
    //    `…_USER_CANCELED`, `…_MAX_INVOCATIONS`, `…_NO_TOOL_CALL`,
    //    `…_MAX_FORCED_INVOCATIONS`, `…_EARLY_CONTINUE`,
    //    `…_TERMINAL_STEP_TYPE`, `…_TERMINAL_CUSTOM_HOOK`,
    //    `…_INJECTED_RESPONSE`, `…_MAX_TOKEN_BUDGET_EXCEEDED`,
    //    `…_HALTED_STEP`);
    //  * **no bare spelling exists as a literal anywhere in the binary** —
    //    `strings agy | grep '^NO_TOOL_CALL$'` finds nothing — so the observed
    //    wire value cannot have come from a lookup table;
    //  * the one transformation literal that does exist is the bare prefix
    //    `EXECUTOR_TERMINATION_REASON_`, trailing underscore and all, sitting
    //    in the Go string blob beside the executor's own messages. Nothing but
    //    a `TrimPrefix` needs that string.
    //
    // The live payload captured when these hooks were first wired is exactly
    // what that derivation predicts: `"terminationReason":"NO_TOOL_CALL"`.
    eventKindPath: ['terminationReason'],
    // Six of the twelve. The other six — `UNSPECIFIED`, `HALTED_STEP`,
    // `EARLY_CONTINUE`, `INJECTED_RESPONSE`, `TERMINAL_STEP_TYPE`,
    // `TERMINAL_CUSTOM_HOOK` — are left undeclared because nothing here knows
    // whether they end a run well or badly, and an undeclared subtype resolves
    // to `unknown`, which is not recorded and so leaves the session saying
    // whatever it last said. That is the direction to be wrong in: guessing
    // `idle` is what tells a user their work is done.
    eventKindMeaning: {
      // The captured one: the model answered without calling a tool, which is
      // how an ordinary turn ends. No `ending`: `agy` fires this on every turn
      // and the conversation is still open afterwards.
      'NO_TOOL_CALL': AgentHookMeaning(AgentActivityStatus.idle),
      // The user stopped it themselves. Not a failure — they are already
      // looking at the session — and not an ending either: whoever stopped it
      // wrote the row's word already.
      'USER_CANCELED': AgentHookMeaning(AgentActivityStatus.idle),
      'ERROR': AgentHookMeaning(
        AgentActivityStatus.failed,
        fallbackMessage: 'Execution failed',
        ending: AgentSessionEnding.failed,
      ),
      // The run hit a ceiling with work outstanding. The CLI's own shipped
      // hooks doc calls this family "stopped due to error" and puts an `error`
      // string beside it.
      'MAX_INVOCATIONS': AgentHookMeaning(
        AgentActivityStatus.failed,
        fallbackMessage: 'Maximum invocations reached',
        ending: AgentSessionEnding.failed,
      ),
      'MAX_FORCED_INVOCATIONS': AgentHookMeaning(
        AgentActivityStatus.failed,
        fallbackMessage: 'Maximum forced invocations reached',
        ending: AgentSessionEnding.failed,
      ),
      'MAX_TOKEN_BUDGET_EXCEEDED': AgentHookMeaning(
        AgentActivityStatus.failed,
        fallbackMessage: 'Maximum token budget exceeded',
        ending: AgentSessionEnding.failed,
      ),
    },
    // `PreInvocation` and `PostInvocation` payloads carry no
    // `terminationReason`, so they fall through to these untouched — the
    // property that makes reading the subtype a descriptor-only change.
    eventStatus: {
      'SessionStart': AgentActivityStatus.working,
      'PreInvocation': AgentActivityStatus.working,
      'PostInvocation': AgentActivityStatus.working,
      'Stop': AgentActivityStatus.idle,
    },
  ),
  statusStrategy: AgentStatusStrategy.hooks,
  // `approval` is left empty on purpose. The 1.0.13 build wrote a
  // `keybindings.json` binding `confirm.yes` to `y` and `confirm.no` to `n`,
  // which looked like the best-sourced approval keys in this file — but 1.1.23
  // ships no such file, so those keys describe a version nobody is running.
  // Pressing a guessed key into a TUI is the one failure worse than sending the
  // user to the terminal, so nothing is declared.
  // Nothing is known. `agy` writes protobuf into a store whose schema is not
  // published and which this app reads none of, so there is no evidence either
  // way — and §19's rule is that an unknown is never reported as a zero, nor
  // as a yes.
  attachments: AgentAttachmentSupport.none(
    refusal: 'Nobody here has seen Antigravity open a file named in a prompt.',
  ),
  // **Measured, not assumed absent.** Its store was read on 2026-09-08: 21
  // conversations, 4,451 steps, and the whole tool vocabulary its own calls
  // name is view_file, run_command, grep_search, replace_file_content,
  // manage_task, find_by_name, schedule, search_web, list_dir, call_mcp_tool,
  // write_to_file — no plan or todo tool anywhere in it. `manage_task` and the
  // `steps.task_details` column beside it look like the thing and are not: both
  // describe a **background shell command** (a task id, a log file URL and the
  // command line), which is what `schedule` starts. **136 `manage_task` calls
  // read 2026-09-09**, every one of them `{Action, TaskId}`.
  // The refusal names two files because it took two to answer. The store's own
  // `conversations/<id>.db` is protobuf in an unpublished schema, so a plan
  // written in prose there would be unreadable; the JSONL transcript beside it
  // — present for all 25 WSL conversations, absent on Windows — is readable and
  // has no plan tool in it. So neither file has a plan to read, and this is no
  // longer "the finding `agentSupportsChatView` refuses this agent for": that
  // allowlist is now only the prior to a per-session reading.
  plan: AgentPlanSupport.none(
    refusal:
        'Antigravity keeps no plan we can read: the conversation file its '
        'store indexes is protobuf in an unpublished schema, and the readable '
        'JSONL transcript beside it, where one exists, names no plan tool — '
        'its 136 `manage_task` calls are all `{Action, TaskId}` for a '
        'background shell command — so there is no plan to read either way.',
  ),
  // Not under this agent's store home: sessions are in `.gemini/antigravity-cli`
  // and skills are in `.gemini/config`, which is why the root is home-relative.
  skills: AgentSkillSupport.homeDirectory(
    ['.gemini', 'config', 'skills'],
    evidence:
        'agy 1.1.27: the binary carries the literal '
        '`~/.gemini/config/skills/<name>/SKILL.md`, and its bundled '
        'agy-customizations skill names ~/.gemini/config/ as the global '
        'discovery root. Read 2026-09-09.',
  ),
);
