import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/usage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show AccountUsageState, DataRefused;
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/application/agent_account_switch.dart';
import 'package:karmashala/src/features/agents/presentation/toolbar_usage_strip.dart';
import 'package:karmashala/src/features/environments/application/environments_controller.dart';
import 'package:karmashala/src/features/notifications/application/notification_providers.dart';

import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import 'usage_fixtures.dart';

/// Switching a machine's account from the toolbar's usage card: it asks the
/// one switch Settings asks too, and the card says how it went. The card
/// closing around a pick used to drop the switch before it was asked.
void main() {
  const one = 'one@example.com';
  const two = 'two@example.com';

  ClaudeAccount saved(String email) => ClaudeAccount(
    id: email,
    email: email,
    claudeAiOauth: const {},
    capturedAt: testTime,
  );

  final windows = agentInstallation(id: 'a1');
  final wsl = agentInstallation(
    id: 'a2',
    environmentId: 'wsl:Ubuntu',
    path: '/usr/bin/claude',
  );

  late FakeDataServer server;

  Future<ProviderContainer> pump(
    WidgetTester tester, {
    List<Override> overrides = const [],
  }) async {
    server = FakeDataServer();
    final db = seedUsageDatabase(server: server);
    server.environmentRows.upsert(wslEnv());
    server.installationRows.insert(wsl);
    server.claudeAccountRows
      ..insert(saved(one))
      ..insert(saved(two));
    for (final install in [windows, wsl]) {
      seedUsage(server, install, usage: usageSnapshot(email: one));
    }
    final container = ProviderContainer(
      overrides: [
        await db.server.override(),
        clockProvider.overrideWithValue(MovableClock(testTime)),
        ...overrides,
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topRight,
              child: SizedBox(width: 1000, child: ToolbarUsageStrip()),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('62%'));
    await tester.pumpAndSettle();
    return container;
  }

  Future<void> pick(WidgetTester tester, String environmentId) async {
    await tester.tap(find.byKey(ValueKey('usage-switch-$environmentId')));
    await tester.pumpAndSettle();
    // By its words, as a person picks it.
    await tester.tap(find.text(two));
    await tester.pumpAndSettle();
  }

  Future<void> quiesce(WidgetTester tester, ProviderContainer container) async {
    container.read(windowFocusedProvider.notifier).set(false);
    await tester.pump();
  }

  for (final install in [windows, wsl]) {
    testWidgets('the card\'s Switch on ${install.environmentId} asks the '
        'shared switch', (tester) async {
      final asked = <(String, String)>[];
      final container = await pump(
        tester,
        overrides: [
          accountSwitchControllerProvider.overrideWith(
            () => _RecordingSwitch(asked),
          ),
        ],
      );
      await pick(tester, install.environmentId);
      expect(asked, [(install.id, two)]);
      await quiesce(tester, container);
    });
  }

  testWidgets('the switch reaches the server, and the new account\'s card '
      'opens saying so', (tester) async {
    final container = await pump(tester);
    server.agentWork.onRefresh = (key) => key == usageAccountKey(wsl)
        ? AccountUsageState(
            accountKey: key,
            agentId: wsl.agentId,
            environmentId: wsl.environmentId,
            usage: usageSnapshot(percent: 20, email: two),
          )
        : server.agentWork.usage[key]!;

    await pick(tester, wsl.environmentId);

    expect(server.agentWork.switches, [(wsl.id, two)]);
    final machine = container.read(
      environmentLabelForIdProvider(wsl.environmentId),
    );
    expect(find.text('Switched $machine to $two.'), findsOneWidget);
    // The card that says it is the new account's, and only it is open.
    expect(find.text(two), findsOneWidget);
    expect(find.byKey(const ValueKey('usage-switch-outcome')), findsOneWidget);
    await quiesce(tester, container);
  });

  testWidgets('a refused switch says why, in the card', (tester) async {
    final container = await pump(tester);
    server.agentWork.accountRefusals[wsl.id] = const DataRefused.invalid(
      'Claude is running there; quit it first.',
    );

    await pick(tester, wsl.environmentId);

    final machine = container.read(
      environmentLabelForIdProvider(wsl.environmentId),
    );
    expect(
      find.text(
        'Could not switch $machine: Claude is running there; quit it first.',
      ),
      findsOneWidget,
    );
    expect(find.text(one), findsOneWidget, reason: 'still the same account');
    await quiesce(tester, container);
  });
}

class _RecordingSwitch extends AccountSwitchController {
  _RecordingSwitch(this.asked);

  final List<(String, String)> asked;

  @override
  Future<AccountSwitchOutcome> switchTo(
    AgentInstallation installation,
    String accountId,
  ) async {
    asked.add((installation.id, accountId));
    return AccountSwitchOutcome(
      installationId: installation.id,
      agentId: installation.agentId,
      environmentId: installation.environmentId,
      account: accountId,
      at: testTime,
    );
  }
}
