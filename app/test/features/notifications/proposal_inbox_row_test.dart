import 'package:agent_cli/descriptors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/notifications/presentation/attention_inbox_view.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala_automations/automations.dart';
import 'package:karmashala_notifications/attention.dart';
import 'package:karmashala_notifications/watched.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/fake_data_server.dart';

/// "Claude Code proposed an automation" in the inbox: the row carries the
/// owner's three verbs, and turning it on from there is the owner's act.
void main() {
  final now = testTime.add(const Duration(hours: 2));

  testWidgets('the inbox row offers Review, Turn on and Discard, and Turn on '
      'arms it', (tester) async {
    final server = FakeDataServer()
      ..environmentRows.upsert(windowsEnv())
      ..projectRows.insert(project())
      ..repositoryRows.insert(repository());
    server.installationRows.insert(
      agentInstallation(agentId: AgentIds.claudeCode),
    );
    server.automationRows.insert(
      Automation(
        id: 'p1',
        repositoryId: 'r1',
        name: 'Needs me',
        schedule: AutomationSchedule.once(testTime),
        agentInstallationId: '',
        prompt: '',
        permissionMode: null,
        enabled: false,
        armedAt: testTime,
        trigger: const AutomationEventTrigger(
          kind: AutomationEventKind.needsYou,
          action: AutomationEventAction.notifyOnly,
        ),
        steps: AutomationSteps(const [
          AutomationStep(
            kind: AutomationStepKind.notify,
            when: AutomationStepWhen.always,
          ),
        ]),
        proposedBy: 'Claude Code in "Fix the cart"',
      ),
    );
    server.attention.inbox = AttentionInbox.empty.raise(
      InboxItem(
        session: const WatchedSession(
          key: AgentSessionKey('automation', 'proposal:p1'),
          label: 'Fix the cart',
          openId: '',
          imported: false,
        ),
        kind: InboxItemKind.automationProposed,
        at: testTime,
        id: proposalInboxId('p1'),
        detail:
            'Claude Code in "Fix the cart" proposed an automation: '
            '"Needs me". It does nothing until you turn it on.',
      ),
    );
    final container = ProviderContainer(
      overrides: [
        await server.override(),
        clockProvider.overrideWithValue(FixedClock(now)),
        agentSessionStatusProvider.overrideWith(
          (ref, id) => const Stream<AgentStatusReport>.empty(),
        ),
      ],
    );
    addTearDown(container.dispose);
    for (final (width, scale) in const [(360.0, 1.0), (360.0, 1.6)]) {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(
                size: Size(width, 800),
                textScaler: TextScaler.linear(scale),
              ),
              child: Scaffold(
                body: SizedBox(width: width, child: const AttentionInboxView()),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull, reason: '$width $scale');
      expect(find.textContaining('Proposed automation'), findsOneWidget);
      expect(find.text('Review'), findsOneWidget);
      expect(find.text('Discard'), findsOneWidget);
    }

    await tester.tap(find.text('Turn on'));
    await tester.pumpAndSettle();
    final stored = server.automationRows.getAll().single;
    expect(stored.enabled, isTrue);
    expect(stored.isProposed, isFalse);
    expect(server.attention.dismissed, [proposalInboxId('p1')]);
  });
}
