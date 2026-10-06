import '../../permissions/permission_risk.dart';
import '../domain/agent_descriptor.dart';
import '../domain/agent_mcp_config.dart';
import '../domain/agent_plan.dart';
import '../domain/agent_screen_menu.dart';
import '../domain/agent_permission_support.dart';
import '../domain/agent_skill_support.dart';
import '../domain/agent_status.dart';

/// What Codex is, as data: how to find, launch and observe it.
/// One part of its adapter.
const codexDescriptor = AgentDescriptor(
  id: 'codex',
  displayName: 'Codex CLI',
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
    // Codex checks for an update at startup and, on "Update now" or `codex
    // update`, replaces its own executable — an npm/installer self-update that
    // behavioural antivirus reads as the tail of a dropper chain. The global
    // `-c check_for_update_on_startup=false` suppresses the check (the popup
    // and banner); it does not touch `codex update`, and the `app-server` here
    // does not check for updates at all, so it is a belt-and-braces override.
    selfUpdate: AgentSelfUpdate.declared(
      disableArguments: ['-c', 'check_for_update_on_startup=false'],
      updateCommand: ['codex', 'update'],
      latestVersion: AgentLatestVersionSource.npm(
        '@openai/codex',
        evidence:
            'registry.npmjs.org/@openai/codex/latest answered '
            '"version":"0.158.0" on 2026-09-28; the standalone installer and '
            '`codex update` ship the same numbers.',
      ),
      evidence:
          'openai/codex config.toml key check_for_update_on_startup (default '
          'true; codex-rs/config/src/config_toml.rs, core/src/config/mod.rs '
          'unwrap_or(true)), a -c global override (utils/cli config_override); '
          '`codex update` subcommand (cli/src/main.rs, docs config-reference). '
          'Verified against rust-v0.154.0, 2026-09-17. app-server itself does '
          'not check (only tui/src/updates.rs does); the standalone daemon '
          'updater is separate and unaffected by this key.',
    ),
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
      // Opens its own picker ("/permissions - choose what Codex is allowed to
      // do", codex-cli 0.155.0's slash table); it takes no argument.
      pickerCommand: '/permissions',
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
    // So a packet it is told to read from Karmashala's data directory is in
    // its own sandbox: under on-request approvals it asked before reading a
    // file outside the workspace (probe, 2026-10-03). A top-level option,
    // so it stands left of `resume` like the permission flags.
    extraDirectory: AgentExtraDirectorySupport.flag(
      '--add-dir',
      evidence:
          'codex 0.153.4 --help lists --add-dir among its top-level options '
          '(the list above), one directory per flag',
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
    // The directory-trust question Codex 0.146.0 would not start without,
    // captured in `test/features/agents/fixtures/codex-approval-prompt.raw`:
    // "Do you trust the contents of this directory? … › 1. Yes, continue
    // 2. No, quit · Press enter to continue". `Press enter to continue` alone
    // is not it — the update offer shares that footer.
    firstRunPrompt: AgentFirstRunPromptRules(
      markers: [GridMatcher('Do you trust the contents of this directory')],
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
    // The only one of the three whose `--help` states the stdin contract in
    // full, including what a prompt *and* a pipe together do — which is the
    // shape a recap uses: the fixed request as the argument, the conversation
    // on stdin.
    recap: AgentRecapSupport.overStdin(
      ['exec'],
      evidence:
          'codex exec --help (codex-cli 0.153.4): "Run Codex '
          'non-interactively" / "[PROMPT]  Initial instructions for the agent. '
          'If not provided as an argument (or if `-` is used), instructions are '
          'read from stdin. If stdin is piped and a prompt is also provided, '
          'stdin is appended as a `<stdin>` block". Read 2026-09-09.',
    ),
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
      // Takes no argument: it opens the picker `model_popups.rs` draws, where
      // the person chooses. Orca does the same (read 2026-09-23).
      pickerCommand: '/model',
    ),
  ),
  store: AgentStoreSpec(
    homeDirectoryName: '.codex',
    homeVariable: 'CODEX_HOME',
    // What 0.160.0 writes when its trust prompt is answered.
    folderTrust: AgentFolderTrustSpec(
      format: AgentFolderTrustFormat.tomlProjects,
      settingsFile: 'config.toml',
    ),
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
  // Measured on 0.153.4/0.154.0 (directory trust, update offer): `› ` marks the
  // highlighted row, ↓/↑ move it, Enter confirms it.
  //
  // Approve and deny on a menu pick an option by its words: directory trust
  // is `› 1. Yes, continue` / `2. No, quit`. The update offer (`Update now` /
  // `Skip` / `Skip until next version`) matches neither on purpose, so approve
  // refuses rather than running an updater. No cancel is declared safe:
  // Codex's prompts name no way to decline but their `No` row.
  menus: AgentMenuSupport(
    markers: ['›'],
    affirmative: [r'^Yes\b'],
    negative: [r'^No\b'],
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
  terminal: AgentTerminalRules(
    pasteBurstFoldsReturn: true,
    takesInputMidTurn: true,
    pastePlaceholder: '[Pasted Content ',
    evidence:
        'Codex takes fast typing as a paste burst and folds the Return after '
        'it into a newline; a typed message ends the burst with Ctrl+E first. '
        'A message sent while a task runs is queued by Codex itself (the '
        'owner, 2026-10-05). A large paste shows as "[Pasted Content <n> '
        'chars]" (codex 0.160.0 binary, read 2026-10-06).',
  ),
  mcpConfig: AgentMcpConfigSpec.undeclared(
    refusal:
        'Codex keeps its servers in ~/.codex/config.toml, and nothing here '
        'reads TOML yet, so what it would be given has not been read.',
  ),
);
