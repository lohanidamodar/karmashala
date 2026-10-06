import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/quick_open/quick_open.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/features/browser/application/browser_pane_controller.dart';
import 'package:karmashala/src/features/running/application/running_providers.dart';
import 'package:karmashala/src/features/running/domain/port_label.dart';
import 'package:karmashala/src/features/terminal/application/local_host_providers.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

import '../../../features/terminal/fake_instance.dart';
import '../../../support/fake_command_runner.dart';
import '../../../support/fake_data_server.dart';
import '../../../support/test_machine.dart';

/// A reading already taken: quick open reads nothing of its own.
class _Known extends RunningController {
  @override
  RunningSnapshot build() => RunningSnapshot(
    reading: RunningReading(
      serverPid: 1,
      checkedAt: DateTime.utc(2026, 10, 6),
      processes: const [
        RunningProcess(
          pid: 1,
          parent: 0,
          name: 'karmashala_host.exe',
          role: RunningRole.server,
          ports: [RunningPort(port: 47821, address: '127.0.0.1')],
        ),
        RunningProcess(
          pid: 11,
          parent: 10,
          name: 'node.exe',
          role: RunningRole.child,
          title: 'Fix the build',
          ports: [RunningPort(port: 5173, address: '::1')],
        ),
        RunningProcess(
          pid: 12,
          parent: 10,
          name: 'postgres.exe',
          role: RunningRole.child,
          title: 'Fix the build',
          ports: [RunningPort(port: 5432, address: '127.0.0.1')],
        ),
      ],
    ),
  );
}

class _Browser extends BrowserPaneController {
  final navigated = <String>[];

  @override
  BrowserPaneState build() => const BrowserPaneState();

  @override
  Future<void> navigate(String url) async => navigated.add(url);
}

void main() {
  late _Browser browser;

  Future<void> open(WidgetTester tester) async {
    final db = TestMachine();
    final server = FakeDataServer()..runsOn(db);
    browser = _Browser();
    final container = ProviderContainer(
      overrides: [
        await server.override(),
        ...fakeTerminalOverrides(machine: db),
        localHostSessionAccessProvider.overrideWithValue(null),
        hostCommandRunnerProvider.overrideWithValue(FakeCommandRunner()),
        runningProvider.overrideWith(_Known.new),
        portFactsProvider.overrideWithValue(const PortFacts()),
        browserPaneControllerProvider.overrideWith(() => browser),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => QuickOpen.show(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Future<void> type(WidgetTester tester, String query) async {
    await tester.enterText(find.byType(TextField), query);
    await tester.pumpAndSettle();
  }

  testWidgets('Running is found by either name', (tester) async {
    await open(tester);
    await type(tester, 'running');
    expect(find.text('Open Running'), findsOneWidget);
    await type(tester, 'ports');
    expect(find.text('Show ports'), findsOneWidget);
  });

  testWidgets('each http port the last reading found can be opened; a '
      'database and the server cannot', (tester) async {
    await open(tester);
    expect(
      find.text('Open localhost:5173'),
      findsNothing,
      reason: 'only when searched',
    );
    await type(tester, 'localhost');
    expect(find.text('Open localhost:5173'), findsOneWidget);
    expect(find.text('Open localhost:5432'), findsNothing);
    expect(find.text('Open localhost:47821'), findsNothing);
    await tester.tap(find.text('Open localhost:5173'));
    await tester.pumpAndSettle();
    expect(browser.navigated, ['http://localhost:5173']);
  });
}
