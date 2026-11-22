import '../../permissions/permission_risk.dart';
import '../domain/agent_descriptor.dart';
import '../domain/agent_permission_support.dart';

const _evidence =
    'agy acp 1.5.14 (agy 1.5.13, WSL, 2026-11-22) session/new availableModes: '
    'default, accept-edits, auto, plan; standalone antigravity-acp 1.3.0 '
    '(2026-10-07): default, auto_edit, yolo';

const _authEvidence =
    'antigravity-acp 1.3.0 in archlinux, 2026-10-12 & agy acp 1.5.14 '
    '(2026-11-22): initialize offers oauth-personal, oauth-business, '
    'gemini-api-key, agent-platform; authenticate oauth-personal prints '
    '"Open the following link to authenticate the ACP server: '
    'https://accounts.google.com/..." on stderr, redirect_uri '
    'http://127.0.0.1:<port>/, opens no browser itself, and waits on that '
    'callback; agy 1.5.0+ adds `agy acp --login` for terminal auth';

const _browserLogin =
    'Gives a Google sign-in link; finish it in a browser on the machine '
    'Antigravity runs on, which it returns to.';

/// Google Antigravity spoken to over ACP: prefers the native `agy acp`
/// subcommand built into `agy` 1.5.0+ (fast start, shared `~/.gemini/antigravity-cli`
/// store, Plan and Auto modes, `agy acp --login`), and falls back to the
/// standalone `agy_acp_server` archive from the public ACP registry
/// (`antigravity-acp`) where `agy` is absent or older than 1.5.0.
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
    cliSubcommand: AcpCliSubcommand(
      binaries: AgentBinaries(
        windows: ['agy'],
        posix: ['agy'],
        windowsInstallPaths: [r'%USERPROFILE%\.local\bin\agy.exe'],
      ),
      since: '1.5.0',
      arguments: ['acp'],
      terminalLogin: AcpTerminalLogin(
        name: 'Sign in with Google (terminal)',
        arguments: ['--login'],
        how:
            'Opens a terminal running `agy acp --login`: sign in with Google '
            'there (works over SSH and without a browser on this machine).',
        evidence:
            'agy 1.5.13 `agy help acp` (WSL, 2026-11-22): "--login  Log in '
            'with Google interactively, then exit (ACP terminal auth)"; '
            'introduced in agy 1.5.0',
      ),
      evidence:
          'agy 1.5.0 changelog & agy 1.5.13 `agy help acp` (WSL, 2026-11-22): '
          '`agy acp` starts Antigravity ACP Server over stdio',
    ),
    apiKeyVariables: {'gemini-api-key': 'GEMINI_API_KEY'},
    authCompletions: {
      'oauth-personal': AcpAuthCompletion(
        how: _browserLogin,
        evidence: _authEvidence,
      ),
      'oauth-business': AcpAuthCompletion(
        how: _browserLogin,
        evidence: _authEvidence,
      ),
      'gemini-api-key': AcpAuthCompletion(
        how: 'Uses the GEMINI_API_KEY you give here.',
        evidence: _authEvidence,
      ),
    },
    modeNames: {
      PermissionRisk.readOnly: ['plan'],
      PermissionRisk.ask: ['default'],
      PermissionRisk.acceptEdits: ['accept-edits', 'auto_edit'],
      PermissionRisk.autoRun: ['auto'],
      PermissionRisk.bypass: ['yolo'],
    },
    // Auto mode's reviewer screens commands leaving the sandbox; any ask that
    // still reaches the client is the person's to answer.
    screenedModes: {'auto'},
  ),
  launch: AgentLaunchSpec(
    permission: AgentPermissionSupport.axes(
      evidence: _evidence,
      legacyAliases: {'auto_edit': 'mode=accept-edits'},
      axes: [
        AgentPermissionAxis(
          id: 'mode',
          label: 'Mode',
          description: 'How much Antigravity may do without asking.',
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
              description: 'Antigravity asks before edits and commands.',
              arguments: [],
              permits: PermissionRisk.ask,
              evidence: _evidence,
            ),
            AgentPermissionValue(
              id: 'accept-edits',
              label: 'Accept edits',
              shortLabel: 'Accept edits',
              description: 'File edits apply without asking; others ask.',
              arguments: [],
              permits: PermissionRisk.acceptEdits,
              evidence: _evidence,
            ),
            AgentPermissionValue(
              id: 'auto',
              label: 'Auto mode',
              shortLabel: 'Auto',
              description:
                  'Approves edits and safe commands; a reviewer screens '
                  'commands leaving the sandbox.',
              arguments: [],
              permits: PermissionRisk.autoRun,
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
