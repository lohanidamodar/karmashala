import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/sessions/application/session_handoff_service.dart';
import 'package:karmashala/src/features/sessions/presentation/continue_with_dialog.dart';
import 'package:karmashala_session/launch.dart';

import '../../support/fixtures.dart';
import '../../support/permission_fixtures.dart';
import '../../support/window_matrix.dart';

/// "Continue with…" is a long form over a session in progress; every control
/// Tab reaches has to be on screen, the mode buttons at the top included.
void main() {
  const agent = AgentDescriptor(
    id: 'prompting',
    displayName: 'Prompting CLI',
    binaries: AgentBinaries(windows: ['p'], posix: ['p']),
    launch: AgentLaunchSpec(
      permission: testPermissionSupport,
      prompt: AgentPromptSupport.positional(),
      fork: AgentForkSupport.native(
        resume: AgentResume.flag('--resume'),
        evidence: 'p --help',
      ),
    ),
  );

  HandoffTarget target(String id, {bool isSameAgent = false}) => HandoffTarget(
    installation: AgentInstallation(
      id: id,
      agentId: agent.id,
      executable: const EnvironmentPath(
        environmentId: 'windows',
        path: r'C:\p',
      ),
      createdAt: testTime,
    ),
    descriptor: agent,
    agentName: agent.displayName,
    permission: carryPermission(PermissionRisk.ask, agent),
    isSameAgent: isSameAgent,
  );

  testWidgets('ContinueWithDialog keeps every focus stop in the window', (
    tester,
  ) async {
    await expectSurvivesWindowMatrix(
      tester,
      because: 'a handoff form opened over a running session',
      build: () => ProviderScope(
        overrides: [
          sessionContinuationProvider.overrideWith(
            (ref, _) => SessionContinuation(
              targets: [target('a1', isSameAgent: true), target('a2')],
              plan: SessionForkPlan.decide(
                descriptor: agent,
                agentName: agent.displayName,
                externalSessionId: 'cli-1',
              ),
            ),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => ContinueWithDialog.show(context, 's1'),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
      warmUp: (tester) async {
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
      },
    );
  });
}
