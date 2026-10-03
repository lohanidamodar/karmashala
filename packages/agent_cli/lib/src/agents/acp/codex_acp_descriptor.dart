import '../../permissions/permission_risk.dart';
import '../domain/agent_descriptor.dart';
import '../domain/agent_permission_support.dart';

const _evidence =
    '@agentclientprotocol/codex-acp: session/new availableModes read-only, '
    'workspace-write, agent, agent-full-access — declared from the adapter '
    'source 2026-10-02, not yet read off a live session';

/// Codex behind the `codex-acp` adapter, spoken to over ACP. Terminal-shaped
/// rules are deliberately absent; the mode is set over the protocol.
const codexAcpDescriptor = AgentDescriptor(
  id: 'codex-acp',
  displayName: 'Codex (ACP)',
  binaries: AgentBinaries(windows: ['codex-acp'], posix: ['codex-acp']),
  // The adapter embeds Codex, which keeps its threads in Codex's home.
  store: AgentStoreSpec(
    homeDirectoryName: '.codex',
    homeVariable: 'CODEX_HOME',
  ),
  acp: AcpLaunchSpec(
    npxPackage: '@agentclientprotocol/codex-acp',
    modeNames: {
      PermissionRisk.readOnly: ['read-only'],
      PermissionRisk.ask: ['workspace-write'],
      PermissionRisk.acceptEdits: ['workspace-write'],
      PermissionRisk.autoRun: ['agent'],
      PermissionRisk.bypass: ['agent-full-access'],
    },
  ),
  launch: AgentLaunchSpec(
    permission: AgentPermissionSupport.axes(
      evidence: _evidence,
      axes: [
        AgentPermissionAxis(
          id: 'mode',
          label: 'Mode',
          description: 'How much Codex may do without asking.',
          defaultValueId: 'workspace-write',
          values: [
            AgentPermissionValue(
              id: 'read-only',
              label: 'Read-only',
              shortLabel: 'Read-only',
              description: 'Reads and proposes; changes nothing.',
              arguments: [],
              permits: PermissionRisk.readOnly,
              evidence: _evidence,
            ),
            AgentPermissionValue(
              id: 'workspace-write',
              label: 'Workspace write',
              shortLabel: 'Workspace',
              description:
                  'Writes inside the workspace without asking; asks before '
                  'anything outside it.',
              arguments: [],
              permits: PermissionRisk.acceptEdits,
              evidence: _evidence,
            ),
            AgentPermissionValue(
              id: 'agent',
              label: 'Agent',
              shortLabel: 'Agent',
              description: 'Runs without prompts inside the sandbox.',
              arguments: [],
              permits: PermissionRisk.autoRun,
              evidence: _evidence,
            ),
            AgentPermissionValue(
              id: 'agent-full-access',
              label: 'Agent, full access',
              shortLabel: 'Full access',
              description: 'No prompts and no sandbox.',
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
