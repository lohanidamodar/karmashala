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
    idle: [GridMatcher('shift+tab to cycle')],
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
  binaries: AgentBinaries(windows: ['antigravity'], posix: ['antigravity']),
  launch: AgentLaunchSpec(
    baseArguments: ['--stdio'],
    // `ask` and `acceptEdits` are **absent, not empty**. We know of no
    // Antigravity flag for either, and the old `[]` meant the app passed
    // nothing while the UI reported the user's choice as applied — Loop 31 §4's
    // sharpest case, since the mode being silently dropped was the *safe* one.
    // Omitted means not offered, and the control says why instead of implying a
    // policy we cannot enforce.
    permissionModes: {
      PermissionMode.bypass: PermissionModeMapping.exact(['--yolo']),
    },
    resume: AgentResume.flag('--resume'),
  ),
  // No documented session store, hook config, or resume convention yet.
  statusStrategy: AgentStatusStrategy.none,
);
