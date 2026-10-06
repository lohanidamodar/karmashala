import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/quick_open/quick_open.dart';
import 'package:karmashala/src/core/logging/diagnostics_providers.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/features/server/application/server_overview.dart';
import 'package:karmashala/src/features/settings/application/settings_tab.dart';
import 'package:karmashala/src/features/settings/presentation/settings_catalog.dart';
import 'package:karmashala/src/features/terminal/application/local_host_providers.dart';
import 'package:karmashala_host_protocol/host_access.dart';

import '../../../features/terminal/fake_instance.dart';
import '../../../support/fake_command_runner.dart';
import '../../../support/fake_data_server.dart';
import '../../../support/test_machine.dart';

/// Quick open's server commands: Stop, Restart or Start as the server's state
/// allows, Server settings and its log — each the Server page's own action.
void main() {
  ServerOverview running({int live = 3}) => ServerOverview(
    state: ServerRunState.running,
    appVersion: '1.31.1',
    liveSessions: live,
    endedSessions: 0,
  );

  const stopped = ServerOverview(
    state: ServerRunState.stopped,
    appVersion: '1.31.1',
    canStart: true,
    canRestart: false,
    canStop: false,
  );

  const elsewhere = ServerOverview(
    state: ServerRunState.running,
    appVersion: '1.31.1',
    controlsRefusal: 'This window is connected to a server on another machine.',
    usesAnotherMachine: true,
  );

  Future<(ProviderContainer, _FakeHostStatus)> open(
    WidgetTester tester,
    ServerOverview overview,
  ) async {
    final db = TestMachine();
    final server = FakeDataServer()..runsOn(db);
    final status = _FakeHostStatus();
    final container = ProviderContainer(
      overrides: [
        await server.override(),
        ...fakeTerminalOverrides(machine: db),
        localHostSessionAccessProvider.overrideWithValue(null),
        localHostStatusProvider.overrideWith(() => status),
        serverOverviewProvider.overrideWith((ref) async => overview),
        serverLogFileProvider.overrideWith(
          (ref) async =>
              File('${Directory.systemTemp.path}/no-such/server.log'),
        ),
        hostCommandRunnerProvider.overrideWithValue(FakeCommandRunner()),
      ],
    );
    addTearDown(container.dispose);
    await container.read(serverOverviewProvider.future);
    await container.read(serverLogFileProvider.future);
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
    return (container, status);
  }

  Future<void> type(WidgetTester tester, String query) async {
    await tester.enterText(find.byType(TextField), query);
    await tester.pumpAndSettle();
  }

  /// Scrolls the results until [text]'s row is built: for "server", Settings'
  /// Server page is an exact match and rightly ranks above the verbs.
  Future<void> reveal(WidgetTester tester, String text) =>
      tester.scrollUntilVisible(
        find.text(text),
        80,
        scrollable: find
            .descendant(
              of: find.byType(ListView),
              matching: find.byType(Scrollable),
            )
            .first,
      );

  /// Whether [label] is offered at all: queried by its own name, it would be
  /// the first row.
  Future<bool> offered(WidgetTester tester, String label) async {
    await type(tester, label.toLowerCase());
    return find.text(label).evaluate().isNotEmpty;
  }

  testWidgets('a running server can be stopped or restarted, and its '
      'settings and log opened', (tester) async {
    await open(tester, running());

    await type(tester, 'server');
    for (final label in [
      'Stop server',
      'Restart server',
      'Open Server settings',
      'Open server log',
    ]) {
      await reveal(tester, label);
      expect(find.text(label), findsOneWidget);
    }
    expect(find.textContaining('running · 3 sessions'), findsWidgets);
    expect(await offered(tester, 'Start server'), isFalse);
  });

  testWidgets('the verb leads with its command, and an empty box lists none '
      'of them', (tester) async {
    await open(tester, running());

    expect(find.text('Stop server'), findsNothing);
    expect(find.text('Open Server settings'), findsNothing);

    await type(tester, 'stop');
    final stop = tester.getTopLeft(find.text('Stop server')).dy;
    expect(stop, greaterThan(tester.getTopLeft(find.text('COMMANDS')).dy));
    for (final header in ['SETTINGS', 'SESSIONS']) {
      final found = find.text(header);
      if (found.evaluate().isNotEmpty) {
        expect(stop, lessThan(tester.getTopLeft(found).dy));
      }
    }
  });

  testWidgets('a stopped one is offered Start alone', (tester) async {
    await open(tester, stopped);

    await type(tester, 'server');
    await reveal(tester, 'Start server');
    expect(find.text('Start server'), findsOneWidget);
    expect(await offered(tester, 'Stop server'), isFalse);
    expect(await offered(tester, 'Restart server'), isFalse);
  });

  for (final query in ['host', 'session host']) {
    testWidgets('"$query" finds them', (tester) async {
      await open(tester, running());

      await type(tester, query);
      await reveal(tester, 'Stop server');
      expect(find.text('Stop server'), findsOneWidget);
      await reveal(tester, 'Open Server settings');
      expect(find.text('Open Server settings'), findsOneWidget);
    });
  }

  testWidgets('none of the controls when the window uses another machine\'s '
      'server, and Server settings says why', (tester) async {
    await open(tester, elsewhere);

    for (final label in ['Stop server', 'Restart server', 'Start server']) {
      expect(await offered(tester, label), isFalse, reason: label);
    }
    await type(tester, 'server settings');
    expect(find.text('Open Server settings'), findsOneWidget);
    expect(
      find.text('This window is connected to a server on another machine.'),
      findsOneWidget,
    );
  });

  testWidgets('Stop server asks first, naming the sessions it ends', (
    tester,
  ) async {
    final (_, status) = await open(tester, running(live: 2));

    await type(tester, 'stop server');
    await tester.tap(find.text('Stop server'));
    await tester.pumpAndSettle();
    expect(find.text('Stop the server?'), findsOneWidget);
    expect(find.textContaining('ends the 2 running sessions'), findsOneWidget);

    await tester.tap(find.text('Stop').last);
    await tester.pumpAndSettle();
    expect(status.calls, ['stop(force: true)']);
  });

  testWidgets('Restart server asks first too', (tester) async {
    final (_, status) = await open(tester, running(live: 1));

    await type(tester, 'restart server');
    await tester.tap(find.text('Restart server'));
    await tester.pumpAndSettle();
    expect(find.text('Restart the server?'), findsOneWidget);
    await tester.tap(find.text('Restart').last);
    await tester.pumpAndSettle();
    expect(status.calls, ['restart(force: true)']);
  });

  testWidgets('Start server starts it', (tester) async {
    final (_, status) = await open(tester, stopped);

    await type(tester, 'start server');
    await tester.tap(find.text('Start server'));
    await tester.pumpAndSettle();
    expect(status.calls, ['start()']);
  });

  testWidgets('Open Server settings lands on its status section', (
    tester,
  ) async {
    final (container, _) = await open(tester, running());

    await type(tester, 'server settings');
    await tester.tap(find.text('Open Server settings'));
    await tester.pumpAndSettle();
    expect(
      container.read(settingsTabSectionProvider)?.anchor,
      SettingsAnchor.serverStatus,
    );
  });

  testWidgets('Open server log opens it as the page does, and says when '
      'there is none yet', (tester) async {
    await open(tester, running());

    await type(tester, 'server log');
    await tester.tap(find.text('Open server log'));
    await tester.pumpAndSettle();
    expect(
      find.text('The server has not written its log yet.'),
      findsOneWidget,
    );
  });
}

class _FakeHostStatus extends LocalHostStatusController {
  final calls = <String>[];

  @override
  HostDeployment? build() => null;

  @override
  Future<void> refresh() async {}

  @override
  Future<void> start() async => calls.add('start()');

  @override
  Future<void> restart({required bool force}) async =>
      calls.add('restart(force: $force)');

  @override
  Future<void> stop({required bool force}) async =>
      calls.add('stop(force: $force)');
}
