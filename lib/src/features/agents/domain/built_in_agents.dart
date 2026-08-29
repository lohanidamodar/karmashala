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
    permissionArguments: {
      PermissionMode.ask: [],
      PermissionMode.acceptEdits: ['--permission-mode', 'acceptEdits'],
      PermissionMode.bypass: ['--permission-mode', 'bypassPermissions'],
    },
    resume: AgentResume.flag('--resume'),
    interactiveResume: AgentResume.flag('--resume'),
  ),
  store: AgentStoreSpec(
    homeDirectoryName: '.claude',
    format: AgentStoreFormat.claudeJsonl,
  ),
  statusStrategy: AgentStatusStrategy.hooks,
  hooks: AgentHookSpec(
    configFileName: 'settings.json',
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
);

const _codex = AgentDescriptor(
  id: 'codex',
  displayName: 'Codex CLI',
  kind: AgentKind.codex,
  binaries: AgentBinaries(windows: ['codex'], posix: ['codex']),
  launch: AgentLaunchSpec(
    baseArguments: ['app-server'],
    permissionArguments: {
      PermissionMode.ask: ['--ask-for-approval', 'on-request'],
      PermissionMode.acceptEdits: ['--ask-for-approval', 'on-failure'],
      PermissionMode.bypass: ['--dangerously-bypass-approvals-and-sandbox'],
    },
    resume: AgentResume.flag('--resume'),
    // Interactively Codex resumes with a subcommand, not a flag.
    interactiveResume: AgentResume.subcommand('resume'),
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
);

const _antigravity = AgentDescriptor(
  id: 'antigravity',
  displayName: 'Antigravity',
  kind: AgentKind.antigravity,
  binaries: AgentBinaries(windows: ['antigravity'], posix: ['antigravity']),
  launch: AgentLaunchSpec(
    baseArguments: ['--stdio'],
    permissionArguments: {
      PermissionMode.ask: [],
      PermissionMode.acceptEdits: [],
      PermissionMode.bypass: ['--yolo'],
    },
    resume: AgentResume.flag('--resume'),
  ),
  // No documented session store, hook config, or resume convention yet.
  statusStrategy: AgentStatusStrategy.none,
);
