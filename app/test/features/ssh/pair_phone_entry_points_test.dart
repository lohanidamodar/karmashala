import 'package:agent_cli/process.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/environments/application/environment_health.dart';
import 'package:karmashala/src/features/environments/application/system_health.dart';
import 'package:karmashala/src/features/environments/application/system_health_service.dart';
import 'package:karmashala/src/features/environments/presentation/environment_health_dialog.dart';
import 'package:karmashala/src/features/environments/presentation/environments_section.dart';
import 'package:karmashala/src/features/ssh/application/companion_route_store.dart';
import 'package:karmashala/src/features/ssh/presentation/pair_phone_dialog.dart';
import 'package:karmashala/src/features/ssh/presentation/pair_phone_entry.dart';
import 'package:karmashala/src/features/ssh/presentation/ssh_hosts_section.dart';
import 'package:karmashala_remote/pairing.dart';
import 'package:karmashala_environments/ssh.dart';

import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/system_health_fakes.dart';

/// "Pair a phone…" lives where the machine is shown — its SSH card, its
/// environment card, the health panel — and every one opens the same dialog.
/// The Explorer's switcher is pinned beside its other items, in
/// `explorer_scope_test.dart`.
void main() {
  late FakeDataServer server;

  setUp(() {
    server = FakeDataServer(clock: () => testTime);
    server.environmentRows
      ..upsert(windowsEnv())
      ..upsert(sshEnvFixture());
    server.sshHostRows.upsert(
      SshHost(
        id: 'h1',
        name: 'build-box',
        host: 'build.example.com',
        port: 22,
        username: 'dev',
        authMethod: SshAuthMethod.password,
        createdAt: testTime,
      ),
    );
  });

  Future<void> pump(WidgetTester tester, Widget body) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final data = await server.override();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          data,
          clockProvider.overrideWithValue(FixedClock(testTime)),
          idGeneratorProvider.overrideWithValue(SequentialIdGenerator()),
          systemHealthProvider.overrideWith(
            () => FixedSystemHealthController(
              SystemHealthReport(
                checkedAt: testTime,
                checks: const [],
                environments: [
                  EnvironmentHealth(
                    environment: windowsEnv(),
                    level: HealthLevel.healthy,
                    summary: '1 coding agent ready.',
                    installations: const [],
                  ),
                  EnvironmentHealth(
                    environment: sshEnvFixture(),
                    level: HealthLevel.healthy,
                    summary: '1 coding agent ready.',
                    installations: const [],
                  ),
                ],
              ),
            ),
          ),
        ],
        child: MaterialApp(home: Scaffold(body: body)),
      ),
    );
    await tester.pump();
  }

  Future<void> expectOpensTheDialog(WidgetTester tester, Finder button) async {
    expect(button, findsOneWidget);
    await tester.tap(button);
    await tester.pump();
    final dialog = tester.widget<PairPhoneDialog>(find.byType(PairPhoneDialog));
    expect(dialog.host.id, 'h1');
    expect(find.text('Pair a phone with build-box'), findsOneWidget);
  }

  testWidgets('the SSH host card has it as a button', (tester) async {
    await pump(tester, const SingleChildScrollView(child: SshHostsSection()));
    await expectOpensTheDialog(
      tester,
      find.widgetWithText(TextButton, kPairPhoneLabel),
    );
  });

  testWidgets('the environment card has it, for a box and for nothing else', (
    tester,
  ) async {
    await pump(
      tester,
      const SingleChildScrollView(child: EnvironmentsSection()),
    );
    // Two environments, one button: this computer has no address of its own
    // for a phone to pair with.
    await expectOpensTheDialog(
      tester,
      find.widgetWithText(TextButton, kPairPhoneLabel),
    );
  });

  testWidgets(
    'the environment card says which route was chosen, once one was',
    (tester) async {
      await pump(
        tester,
        const SingleChildScrollView(child: EnvironmentsSection()),
      );
      // Nobody has chosen, so nothing is claimed: the dial decides next time.
      expect(find.textContaining('Phones connect'), findsNothing);
    },
  );

  testWidgets('and says it from the store, so it survives a restart', (
    tester,
  ) async {
    CompanionRouteStore(server.store).write('h1', HostRoute.relay);
    await pump(
      tester,
      const SingleChildScrollView(child: EnvironmentsSection()),
    );
    expect(
      find.text('Phones connect through the hosted relay.'),
      findsOneWidget,
    );
  });

  testWidgets('the health panel has it on the box\'s row', (tester) async {
    await pump(tester, const EnvironmentHealthDialog());
    await expectOpensTheDialog(
      tester,
      find.widgetWithText(TextButton, kPairPhoneLabel),
    );
  });

  test('only an SSH environment with a saved host is pairable', () {
    expect(windowsEnv().kind, isNot(EnvironmentKind.ssh));
    expect(sshEnvFixture().sshHostId, 'h1');
  });
}
