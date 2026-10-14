import '../../permissions/permission_risk.dart';
import '../domain/agent_descriptor.dart';
import '../domain/agent_permission_support.dart';

const _evidence =
    'codexAppServer bridge: modes read-only, workspace-write, agent, '
    'agent-full-access (the codex-acp adapter\'s ids) as approval policy and '
    'sandbox on codex-cli 0.160.0 app-server, 2026-10-04';

/// Codex's chat: the person's own `codex app-server`, translated to ACP
/// in-process, so it shares the terminal Codex's login and threads.
/// Terminal-shaped rules are deliberately absent; the mode is set over the
/// protocol.
const codexAcpDescriptor = AgentDescriptor(
  id: 'codex-acp',
  chatFormOf: 'codex',
  displayName: 'Codex CLI · Chat',
  binaries: AgentBinaries(
    windows: ['codex'],
    posix: ['codex'],
    windowsInstallPaths: [
      r'%LOCALAPPDATA%\Programs\OpenAI\Codex\bin\codex.exe',
    ],
  ),
  store: AgentStoreSpec(
    homeDirectoryName: '.codex',
    homeVariable: 'CODEX_HOME',
  ),
  acp: AcpLaunchSpec(
    arguments: ['app-server'],
    nativeBridge: AcpNativeBridge.codexAppServer,
    modeNames: {
      PermissionRisk.readOnly: ['read-only'],
      PermissionRisk.ask: ['workspace-write'],
      PermissionRisk.acceptEdits: ['workspace-write'],
      PermissionRisk.autoRun: ['agent'],
      PermissionRisk.bypass: ['agent-full-access'],
    },
    authCompletions: {
      'chatgpt': AcpAuthCompletion(
        how:
            'Codex gives a ChatGPT sign-in link; finish it in a browser on '
            'the machine Codex runs on, which it returns to.',
        evidence:
            'codex_app_server_bridge.dart: account/login/start answers an '
            'authUrl, said on stderr, and account/login/completed ends it '
            '(codex-cli 0.160.0, read 2026-10-12)',
      ),
    },
    terminalLogin: AcpTerminalLogin(
      name: 'Sign in with a device code',
      arguments: ['login', '--device-auth'],
      how:
          'Opens a terminal running `codex login --device-auth`: a link '
          'and a code you can use from any browser.',
      evidence: 'codex login --help, codex-cli 0.160.0, 2026-10-12',
    ),
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
              description: 'Reads and proposes; asks before changing anything.',
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
  instructionFiles: ['AGENTS.md'],
);
