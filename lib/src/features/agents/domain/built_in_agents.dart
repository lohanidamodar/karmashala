import '../../settings/domain/permission_mode.dart';
import 'agent_descriptor.dart';
import 'agent_kind.dart';
import 'agent_status.dart';

/// The agents Chitragupta ships knowledge of.
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
  binaries: AgentBinaries(windows: ['claude'], posix: ['claude']),
  launch: AgentLaunchSpec(
    baseArguments: [
      '--input-format',
      'stream-json',
      '--output-format',
      'stream-json',
      '--verbose',
    ],
    permissionModes: {
      // `manual` — the CLI's alias for the config value `default` — is the
      // mode that stops and asks before edits, commands and network access.
      //
      // **Passing nothing is not the same thing.** Which mode an unflagged
      // session starts in depends on the account: Claude Code 2.1.228+ starts
      // Pro/Max/Team sessions in `auto`, where a classifier reviews each action
      // instead of prompting, and only falls back to `default` for Enterprise,
      // API-key, `-p` and cloud-platform sessions.
      //
      // So the previous empty mapping was Loop 31 §4's worst case made real:
      // the user picked the *safest* mode, we passed no flag, and a Pro account
      // silently ran under `auto`. Naming the mode costs one flag and makes the
      // choice true for every account.
      //
      //   $ claude --permission-mode manual -p 'reply with the single word OK'
      //   OK
      //
      // Verified against 2.1.251, which also rejects an unknown value outright,
      // so this is a name the CLI really has.
      PermissionMode.ask: PermissionModeMapping.exact([
        '--permission-mode',
        'manual',
      ]),
      PermissionMode.acceptEdits: PermissionModeMapping.exact([
        '--permission-mode',
        'acceptEdits',
      ]),
      PermissionMode.bypass: PermissionModeMapping.exact([
        '--permission-mode',
        'bypassPermissions',
      ]),
    },
    resume: AgentResume.flag('--resume'),
    interactiveResume: AgentResume.flag('--resume'),
    // `claude --session-id <uuid>` pins the CLI's session id to one we choose.
    // Chitragupta's own session ids are already RFC-4122 v4, so one string is
    // both — which is what makes a PTY-hosted Claude session's transcript
    // locatable at launch instead of guessed at afterwards.
    sessionIdAssignment: AgentSessionIdAssignment.flag('--session-id'),
    // `claude [prompt]` — verified against v2.1.251.
    acceptsPromptArgument: true,
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
    //     {"name":"grafana"…},{"name":"chitragupta"…},
    //     {"name":"claude.ai Google Drive"…}]
    //
    // Four of the user's five servers plus ours. `--strict-mcp-config` is
    // therefore never passed: it would silently drop the user's MCP setup for
    // every session Chitragupta opens.
    mcp: AgentMcpSupport.configFile(
      flag: '--mcp-config',
      evidence:
          'claude 2.1.251 --help: "--mcp-config <configs...>  Load MCP servers '
          'from JSON files or strings (space-separated)"; merge verified by '
          'the init message above listing our server alongside the four '
          'already configured',
    ),
  ),
  store: AgentStoreSpec(
    homeDirectoryName: '.claude',
    format: AgentStoreFormat.claudeJsonl,
  ),
  statusStrategy: AgentStatusStrategy.hooks,
  hooks: AgentHookSpec(
    configFileName: 'settings.json',
    // Claude Code's `Notification` payload carries a `message` describing what
    // it wants. It was decoded for the session id and dropped, which is why the
    // app could say an approval was pending and never what for.
    messagePath: ['message'],
    // `Notification` is fired for two unrelated things — "Claude needs your
    // permission to use Bash", and the 60-second nudge "Claude is waiting for
    // your input" after a turn ends. Both used to arrive as `awaitingApproval`
    // with an Approve button that types Enter, which at an idle prompt submits
    // the composer instead of confirming anything.
    messageWaiting: {
      'needs your permission': AgentWaitKind.approval,
      'waiting for your input': AgentWaitKind.input,
    },
    eventStatus: {
      'UserPromptSubmit': AgentActivityStatus.working,
      'PreToolUse': AgentActivityStatus.working,
      'PostToolUse': AgentActivityStatus.working,
      'Notification': AgentActivityStatus.awaitingApproval,
      'Stop': AgentActivityStatus.idle,
      'SessionEnd': AgentActivityStatus.idle,
    },
  ),
  // A transcript ending in an assistant record is a finished turn; one ending
  // in a user record (a prompt or a tool result) means the agent is mid-turn.
  stateFile: AgentStateFileRules(
    idle: [
      StateRecordMatcher(['type'], 'assistant'),
    ],
    working: [
      StateRecordMatcher(['type'], 'user'),
    ],
  ),
  // Read off Claude Code v2.1.251's own footer, captured from a real PTY run
  // (`test/features/agents/fixtures/claude-code-*.raw`). Working and idle differ
  // by one segment of the same line, which is why the order matters more than
  // the patterns: `esc to interrupt` is checked before the footer that is always
  // there.
  grid: AgentGridRules(
    awaitingApproval: [
      // The trust and permission modals both end in this pair.
      GridMatcher('Enter to confirm'),
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
);

const _codex = AgentDescriptor(
  id: 'codex',
  displayName: 'Codex CLI',
  kind: AgentKind.codex,
  binaries: AgentBinaries(windows: ['codex'], posix: ['codex']),
  launch: AgentLaunchSpec(
    baseArguments: ['app-server'],
    permissionModes: {
      PermissionMode.ask: PermissionModeMapping.exact([
        '--ask-for-approval',
        'on-request',
      ]),
      // Codex has no accept-edits mode. It splits the question in two — a
      // *sandbox* decides what may be written, an *approval policy* decides
      // what must be asked — so the nearest thing takes one flag from each:
      // `workspace-write` lets it edit files in the working tree without
      // asking, and the approval policy still escalates commands.
      //
      // **This value has now been wrong twice, on two different CLI versions,
      // and both times the symptom was the agent refusing to launch.** Loop 49
      // replaced `on-failure` (rejected by 0.145.0) with `untrusted`; 0.151.0
      // has since removed `untrusted` too:
      //
      //   $ codex --sandbox workspace-write --ask-for-approval untrusted \
      //       exec 'reply with the single word PONG'
      //   error: invalid value 'untrusted' for '--ask-for-approval <APPROVAL_POLICY>'
      //     [possible values: on-request, never]
      //
      // `on-request` is the only remaining value that is not *more* permissive
      // than accept-edits (`never` asks for nothing at all, which is the wrong
      // direction for a mode the user picked to stay in control of commands).
      // Verified to launch on 0.151.0:
      //
      //   $ codex --sandbox workspace-write --ask-for-approval on-request \
      //       exec --skip-git-repo-check 'reply with the single word PONG'
      //   sandbox: workspace-write [workdir, /tmp, $TMPDIR]
      //   codex
      //   PONG
      //
      // The lesson Loop 49 drew still holds and is worth restating: no unit
      // test can catch this, because the flag is asserted against a string
      // literal that is itself the mistake. Only running the CLI can.
      PermissionMode.acceptEdits: PermissionModeMapping.approximate(
        ['--sandbox', 'workspace-write', '--ask-for-approval', 'on-request'],
        note:
            'Codex has no accept-edits mode. The nearest lets it write inside '
            'the working tree without asking, and leaves commands under the '
            'same on-request approval policy as "Ask every time".',
      ),
      PermissionMode.bypass: PermissionModeMapping.exact([
        '--dangerously-bypass-approvals-and-sandbox',
      ]),
    },
    resume: AgentResume.flag('--resume'),
    // Interactively Codex resumes with a subcommand, not a flag.
    interactiveResume: AgentResume.subcommand('resume'),
    // `codex [OPTIONS] [PROMPT]` — verified against 0.146.
    acceptsPromptArgument: true,
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
    //   $ codex mcp list -c mcp_servers.chitragupta.url=http://…/mcp/TOK
    //   Name           Command …
    //   agent-browser  …/agent-browser.exe  mcp  …  enabled
    //
    //   Name         Url                       …
    //   chitragupta  http://…/mcp/TOK          …  enabled
    //
    // **Writing the block into `config.toml` instead was rejected**, and not
    // only because editing a user's config file is invasive. That file holds
    // one `[mcp_servers.chitragupta]` for the whole machine, so it can carry
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
      urlKey: 'mcp_servers.chitragupta.url',
      evidence:
          'codex-cli 0.151.0 --help: "-c, --config <key=value>  Override a '
          'configuration value that would otherwise be loaded from '
          '`~/.codex/config.toml`"; `codex mcp add --url` documents `url` as '
          'the streamable-HTTP key, and `codex mcp list -c '
          'mcp_servers.chitragupta.url=…` lists it beside the user\'s own',
    ),
  ),
  store: AgentStoreSpec(
    homeDirectoryName: '.codex',
    format: AgentStoreFormat.codexRollout,
  ),
  // Codex configures notifications through TOML, not a JSON hook file, so its
  // best available source today is the rollout file.
  statusStrategy: AgentStatusStrategy.stateFile,
  stateFile: AgentStateFileRules(
    idle: [
      StateRecordMatcher(['payload', 'role'], 'assistant'),
    ],
    working: [
      StateRecordMatcher(['payload', 'role'], 'user'),
      // Best-effort: a non-message payload mid-rollout means work in progress.
      StateRecordMatcher(['payload', 'type'], 'function_call'),
      StateRecordMatcher(['payload', 'type'], 'function_call_output'),
      StateRecordMatcher(['payload', 'type'], 'reasoning'),
    ],
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
    permissionModes: {
      // No flag, and unlike the old empty mappings this one is *exact* rather
      // than absent. `--dangerously-skip-permissions` is documented as the way
      // to stop the CLI prompting, which makes prompting the unflagged
      // behaviour in the CLI's own words.
      //
      // Claude Code's entry above warns that "passing nothing" can quietly mean
      // something else per account, and that warning is why this note exists
      // rather than a bare `exact([])`: what is verified is the help text, not
      // an observed session.
      PermissionMode.ask: PermissionModeMapping.exact(
        [],
        note:
            'Antigravity prompts before tool use unless it is told not to, so '
            '"Ask every time" is its own default and needs no flag.',
      ),
      PermissionMode.acceptEdits: PermissionModeMapping.exact([
        '--mode',
        'accept-edits',
      ]),
      PermissionMode.bypass: PermissionModeMapping.exact([
        '--dangerously-skip-permissions',
      ]),
    },
    // `--conversation  Resume a previous conversation by ID`. One convention
    // for both launches: unlike Codex there is no separate subcommand form, so
    // the headless and interactive resumes are the same flag.
    //
    // Interactive resume is the entry that was missing rather than wrong.
    // `interactiveResume` drives `interactiveAgentArguments`, and left at the
    // default it meant a pane could never continue an Antigravity conversation
    // at all, whatever the rest of the registry said.
    resume: AgentResume.flag('--conversation'),
    interactiveResume: AgentResume.flag('--conversation'),
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
    // Left false, and this one is a real distinction rather than caution. The
    // CLI does take an opening prompt, but as `-i` / `--prompt-interactive
    // <prompt>` — a flag with a value, not the trailing positional this field
    // means. Declaring it true would append the message as a bare argument,
    // which is not how this CLI reads it. Delivering a first message to an
    // Antigravity pane needs the descriptor to be able to express a
    // prompt-carrying *flag*; see the follow-up in
    // `docs/ANTIGRAVITY_SUPPORT_2026-08-31.md`.
    acceptsPromptArgument: false,
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
    configKey: 'chitragupta',
    // `PreInvocation`, `PostInvocation` and `Stop` take the handler object
    // itself. The `{matcher, hooks}` wrapper is for the tool events, which have
    // something to match on; using it here installs a hook that never fires.
    entryStyle: AgentHookEntryStyle.flat,
    // protojson, so camelCase — nothing like Claude Code's `session_id`, and
    // this is the id `--conversation` resumes.
    sessionIdPath: ['conversationId'],
    // `workspacePaths` arrives as `[]` from the CLI, so there is nothing to
    // read. Adoption falls back to the oldest unclaimed pane, which costs
    // precision and never correctness.
    cwdPath: [],
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
    eventStatus: {
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
);
