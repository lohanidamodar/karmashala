import '../../permissions/permission_risk.dart';
import '../domain/agent_descriptor.dart';
import '../domain/agent_permission_support.dart';

const _evidence =
    '@xai-official/grok `grok agent stdio`: session/new availableModes '
    'default, acceptEdits, auto — declared from the package source '
    '2026-10-02, not yet read off a live session';

const _authEvidence =
    '@xai-official/grok 1.0.50 in archlinux, 2026-10-12: initialize '
    'offers grok.com "Sign in with Grok"; authenticate grok.com runs '
    r'$BROWSER, xdg-open or `cmd.exe /c start` on '
    'https://accounts.x.ai/oauth2/device?user_code=..., prints nothing '
    'and waits; `grok login --device-auth` prints the link and the code '
    'in a terminal';

/// Grok's coding agent in its ACP mode (`grok agent stdio`). Terminal-shaped
/// rules are deliberately absent; the mode is set over the protocol. No store:
/// where it keeps conversations has not been established.
const grokDescriptor = AgentDescriptor(
  id: 'grok',
  displayName: 'Grok',
  binaries: AgentBinaries(windows: ['grok'], posix: ['grok']),
  acp: AcpLaunchSpec(
    arguments: ['agent', 'stdio'],
    npxPackage: '@xai-official/grok',
    modeNames: {
      PermissionRisk.ask: ['default'],
      PermissionRisk.acceptEdits: ['acceptEdits'],
      PermissionRisk.autoRun: ['auto'],
      PermissionRisk.bypass: ['auto'],
    },
    authCompletions: {
      'grok.com': AcpAuthCompletion(
        how:
            "Grok opens x.ai's sign-in page in a browser on its own "
            'machine and never prints the link. From a phone, or if no '
            'browser opens, sign in in a terminal instead.',
        evidence: _authEvidence,
      ),
    },
    terminalLogin: AcpTerminalLogin(
      name: 'Sign in with a device code',
      arguments: ['login', '--device-auth'],
      how:
          'Opens a terminal running `grok login --device-auth`: a link '
          'and a code you can use from any browser.',
      evidence: _authEvidence,
    ),
  ),
  launch: AgentLaunchSpec(
    permission: AgentPermissionSupport.axes(
      evidence: _evidence,
      axes: [
        AgentPermissionAxis(
          id: 'mode',
          label: 'Mode',
          description: 'How much Grok may do without asking.',
          defaultValueId: 'default',
          values: [
            AgentPermissionValue(
              id: 'default',
              label: 'Ask every time',
              shortLabel: 'Ask',
              description: 'Grok asks before edits and commands.',
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
              id: 'auto',
              label: 'Auto (full autonomy)',
              shortLabel: 'Auto',
              description: 'No prompts and nothing screening what runs.',
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
