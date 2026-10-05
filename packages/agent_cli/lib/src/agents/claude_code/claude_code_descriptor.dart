import '../../permissions/permission_risk.dart';
import '../domain/agent_descriptor.dart';
import '../domain/agent_mcp_config.dart';
import '../domain/agent_plan.dart';
import '../domain/agent_plan_approval.dart';
import '../domain/agent_question.dart';
import '../domain/agent_screen_menu.dart';
import '../domain/agent_permission_support.dart';
import '../domain/agent_skill_support.dart';
import '../domain/agent_status.dart';

/// What Claude Code is, as data: how to find, launch and observe it.
/// One part of its adapter.
const claudeCodeDescriptor = AgentDescriptor(
  id: 'claudeCode',
  displayName: 'Claude Code',
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
    // Set by a running Claude Code for its children (observed 2.1.282). One
    // inherited by a pane Karmashala launches makes that Claude a child
    // session: `CLAUDE_CODE_CHILD_SESSION` turns transcript saving off, so the
    // conversation can never be resumed.
    parentSessionEnvironment: {
      'CLAUDECODE',
      'CLAUDE_CODE_ENTRYPOINT',
      'CLAUDE_CODE_EXECPATH',
      'CLAUDE_CODE_SESSION_ID',
      'CLAUDE_CODE_CHILD_SESSION',
      'CLAUDE_CODE_SESSION_ATTENDED',
      'CLAUDE_CODE_MESSAGING_SOCKET',
      'CLAUDE_CODE_MESSAGING_TOKEN',
      'CLAUDE_PID',
    },
    baseArguments: [
      '--input-format',
      'stream-json',
      '--output-format',
      'stream-json',
      '--verbose',
    ],
    // A native Claude Code install updates itself in the background — a startup
    // and periodic check that downloads and installs a new build. Under an
    // unsigned parent that is a behavioural-antivirus dropper signal, so the
    // launched process is given DISABLE_AUTOUPDATER=1, the documented switch
    // that stops the background check while leaving `claude update` working.
    selfUpdate: AgentSelfUpdate.declared(
      disableEnvironment: {'DISABLE_AUTOUPDATER': '1'},
      updateCommand: ['claude', 'update'],
      latestVersion: AgentLatestVersionSource.npm(
        '@anthropic-ai/claude-code',
        evidence:
            'registry.npmjs.org/@anthropic-ai/claude-code/latest answered '
            '"version":"2.1.283" on 2026-09-28; the native installer and '
            '`claude update` ship the same numbers.',
      ),
      evidence:
          'code.claude.com/docs setup ("Disable auto-updates": set '
          'DISABLE_AUTOUPDATER to "1" in settings env; only stops the '
          'background check, `claude update` still works) and env-vars page; '
          'manual update `claude update`. Verified 2026-09-17.',
    ),
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
      live: AgentPermissionLiveCycle(
        axisId: 'mode',
        key: '\x1b[Z',
        order: ['manual', 'acceptEdits', 'plan', 'bypassPermissions', 'auto'],
        indicators: {
          'acceptEdits': 'accept edits on',
          'plan': 'plan mode on',
          'auto': 'auto mode on',
          'bypassPermissions': 'bypass permissions',
        },
        // Bypass is left to a confirmed relaunch, and `dontAsk` is not in the
        // cycle at all: it only ever steps back to the default.
        reachable: {'manual', 'acceptEdits', 'plan', 'auto'},
        evidence:
            'claude 2.1.280 bundle, xlt(): default→acceptEdits→plan→'
            '(bypassPermissions when available)→(auto when available)→default, '
            'dontAsk→default, bound to chat:cycleMode (Shift+Tab); the status '
            'strings "accept edits on", "plan mode on", "auto mode on"',
      ),
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
              description: 'Research and propose changes without making them.',
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
              description: 'Auto-approve file edits and common file commands.',
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
    // So a brief it is told to read from Karmashala's data directory does not
    // stop it on a Read approval (probe, 2026-10-04: a subagent child in ask
    // mode). Joined with `=`: the option is variadic and would take the
    // positional prompt after it as a second directory.
    extraDirectory: AgentExtraDirectorySupport.joined(
      '--add-dir',
      evidence:
          'claude 2.1.287 (Windows claude.exe) --help: '
          '"--add-dir <directories...>  Additional directories to allow tool '
          'access to"',
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
          'prompt file not found: C:\\kw\\nope-does-not-exist.md"; '
          'claude 2.1.287 --help: "--append-system-prompt <prompt>  Append a '
          'system prompt to the default system prompt"',
      textToken: '--append-system-prompt',
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
    // A session sent to the background runs under `claude daemon` and a
    // resume of it is refused; `claude agents --json` names it and
    // `claude attach <id>` opens it.
    backgroundSessions: AgentBackgroundSessions.listed(
      listArguments: ['agents', '--json'],
      attachToken: 'attach',
      evidence:
          'claude 2.1.280 (WSL), 2026-09-30: `claude agents --json` printed '
          '{"id":"2360c006","kind":"background","sessionId":"2360c006-…"} '
          'for a conversation whose `--resume` exited 1 with "is running as '
          'a background session (2360c006). Run `claude attach 2360c006` to '
          'open it"; `claude attach --help`: "Open the background session in '
          'this terminal"',
    ),
    // The folder-trust question a first launch in a directory stops at,
    // captured whole in `test/features/agents/fixtures/
    // claude-code-trust-prompt.raw` and seen again live on 2026-09-25 when an
    // automation's Claude sat at it for minutes in a fresh checkout:
    //
    //   Quick safety check: Is this a project you created or one you trust?
    //   ❯ 1. No, exit
    //     2. Yes, I trust this folder
    //   Enter to confirm · Esc to cancel
    //
    // Either line is the question; `Enter to confirm` alone is not, since the
    // tool-permission modal shares it.
    firstRunPrompt: AgentFirstRunPromptRules(
      markers: [
        GridMatcher('Is this a project you created or one you trust'),
        GridMatcher('Yes, I trust this folder'),
      ],
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
    // A recap is written by a **second process**, not by the running session:
    // print mode starts the same binary, reads the conversation and exits, so
    // nothing is typed into the pane the user left open. See
    // [AgentRecapSupport].
    recap: AgentRecapSupport.overStdin(
      ['-p'],
      evidence:
          'claude 2.1.266 --help: "Claude Code - starts an interactive session '
          'by default, use -p/--print for non-interactive output" / '
          '"-p, --print  Print response and exit (useful for pipes)". stdin is '
          'what print mode reads: "--input-format <format>  Input format (only '
          'works with --print): \'text\' (default), or \'stream-json\'". '
          'Measured 2026-09-09 against a throwaway two-turn transcript: '
          '`claude -p` with the conversation piped answered out of the piped '
          'text and nothing else.',
    ),
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
    homeVariable: 'CLAUDE_CONFIG_DIR',
    // Keyed per git root, read from 2.1.287's own check.
    folderTrust: AgentFolderTrustSpec(
      format: AgentFolderTrustFormat.jsonProjects,
      settingsFile: '../.claude.json',
    ),
  ),
  statusStrategy: AgentStatusStrategy.hooks,
  hooks: AgentHookSpec(
    configFileName: 'settings.json',
    // A subagent's events carry the parent's session_id and their own
    // agent_id (captured below).
    subagentIdPath: ['agent_id'],
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
    // guessing at. The idle nudge reads as idle here too, as `idle_prompt`
    // does below.
    messageMeaning: {
      'needs your permission': AgentHookMeaning(
        AgentActivityStatus.awaitingApproval,
        waiting: AgentWaitKind.approval,
      ),
      'waiting for your input': AgentHookMeaning(AgentActivityStatus.idle),
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
      // The 60-second nudge after a turn ends: "Claude is waiting for your
      // input". **Idle, not a prompt.** The agent finished its turn and sits
      // at its own composer; nothing is open to answer. Read as
      // `awaitingApproval` it put every finished session in the inbox as
      // "needs you" a minute after its turn (found live on a phone, 2.1.283,
      // 2026-09-26), and on the desktop `session_wait` answered
      // `awaitingApproval` for a session at rest. The turn's own `Stop` has
      // already said idle; this repeats it.
      'idle_prompt': AgentHookMeaning(AgentActivityStatus.idle),
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
    inFlightPath: {
      'Stop': ['background_tasks'],
    },
    // 2.1.283's entry: `description` always, `command` for a shell.
    inFlightLabelPaths: [
      ['description'],
      ['command'],
      ['type'],
    ],
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
    // **The one event that speaks for the session rather than the turn**: the
    // CLI on its way out. `Stop` is absent because it fires once per turn, and
    // `StopFailure` for the same reason — it fires *instead of* `Stop` when an
    // API error broke a turn, and the session goes on. Recording it as an
    // ending marked a live session `failed` for the rest of its life: the row
    // is then `isEnded`, so nothing later can correct it, and a rate limit at
    // hour one filed an eight-hour session under "ended in failure".
    eventEnding: {'SessionEnd': AgentSessionEnding.completed},
    // **Except that `SessionEnd` also fires for a `/clear` and a `/resume`**,
    // for the conversation being left, and the CLI carries on in the pane.
    // 2.1.274's schema: `reason` is one of `clear`, `resume`, `logout`,
    // `prompt_input_exit`, `other`; the exit path defaults to `other`.
    endingReasonPath: ['reason'],
    conversationOnlyEndReasons: {'clear', 'resume'},
    // `StopFailure`'s own field; `rate_limit` is how a usage limit is told
    // from an overload, which both arrive as the one event.
    failureReasonPath: ['error'],
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
    // AskUserQuestion's footer, read off 2.1.274 in a real ConPTY: one
    // question reads 'Enter to select · ↑/↓ to navigate · Esc to cancel',
    // several 'Enter to select · Tab/Arrow keys to navigate · Esc to cancel'.
    question: [GridMatcher('Enter to select')],
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
      // The plan prompt, whose 2.1.287 footer names neither key ("ctrl+g to
      // edit in Notepad · <plan file>"; probe, 2026-10-04).
      GridMatcher('Would you like to proceed?'),
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
      // The default mode's own footer on 2.1.280, which names no cycle key:
      // `⏸ manual mode on` (read off a host recording, 2026-09-23). Mid-turn
      // it gains `esc to interrupt`, which the working rule reads first.
      GridMatcher('manual mode on'),
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
  // AskUserQuestion, answered by the keys measured against 2.1.274 in a real
  // ConPTY (claudeQuestionKeys says what each one does). Declining is the
  // same Esc that cancels any prompt; the transcript then records "User
  // declined to answer questions".
  questions: AgentQuestionSupport(
    toolName: 'AskUserQuestion',
    hookEvent: 'PreToolUse',
    keysFor: claudeQuestionKeys,
    declineKeys: '\x1b',
    // Drawn below the answers on 2.1.274 and 2.1.287 (probe, 2026-10-04).
    chatRow: 'Chat about this',
  ),
  // Measured on 2.1.274 (folder trust, permission, MCP server): `❯ ` marks the
  // highlighted row, ↓/↑ move it, Enter confirms it.
  //
  // Approve and deny on a menu pick an option by its words, because Enter
  // alone confirms the highlight and folder trust highlights `No, exit`. The
  // words, as drawn (packages/agent_cli/test/agents/screen_menu_test.dart and
  // the captured fixtures): folder trust `No, exit` / `Yes, I trust this
  // folder`; a tool permission `1. Yes` / `2. Yes, and …` / `3. No` (the plain
  // `Yes` is first, so it is the one approve picks); a project MCP server
  // `Use this MCP server` / `Use this and all future …` / `Continue without
  // using this MCP server`. `^Continue` is deliberately NOT affirmative here:
  // on that last menu it is the refusal.
  //
  // Esc on a tool permission (`Do you want to proceed?`, `Do you want to
  // create note.txt?` — footer `Esc to cancel`) declines the tool call and
  // leaves Claude running, so deny keeps pressing it there. On folder trust
  // Esc exits Claude Code exactly as `No, exit` does, so deny picks the row
  // and says so.
  menus: AgentMenuSupport(
    markers: ['❯'],
    affirmative: [r'^Yes\b', r'^Use this MCP server$'],
    negative: [r'^No\b', r'^Continue without using this MCP server\b'],
    cancelDeclines: ['Do you want to'],
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
  terminal: AgentTerminalRules(
    clusterWidthFromBase: true,
    typedTextArrivesWhole: true,
    // 2.1.287 answered a typed opening that was only a paste with "Your
    // message is only pasted text … I'm not treating the steps in it as your
    // instructions until you confirm" (probe, 2026-10-04).
    typedOpeningLeadIn: 'Please carry out this request: ',
    takesInputMidTurn: true,
    evidence:
        'A message typed while Claude Code works is queued by it and taken at '
        'its next step (the owner, 2026-10-05). '
        'Claude Code lays its screen out with string-width, which gives a '
        'Devanagari cluster its first code point\'s width; panes measured the '
        'default way garbled its redraws (owner, 2026-09-30; xterm2 '
        'divergence 15). A 34-line message with quotes and %VAR% typed into '
        'claude 2.1.287 on a Windows ConPTY, raw or as a bracketed paste, '
        'showed as [Pasted text #1] and was recorded whole as the user turn '
        '(server/test/live/claude_paste_live_test.dart, 2026-10-04).',
  ),
  // WSL keeps `ctrl+v`: Claude Code binds it there as well as `alt+v`, and it
  // is what already worked.
  imagePaste: AgentImagePasteKey(
    windowsNative: AgentImagePasteKey.altV,
    evidence:
        'claude.exe 2.1.284 keybindings: xe=(windows||wsl)?"alt+v":"ctrl+v", '
        '[xe]:"chat:imagePaste", and "ctrl+v":"chat:imagePaste" under wsl only',
  ),
  // The whole declaration, with the counts it was read off, is at
  // [kClaudeCodeTodoWrite]. It is not inlined here because the transcript
  // reader looks the same value up by tool name, and two copies of a schema is
  // how one of them goes stale.
  plan: kClaudeCodeTodoWrite,
  // Keep planning by its words: the decline picks the first `^No`, and the
  // Ultraplan row can come before it.
  planApproval: AgentPlanApprovalSupport(
    toolName: 'ExitPlanMode',
    // Its label, or the placeholder 2.1.287 draws in its place; Enter on it
    // empty rejects the plan and stays in plan mode (probe, 2026-10-04).
    keepPlanningOption: r'^(No, keep planning|Tell Claude what to change)\b',
    // The yeses by what they switch to (the axis below). Bypass is checked
    // before auto, and either before "accept edits", whose words the first
    // two can contain.
    approveOptions: {
      r'^Yes\b.*bypass permissions': 'bypassPermissions',
      r'^Yes\b.*auto mode': 'auto',
      r'^Yes\b.*accept edits': 'acceptEdits',
      r'^Yes\b.*manually approve edits': 'manual',
    },
    skippedOptions: [r'clear context'],
    evidence:
        'claude.exe 2.1.287 string table, read 2026-10-04: "Would you like to '
        'proceed?" with yes-* options, an optional "No, refine with Ultraplan '
        'in a cloud session", then "No, keep planning" (an input row, '
        'placeholder "Tell Claude what to change"); ExitPlanMode input `plan`; '
        'yes labels "Yes, and use auto mode", "Yes, auto-accept edits", "Yes, '
        'manually approve edits", values yes-resume-auto-mode / '
        'yes-accept-edits / yes-default-keep-context / yes-auto-clear-context',
  ),
  skills: AgentSkillSupport.homeDirectory(
    ['.claude', 'skills'],
    projectDirectorySegments: ['.claude', 'skills'],
    evidence:
        'claude 2.1.263: --safe-mode names skills among the customizations it '
        'disables, and ~/.claude/skills/pinokio/SKILL.md is one already '
        'installed at user level on this machine. Read 2026-09-09. The project '
        'root is the 2.1.270 binary\'s own `.claude/skills/<name>/SKILL.md`, '
        'beside `~/.claude/skills/` as two separate discovery roots.',
  ),
  mcpConfig: AgentMcpConfigSpec.json(
    projectFileName: '.mcp.json',
    projectServersPath: ['mcpServers'],
    // Store-home-relative, and it walks out: the store is `~/.claude` and the
    // config is `~/.claude.json` beside it.
    userFileName: '../.claude.json',
    userServersPath: ['mcpServers'],
    perProjectKey: 'projects',
    perProjectServersPath: ['mcpServers'],
    approvedKey: 'enabledMcpjsonServers',
    refusedKey: 'disabledMcpjsonServers',
    evidence:
        'claude 2.1.270 on this machine: ~/.claude.json holds `mcpServers` at '
        'its top level (the three this session was started with) and one entry '
        'per directory under `projects`, each with its own `mcpServers`, '
        '`enabledMcpjsonServers` and `disabledMcpjsonServers`; the binary '
        'carries the literal `.mcp.json`. Read 2026-09-13.',
  ),
);
