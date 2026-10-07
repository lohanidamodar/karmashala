import '../../permissions/permission_risk.dart';
import '../domain/agent_descriptor.dart';
import '../domain/agent_permission_support.dart';

const _evidence =
    'antigravity-acp 1.3.0 session/new availableModes, read off a live '
    'session 2026-10-07: default "Default permission prompt flow", auto_edit '
    '"Auto-approve file edit tools", yolo "Auto-approve all tools"; no plan '
    'mode';

/// Google Antigravity's ACP server (`agy_acp_server`), spoken to over ACP.
///
/// Published by the public ACP registry as `antigravity-acp` — a prebuilt
/// archive per platform, not an npm package, and no `--acp` flag on the `agy`
/// CLI — so it is found on PATH or in the folder Karmashala installs it to.
/// Its version is read over ACP (`agentInfo.version`): `--version` prints a
/// build stamp, not a version. The registry passes `--uid=` on Linux, a no-op
/// unless run as root.
const antigravityAcpDescriptor = AgentDescriptor(
  id: 'antigravity-acp',
  chatFormOf: 'antigravity',
  displayName: 'Antigravity · Chat',
  binaries: AgentBinaries(
    windows: ['agy_acp_server.exe'],
    posix: ['agy_acp_server.par', 'agy_acp_server'],
  ),
  discovery: AgentDiscoveryRules(probeVersion: false),
  store: AgentStoreSpec(homeDirectoryName: '.gemini/antigravity-acp'),
  // Its `gemini-api-key` method reads the key the Gemini tools document.
  acp: AcpLaunchSpec(
    linuxArguments: ['--uid='],
    registryId: 'antigravity-acp',
    apiKeyVariables: {'gemini-api-key': 'GEMINI_API_KEY'},
    modeNames: {
      PermissionRisk.ask: ['default'],
      PermissionRisk.acceptEdits: ['auto_edit'],
      PermissionRisk.bypass: ['yolo'],
    },
  ),
  launch: AgentLaunchSpec(
    permission: AgentPermissionSupport.axes(
      evidence: _evidence,
      axes: [
        AgentPermissionAxis(
          id: 'mode',
          label: 'Mode',
          description: 'How much Antigravity may do without asking.',
          defaultValueId: 'default',
          values: [
            AgentPermissionValue(
              id: 'default',
              label: 'Ask every time',
              shortLabel: 'Ask',
              description: 'Antigravity asks before edits and commands.',
              arguments: [],
              permits: PermissionRisk.ask,
              evidence: _evidence,
            ),
            AgentPermissionValue(
              id: 'auto_edit',
              label: 'Auto edit',
              shortLabel: 'Auto edit',
              description: 'File edits apply without asking; others ask.',
              arguments: [],
              permits: PermissionRisk.acceptEdits,
              evidence: _evidence,
            ),
            AgentPermissionValue(
              id: 'yolo',
              label: 'YOLO (full autonomy)',
              shortLabel: 'YOLO',
              description: 'Every tool runs without asking.',
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
