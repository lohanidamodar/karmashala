import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/flutter_apps/presentation/flutter_app_pane.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_flutter_apps/flutter_apps.dart';
import 'package:karmashala_ui/panes.dart';

import '../../support/fake_data_server.dart';
import 'flutter_apps_harness.dart';

/// The Flutter app pane as a client of the server's apps (slice 3d): it
/// shows what the server holds, streams the console, and asks.
void main() {
  late FakeDataServer server;

  Future<ProviderContainer> pump(
    WidgetTester tester, {
    List<AttachedApp>? apps,
  }) async {
    tester.view
      ..physicalSize = const Size(900, 1100)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final (container, fake) = await flutterPaneContainer(apps: apps);
    server = fake;
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: FlutterAppPane())),
      ),
    );
    await tester.runAsync(pumpEventQueue);
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets('its status line is the shared one the browser pane uses', (
    tester,
  ) async {
    await pump(tester, apps: const []);
    expect(find.byType(PaneStatusRow), findsOneWidget);
    expect(find.byType(StatusDot), findsOneWidget);
    expect(find.byTooltip('Look again'), findsOneWidget);
  });

  testWidgets('says nothing is running, and how to make one visible', (
    tester,
  ) async {
    await pump(tester, apps: const []);
    // The status line says it, and the placeholder says it with the remedy.
    expect(
      find.textContaining('No Flutter app is running that we can see.'),
      findsNWidgets(2),
    );
    expect(find.textContaining('the server\'s machine'), findsOneWidget);
    expect(find.text('Attach by address'), findsOneWidget);
  });

  testWidgets('opening the pane asks the server to look, once', (tester) async {
    await pump(tester);
    bool looked(DataRequest<Object?> r) => r is FlutterApps && r.look;
    expect(server.runs.asked.where(looked), hasLength(1));

    // Nothing polls: pumping the tree for a while asks nothing more.
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(seconds: 5));
    expect(server.runs.asked.where(looked), hasLength(1));
  });

  testWidgets('streams the console, and marks what was replayed', (
    tester,
  ) async {
    await pump(tester);
    final console = ConsoleFake(server)
      ..emitStdout('flutter: hello', at: DateTime.utc(2026, 9, 8, 1))
      ..emitStdout('older', at: DateTime.utc(2026, 9, 7));
    expect(console.server.runs.following(console.appId), isTrue);
    await tester.runAsync(pumpEventQueue);
    await tester.pumpAndSettle();

    expect(find.text('flutter: hello'), findsOneWidget);
    expect(find.text('older'), findsOneWidget);
    expect(find.text('before attach'), findsOneWidget);
  });

  testWidgets('an error offers itself and is never sent', (tester) async {
    await pump(tester);
    ConsoleFake(server).emitFlutterError(flutterErrorTree());
    await tester.runAsync(pumpEventQueue);
    await tester.pumpAndSettle();

    expect(
      find.textContaining('newest error: The following StateError'),
      findsOneWidget,
    );
    expect(find.text('Offer error to session'), findsOneWidget);
  });

  testWidgets('hot reload is off, with the reason, until a tool attaches', (
    tester,
  ) async {
    await pump(tester);

    Tooltip tooltipFor(String label) => tester.widget<Tooltip>(
      find.ancestor(of: find.text(label), matching: find.byType(Tooltip)),
    );

    expect(
      tooltipFor('Hot reload').message,
      contains('No Flutter tool is attached'),
    );

    server.runs.setApps(
      registryOf([attachedApp(reloadMethod: 's1.reloadSources')]),
    );
    await tester.runAsync(pumpEventQueue);
    await tester.pumpAndSettle();
    expect(tooltipFor('Hot reload').message, 'Hot reload');

    await tester.tap(find.text('Hot reload'));
    await tester.runAsync(pumpEventQueue);
    await tester.pumpAndSettle();
    final reload = server.runs.asked.whereType<FlutterReload>().single;
    expect(reload.appId, '127.0.0.1:1/a=');
    expect(reload.full, isFalse);
  });

  testWidgets('a refusal is said in the server\'s words', (tester) async {
    await pump(tester, apps: [attachedApp(reloadMethod: 's1.reloadSources')]);
    server.runs.onFlutter = (request) => request is FlutterReload
        ? throw const DataRefused(
            DataRefusalCode.failed,
            'The reload did not reach the VM.',
          )
        : server.runs.apps;

    await tester.tap(find.text('Restart'));
    await tester.runAsync(pumpEventQueue);
    await tester.pumpAndSettle();

    expect(
      find.text('Restart: The reload did not reach the VM.'),
      findsOneWidget,
    );
  });

  testWidgets('lists every app when more than one is running', (tester) async {
    await pump(
      tester,
      apps: [
        attachedApp(),
        attachedApp(id: '127.0.0.1:2/b=', label: 'pixel'),
      ],
    );

    expect(
      find.text('2 Flutter apps attached.  ·  checked just now'),
      findsOneWidget,
    );
    expect(find.text('windows'), findsOneWidget);
    expect(find.text('pixel'), findsOneWidget);
    expect(
      find.textContaining('started here · found just now'),
      findsNWidgets(2),
    );
  });

  testWidgets('says a build carries no widget locations rather than nothing', (
    tester,
  ) async {
    await pump(
      tester,
      apps: [attachedApp(widgetLocations: WidgetLocationSupport.absent)],
    );
    expect(
      find.text('This build carries no widget locations.'),
      findsOneWidget,
    );
  });

  testWidgets('an address nothing answers on says so and offers Forget', (
    tester,
  ) async {
    await pump(
      tester,
      apps: [
        attachedApp(
          id: '127.0.0.1:9/gone=',
          reachability: AppReachability.unreachable,
          detail: 'Nothing answered.',
        ),
      ],
    );
    expect(
      find.textContaining('1 address is on record and nothing answers on it.'),
      findsOneWidget,
    );
    expect(find.text('Forget'), findsOneWidget);
    expect(find.text('Detach'), findsNothing);

    await tester.tap(find.text('Forget'));
    await tester.runAsync(pumpEventQueue);
    await tester.pumpAndSettle();
    expect(
      server.runs.asked.whereType<FlutterForget>().single.appId,
      '127.0.0.1:9/gone=',
    );
  });
}
