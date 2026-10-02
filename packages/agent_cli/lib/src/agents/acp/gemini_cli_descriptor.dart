import '../../permissions/permission_risk.dart';
import '../domain/agent_descriptor.dart';
import '../domain/agent_permission_support.dart';

const _evidence =
    '@google/gemini-cli ApprovalMode plan, default, autoEdit, yolo as offered '
    'under --acp — declared from the CLI source 2026-10-02, not yet read off '
    'a live session; the mode ids are best-effort';

/// Gemini CLI in its ACP mode (`gemini --acp`). Terminal-shaped rules are
/// deliberately absent; the mode is set over the protocol.
const geminiCliDescriptor = AgentDescriptor(
  id: 'gemini-cli',
  displayName: 'Gemini CLI',
  binaries: AgentBinaries(windows: ['gemini'], posix: ['gemini']),
  store: AgentStoreSpec(homeDirectoryName: '.gemini'),
  acp: AcpLaunchSpec(
    arguments: ['--acp'],
    npxPackage: '@google/gemini-cli',
    // Two spellings for the edit rung: the CLI's enum says `autoEdit`, its
    // settings file says `auto_edit`, and which one `session/new` offers has
    // not been observed.
    modeNames: {
      PermissionRisk.readOnly: ['plan'],
      PermissionRisk.ask: ['default'],
      PermissionRisk.acceptEdits: ['auto_edit', 'autoEdit'],
      PermissionRisk.autoRun: ['yolo'],
      PermissionRisk.bypass: ['yolo'],
    },
  ),
  launch: AgentLaunchSpec(
    permission: AgentPermissionSupport.axes(
      evidence: _evidence,
      axes: [
        AgentPermissionAxis(
          id: 'mode',
          label: 'Approval mode',
          description: 'How much Gemini may do without asking.',
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
              description: 'Gemini asks before edits and commands.',
              arguments: [],
              permits: PermissionRisk.ask,
              evidence: _evidence,
            ),
            AgentPermissionValue(
              id: 'autoEdit',
              label: 'Auto edit',
              shortLabel: 'Auto edit',
              description: 'Edits apply without asking; commands still ask.',
              arguments: [],
              permits: PermissionRisk.acceptEdits,
              evidence: _evidence,
            ),
            AgentPermissionValue(
              id: 'yolo',
              label: 'YOLO (full autonomy)',
              shortLabel: 'YOLO',
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
