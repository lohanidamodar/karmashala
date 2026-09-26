import 'package:agent_cli/descriptors.dart';

/// Permission vocabulary for a **made-up** agent in a test.
///
/// Most tests that touch permissions do not care which CLI they are describing;
/// they care that a session carries a mode, that it reaches a command line, and
/// that a safer one is not silently swapped for a riskier one. Before per-agent
/// modes they said that with `PermissionMode.ask`, and this is the replacement:
/// one axis, three values, one flag each, spanning the three rungs those tests
/// actually distinguish.
///
/// A test about a **real** CLI's modes must not use this — it should read the
/// registry, so it fails when that CLI changes. See
/// `agent_permission_support_test.dart`, which is the file that holds the real
/// declarations to the binaries' own words.
const testPermissionSupport = AgentPermissionSupport.axes(
  evidence: 'test fixture — not a real CLI',
  legacyAliases: {
    'ask': 'mode=ask',
    'acceptEdits': 'mode=acceptEdits',
    'bypass': 'mode=bypass',
  },
  axes: [
    AgentPermissionAxis(
      id: 'mode',
      label: 'Permission mode',
      description: 'How much the fake agent may do without asking.',
      defaultValueId: 'ask',
      values: [
        AgentPermissionValue(
          id: 'ask',
          label: 'Ask every time',
          shortLabel: 'Ask',
          description: 'Prompts before edits and commands.',
          arguments: ['--mode', 'ask'],
          permits: PermissionRisk.ask,
          evidence: 'test fixture',
        ),
        AgentPermissionValue(
          id: 'acceptEdits',
          label: 'Accept edits',
          shortLabel: 'Accept edits',
          description: 'Auto-approves edits; still asks for commands.',
          arguments: ['--mode', 'acceptEdits'],
          permits: PermissionRisk.acceptEdits,
          evidence: 'test fixture',
        ),
        AgentPermissionValue(
          id: 'bypass',
          label: 'Bypass',
          shortLabel: 'Bypass',
          description: 'Skips every prompt.',
          arguments: ['--bypass'],
          permits: PermissionRisk.bypass,
          isDangerous: true,
          evidence: 'test fixture',
        ),
      ],
    ),
  ],
);

/// The three fixture selections, by the names the old shared enum used.
const askSelection = PermissionSelection({'mode': 'ask'});
const acceptEditsSelection = PermissionSelection({'mode': 'acceptEdits'});
const bypassSelection = PermissionSelection({'mode': 'bypass'});

/// The same three as the strings a session row or a settings file holds.
const askStored = 'mode=ask';
const acceptEditsStored = 'mode=acceptEdits';
const bypassStored = 'mode=bypass';

/// The real agents' defaults, for a test that launches one of the three shipped
/// CLIs and only needs to name what it will run under.
const claudeAskStored = 'mode=manual';
const claudeAcceptEditsStored = 'mode=acceptEdits';
const claudeBypassStored = 'mode=bypassPermissions';
const codexDefaultStored = 'approval=on-request;sandbox=workspace-write';
const codexBypassStored = 'approval=on-request;sandbox=bypass-all';
const antigravityAskStored = 'mode=prompt';
const antigravityBypassStored = 'mode=skip-permissions';
