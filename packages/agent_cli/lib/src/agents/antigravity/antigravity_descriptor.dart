import '../../permissions/permission_risk.dart';
import '../domain/agent_descriptor.dart';
import '../domain/agent_mcp_config.dart';
import '../domain/agent_plan.dart';
import '../domain/agent_permission_support.dart';
import '../domain/agent_screen_menu.dart';
import '../domain/agent_skill_support.dart';
import '../domain/agent_status.dart';

/// What Antigravity is, as data: how to find, launch and observe it.
/// One part of its adapter.
const antigravityDescriptor = AgentDescriptor(
  id: 'antigravity',
  displayName: 'Antigravity',
  // **The executable is `agy`, not `antigravity`.** Everything in this entry
  // used to be inherited from Loop 10, which built the adapter against a fake
  // process and never ran the CLI; the binary name was the load-bearing part of
  // that guess, because discovery probes by name and so never found a real
  // installation. `agy --version` reports 1.1.22, and the CLI is a separately
  // distributed self-updating Go binary that puts itself on PATH with
  // `agy install` — the Antigravity IDE does not ship or launch it.
  //
  // `windows: ['agy']`, not `['agy.exe', 'agy']`: Windows resolves the bare
  // name through PATHEXT, so the second spelling is one more failed spawn per
  // discovery, and Claude and Codex both declare the bare name.
  //
  // One declared path, not three. `windowsInstallPaths` is probed by *running*
  // the candidate, so every path that is not there costs a failed spawn per
  // discovery. This one mirrors where `agy install` puts the binary on POSIX
  // (`~/.local/bin`) and matches Claude Code's entry; it is inferred, not
  // watched — nothing here has seen `agy install` run on Windows, and it was
  // absent from all three candidate paths on 2026-09-10.
  binaries: AgentBinaries(
    windows: ['agy'],
    posix: ['agy'],
    windowsInstallPaths: [r'%USERPROFILE%\.local\bin\agy.exe'],
  ),
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
    // No `selfUpdate`, and so no latest-version source: `agy` updates itself
    // over its own channel, and no public, documented feed of its releases
    // was found on 2026-09-28 (it is not on npm). Its installs are never
    // flagged as behind a release — only behind another machine's.
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
    // cannot run anything, on the platform half our sessions launch into.
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
    // [AgentContinueScope.workingDirectory] and why `DirectoryResumePlan`
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
    // Both the TUI resume hint and stream-json init event announce the id.
    sessionIdAnnouncement: AgentSessionIdAnnouncement.pattern(
      pattern:
          r'(?:agy\s+--conversation=|"conversation_id"\s*:\s*")([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-'
          r'[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})',
      evidence:
          'agy 1.1.28: resume hint from entrypoints.printResumeHint '
          '("\\nResume with -c (or command below):\\nagy --conversation=%s\\n") '
          'and stream-json "init" event ("\\"conversation_id\\":\\"%s\\"")',
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
    // is refused for being a recency guess. `DirectoryResumePlan` will only
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
    // `antigravity-trust-prompt.raw` (agy 1.3.2; 1.2.16 words it the same).
    firstRunPrompt: AgentFirstRunPromptRules(
      markers: [GridMatcher('Do you trust the contents of this project')],
    ),
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
    // **The one that takes no conversation from anywhere.** `--print` carries
    // the text itself, so the turns ride in the argument — declared as
    // [AgentRecapSupport.inPrompt] rather than pretended into a stdin it does
    // not read.
    recap: AgentRecapSupport.inPrompt(
      ['--print'],
      evidence:
          'agy 1.1.28 --help: "--print  Run a single prompt non-interactively '
          'and print the response"; `agy --print` with no value exits on "flag '
          'needs an argument: -print", which is what proves it carries one. '
          'Its one stdin door is "--input-format ... stream-json reads one '
          'NDJSON message per line from stdin and runs a turn for each; it '
          'requires --output-format stream-json" — a protocol nothing here has '
          'run. Read 2026-09-09.',
    ),
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
          id: 'gemini-3.8-flash-high',
          label: 'Gemini 3.8 Flash (High)',
          summary: 'Latest Flash, at the most reasoning.',
        ),
        AgentModel(
          id: 'gemini-3.8-flash-medium',
          label: 'Gemini 3.8 Flash (Medium)',
          summary: 'Latest Flash, balanced.',
        ),
        AgentModel(
          id: 'gemini-3.8-flash-low',
          label: 'Gemini 3.8 Flash (Low)',
          summary: 'Latest Flash, fastest.',
        ),
        AgentModel(
          id: 'gemini-3.7-flash-high',
          label: 'Gemini 3.7 Flash (High)',
          summary: 'Previous Flash, at the most reasoning.',
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
  // `AntigravityAdapter.store` is a store that yields *identity* without
  // *content* — which is exactly this one.
  //
  // What remains true is the part that gates the *chat view*: message content
  // is unreadable, so there is no transcript to show, quote into a handoff
  // packet, or seed a resume from. The adapter's `AgentTranscripts` says
  // `buildsChatView: false`, so declaring the store turns none of that on.
  store: AgentStoreSpec(
    homeDirectoryName: '.gemini/antigravity-cli',
    // Answering "Yes, I trust this folder" in /tmp/r70-agytrust-… appended
    // that path to `trustedWorkspaces` in `settings.json`, and nothing else
    // in the home named it (agy 1.3.2 in WSL, 2026-10-09).
    folderTrust: AgentFolderTrustSpec(
      format: AgentFolderTrustFormat.jsonPathList,
      settingsFile: 'settings.json',
      listKey: 'trustedWorkspaces',
    ),
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
    // What is lost with them is a hook for `awaitingApproval`: only `grid`
    // below reads a prompt, off the screen.
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
  // Read in a ConPTY through WSL on agy 1.3.2 (2026-10-09). Every menu it
  // asks with — folder trust (`antigravity-trust-prompt.raw`; the owner saw
  // it on 1.2.16) and a tool permission (`antigravity-permission-prompt.raw`)
  // — ends `↑/↓ Navigate · …`, and no hook announces either. Idle, its footer
  // is `? for shortcuts`, after a turn and after an Esc ("⎿ Interrupted",
  // `antigravity-interrupted.raw`); working it is `esc to cancel`, which a
  // permission menu also ends with, so no working marker is declared: the
  // hooks say working. agy draws its footer from the first column; Claude
  // Code's and Codex's `? for shortcuts` are indented or follow a mode.
  grid: AgentGridRules(
    awaitingApproval: [GridMatcher('↑/↓ Navigate ·')],
    idle: [GridMatcher('? for shortcuts', atLineStart: true)],
  ),
  // Approve and deny pick the option by its words: `Yes, I trust this
  // folder` / `No, exit`, `1. Yes, run command` / `4. No, cancel`, and the
  // binary's other permission menus ("Allow creation of this file?", "Allow
  // access to this URL?", "Allow calling this tool?", "Do you want to
  // proceed?" / "Yes, accept this change") the same way. Enter on `No, exit`
  // exits and trusts nothing (measured). Its ask_question menu
  // (`antigravity-ask-question.raw`: "Question 1/1: …", `› 1. Red`, `3.
  // Write-in...`, footer `enter Select · esc Skip`) has no yes or no: it is
  // answered by option, and declined by its own Esc, which skips it.
  menus: AgentMenuSupport(
    markers: ['>'],
    affirmative: [r'^Yes\b'],
    negative: [r'^No\b'],
    cancelDeclines: ['Question '],
  ),
  // Only the Esc a question names; every other prompt is a menu answered by
  // its option above. The 1.0.13 `keybindings.json` keys (`y`/`n`) describe
  // a version nobody runs.
  approval: AgentApprovalRules(
    deny: AgentApprovalKey(
      keys: '\x1b',
      label: 'Skip',
      effect: 'Presses Esc, which skips the question ("esc Skip").',
    ),
  ),
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
  // longer "the finding the chat view refuses this agent for": that
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
  mcpConfig: AgentMcpConfigSpec.undeclared(
    refusal:
        'Nobody has established where agy reads its own MCP servers, so what '
        'it would be given has not been read.',
  ),
);
