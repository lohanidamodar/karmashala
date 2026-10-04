import '../../permissions/permission_risk.dart';
import '../domain/agent_descriptor.dart';
import '../domain/agent_permission_support.dart';

const _evidence =
    'Claude Code 2.1.287 in stream-json mode (claude -p --input-format '
    'stream-json --output-format stream-json): the set_permission_mode '
    'control answered plan, default, acceptEdits and, launched with '
    '--allow-dangerously-skip-permissions, bypassPermissions — read off live '
    'processes 2026-10-04';

/// Claude Code as chat: the person's own `claude` in its stream-json mode
/// (the protocol its Agent SDK speaks), translated to ACP in-process.
///
/// Nothing terminal-shaped is declared — no hooks, screen rules or menus — the
/// protocol carries status, approvals and the conversation. The mode is set
/// over the protocol too, so no permission value puts anything on argv.
const claudeAcpDescriptor = AgentDescriptor(
  id: 'claude-acp',
  chatFormOf: 'claudeCode',
  displayName: 'Claude (ACP)',
  binaries: AgentBinaries(
    windows: ['claude'],
    posix: ['claude'],
    windowsInstallPaths: [r'%USERPROFILE%\.local\bin\claude.exe'],
  ),
  // The same binary and home as Claude Code in a terminal, so a conversation
  // started in either resumes in the other.
  store: AgentStoreSpec(
    homeDirectoryName: '.claude',
    homeVariable: 'CLAUDE_CONFIG_DIR',
  ),
  acp: AcpLaunchSpec(
    nativeBridge: AcpNativeBridge.claudeStreamJson,
    // Print mode over stream-json both ways, permission prompts sent to the
    // client on the control channel, streamed text, and bypassPermissions
    // allowed as a mode a person may choose.
    arguments: [
      '-p',
      '--input-format',
      'stream-json',
      '--output-format',
      'stream-json',
      '--verbose',
      '--include-partial-messages',
      '--permission-prompt-tool',
      'stdio',
      '--allow-dangerously-skip-permissions',
    ],
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
