import 'package:agent_cli/descriptors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/automations/application/automation_providers.dart';
import 'package:karmashala/src/features/automations/presentation/automation_dialog.dart';
import 'package:karmashala_automations/automations.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';
import '../../support/fake_data_server.dart';

/// A new automation keeps the late policy chosen while creating it.
void main() {
  late ProviderContainer container;
  final now = DateTime.utc(2026, 10, 7, 9);

  setUp(() async {
    final server = FakeDataServer();
    server.environmentRows.upsert(windowsEnv());
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    server.installationRows.insert(
      agentInstallation(agentId: AgentIds.claudeCode),
    );
    container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(),
        await server.override(),
        clockProvider.overrideWithValue(FixedClock(now)),
      ],
    );
    container
        .read(projectChecksDataProvider)
        .setVerification('r1', enabled: true);
    container.read(automationControllerProvider).addCheck('r1', 'tests', const [
      'flutter',
      'test',
    ]);
  });
  tearDown(() => container.dispose());

  Finder item<T>(T value) => find.byWidgetPredicate(
    (w) => w is DropdownMenuItem<T> && w.value == value,
  );

  testWidgets('creating one stores the late policy that was picked', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1440, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () =>
                    AutomationDialog.show(context, repository: repository()),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'Nightly');
    await tester.enterText(find.byType(TextField).last, 'run the tests');
    await tester.tap(find.byType(DropdownButton<AutomationLatePolicy>));
    await tester.pumpAndSettle();
    await tester.tap(item(AutomationLatePolicy.skip).last);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(item('a1').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<String>).last);
    await tester.pumpAndSettle();
    await tester.tap(item('mode=auto').last);
    await tester.pumpAndSettle();

    final arm = find.widgetWithText(FilledButton, 'Arm');
    expect(tester.widget<FilledButton>(arm).onPressed, isNotNull);
    await tester.tap(arm);
    await tester.pumpAndSettle();

    final stored = serverOf(container).automationRows.getAll().single;
    expect(stored.latePolicy, AutomationLatePolicy.skip);
  });
}
