import '../../permissions/permission_risk.dart';
import '../domain/agent_descriptor.dart';
import '../domain/agent_permission_support.dart';

const _evidence =
    '@agentclientprotocol/claude-agent-acp: session/new availableModes '
    'plan, default, acceptEdits, bypassPermissions — declared from the '
    'adapter source 2026-10-02, not yet read off a live session';

/// Claude Code behind the `claude-agent-acp` adapter, spoken to over ACP.
///
/// Nothing terminal-shaped is declared — no hooks, screen rules or menus — the
/// protocol carries status, approvals and the conversation. The mode is set
/// over the protocol too, so no permission value puts anything on argv.
const claudeAcpDescriptor = AgentDescriptor(
  id: 'claude-acp',
  chatFormOf: 'claudeCode',
  displayName: 'Claude (ACP)',
  binaries: AgentBinaries(
    windows: ['claude-agent-acp'],
    posix: ['claude-agent-acp'],
  ),
  // The adapter runs the Claude Code SDK, which writes to Claude Code's home.
  store: AgentStoreSpec(
    homeDirectoryName: '.claude',
    homeVariable: 'CLAUDE_CONFIG_DIR',
  ),
  acp: AcpLaunchSpec(
    npxPackage: '@agentclientprotocol/claude-agent-acp',
    modeNames: {
      PermissionRisk.readOnly: ['plan'],
      PermissionRisk.ask: ['default'],
      PermissionRisk.acceptEdits: ['acceptEdits'],
      PermissionRisk.autoRun: ['bypassPermissions'],
      PermissionRisk.bypass: ['bypassPermissions'],
    },
  ),
  launch: AgentLaunchSpec(
    permission: AgentPermissionSupport.axes(
      evidence: _evidence,
      axes: [
        AgentPermissionAxis(
          id: 'mode',
          label: 'Permission mode',
          description: 'How much Claude may do without asking.',
          defaultValueId: 'default',
          values: [
            AgentPermissionValue(
              id: 'plan',
              label: 'Plan mode',
              shortLabel: 'Plan',
              description: 'Plan the work rather than carry it out.',
              arguments: [],
              permits: PermissionRisk.readOnly,
              evidence: _evidence,
            ),
            AgentPermissionValue(
              id: 'default',
              label: 'Ask every time',
              shortLabel: 'Ask',
              description: 'Claude asks before edits and commands.',
              arguments: [],
              permits: PermissionRisk.ask,
              evidence: _evidence,
            ),
            AgentPermissionValue(
              id: 'acceptEdits',
              label: 'Accept edits',
              shortLabel: 'Accept edits',
              description: 'Edits apply without asking; commands still ask.',
              arguments: [],
              permits: PermissionRisk.acceptEdits,
              evidence: _evidence,
            ),
            AgentPermissionValue(
              id: 'bypassPermissions',
              label: 'Bypass (full autonomy)',
              shortLabel: 'Bypass',
              description: 'No prompts at all.',
              arguments: [],
              permits: PermissionRisk.bypass,
              isDangerous: true,
              evidence: _evidence,
            ),
          ],
        ),
      ],
    ),
  ),
);
