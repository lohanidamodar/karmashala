import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/flutter_apps/application/flutter_app_ui_providers.dart';
import 'package:karmashala/src/features/flutter_apps/presentation/flutter_app_pane.dart';
import 'package:karmashala/src/features/flutter_apps/presentation/flutter_app_picker.dart';
import 'package:karmashala/src/features/flutter_apps/presentation/flutter_console.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_flutter_apps/flutter_apps.dart';

import '../../support/fake_data_server.dart';
import 'flutter_apps_harness.dart';

/// The Flutter panel's app picker (round 113): one row however many apps
/// there are, answering apps first, the rest muted with Forget.
void main() {
  late FakeDataServer server;

  List<AttachedApp> manyApps() => [
    for (var i = 0; i < 8; i++)
      attachedApp(
        id: '127.0.0.1:${i + 1}/live$i=',
        label: 'a running app with a long name number $i',
      ),
    for (var i = 0; i < 3; i++)
      attachedApp(
        id: '10.0.0.$i:5000/hand$i=',
        label: '10.0.0.$i:5000',
        discovery: AppDiscovery.byHand,
        reachability: AppReachability.unreachable,
        detail: 'Nothing answered on that address.',
      ),
  ];

  Future<ProviderContainer> pump(
    WidgetTester tester, {
    required List<AttachedApp> apps,
    double width = 272,
    double textScale = 1,
  }) async {
    tester.view
      ..physicalSize = const Size(900, 900)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final (container, fake) = await flutterPaneContainer(apps: apps);
    server = fake;
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
              size: const Size(900, 900),
              textScaler: TextScaler.linear(textScale),
            ),
            child: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: width,
                  height: 700,
                  child: const FlutterAppPane(),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.runAsync(pumpEventQueue);
    await tester.pumpAndSettle();
    return container;
  }

  Future<void> openPicker(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('flutter-app-picker')));
    await tester.pumpAndSettle();
  }

  for (final (width, scale) in [(272.0, 1.0), (360.0, 1.0), (272.0, 1.6)]) {
    testWidgets(
      'eleven apps take one row at ${width.toInt()}px, text x$scale',
      (tester) async {
        await pump(tester, apps: manyApps(), width: width, textScale: scale);
        expect(tester.takeException(), isNull);
        expect(find.byType(FlutterAppPicker), findsOneWidget);
        // The first answering app is selected; no other app is drawn.
        expect(find.text('a running app with a long name number 0'), findsOne);
        expect(
          find.text('a running app with a long name number 5'),
          findsNothing,
        );
        expect(find.text('11'), findsOneWidget);
        // The console has the rest of the panel.
        final picker = tester.getSize(find.byType(FlutterAppPicker));
        expect(picker.height, lessThan(80 * scale));
        expect(
          tester.getSize(find.byType(FlutterConsole)).height,
          greaterThan(300),
        );

        await openPicker(tester);
        expect(tester.takeException(), isNull);
        expect(find.text('ANSWERING'), findsOneWidget);
        expect(find.text('NOT ANSWERING'), findsOneWidget);
        expect(find.text('Forget all not answering'), findsOneWidget);
      },
    );
  }

  testWidgets('one app draws no picker', (tester) async {
    await pump(tester, apps: [attachedApp()]);
    expect(find.byType(FlutterAppPicker), findsNothing);
  });

  testWidgets('answering apps come first, whatever the registry order', (
    tester,
  ) async {
    await pump(
      tester,
      apps: [
        attachedApp(
          id: '10.0.0.1:5000/hand=',
          label: 'typed one',
          discovery: AppDiscovery.byHand,
          reachability: AppReachability.ended,
        ),
        attachedApp(label: 'windows'),
      ],
    );
    await openPicker(tester);
    final answering = tester.getTopLeft(find.text('ANSWERING')).dy;
    final quiet = tester.getTopLeft(find.text('NOT ANSWERING')).dy;
    expect(answering, lessThan(quiet));
    expect(tester.getTopLeft(find.text('windows').last).dy, lessThan(quiet));
    expect(tester.getTopLeft(find.text('typed one')).dy, greaterThan(quiet));
  });

  testWidgets('picking an app selects it', (tester) async {
    final container = await pump(
      tester,
      apps: [
        attachedApp(label: 'windows'),
        attachedApp(id: '127.0.0.1:2/b=', label: 'pixel'),
      ],
    );
    expect(container.read(paneFlutterAppIdProvider), '127.0.0.1:1/a=');
    await openPicker(tester);
    await tester.tap(find.text('pixel').last);
    await tester.pumpAndSettle();
    expect(container.read(paneFlutterAppIdProvider), '127.0.0.1:2/b=');
    expect(find.text('pixel'), findsOneWidget);
  });

  testWidgets('a row\'s Forget forgets that one', (tester) async {
    await pump(tester, apps: manyApps());
    await openPicker(tester);
    await tester.tap(find.byTooltip('Forget 10.0.0.1:5000'));
    await tester.runAsync(pumpEventQueue);
    await tester.pumpAndSettle();
    expect(server.runs.asked.whereType<FlutterForget>().map((r) => r.appId), [
      '10.0.0.1:5000/hand1=',
    ]);
  });

  testWidgets('Forget all forgets every one not answering, and only them', (
    tester,
  ) async {
    await pump(tester, apps: manyApps());
    await openPicker(tester);
    await tester.tap(find.text('Forget all not answering'));
    await tester.runAsync(pumpEventQueue);
    await tester.pumpAndSettle();
    expect(server.runs.asked.whereType<FlutterForget>().map((r) => r.appId), [
      '10.0.0.0:5000/hand0=',
      '10.0.0.1:5000/hand1=',
      '10.0.0.2:5000/hand2=',
    ]);
  });

  group('when the selected app is dropped', () {
    testWidgets('the next answering one is selected', (tester) async {
      final container = await pump(
        tester,
        apps: [
          attachedApp(label: 'windows'),
          attachedApp(id: '127.0.0.1:2/b=', label: 'pixel'),
          attachedApp(id: '127.0.0.1:3/c=', label: 'chrome'),
        ],
      );
      container
          .read(selectedFlutterAppIdProvider.notifier)
          .select('127.0.0.1:2/b=');
      await tester.pumpAndSettle();
      expect(find.text('pixel'), findsOneWidget);

      server.runs.setApps(
        registryOf([
          attachedApp(label: 'windows'),
          attachedApp(id: '127.0.0.1:3/c=', label: 'chrome'),
        ]),
      );
      await tester.runAsync(pumpEventQueue);
      await tester.pumpAndSettle();
      expect(container.read(paneFlutterAppIdProvider), '127.0.0.1:1/a=');
      expect(find.text('windows'), findsOneWidget);
      expect(find.byType(FlutterConsole), findsOneWidget);
    });

    testWidgets('with none answering, the empty state shows', (tester) async {
      final container = await pump(
        tester,
        apps: [
          attachedApp(label: 'windows'),
          attachedApp(
            id: '10.0.0.1:5000/hand=',
            label: 'typed one',
            discovery: AppDiscovery.byHand,
            reachability: AppReachability.unreachable,
          ),
          attachedApp(
            id: '10.0.0.2:5000/hand=',
            label: 'typed two',
            discovery: AppDiscovery.byHand,
            reachability: AppReachability.unreachable,
          ),
        ],
      );
      expect(container.read(paneFlutterAppIdProvider), '127.0.0.1:1/a=');

      server.runs.setApps(
        registryOf([
          attachedApp(
            id: '10.0.0.1:5000/hand=',
            label: 'typed one',
            discovery: AppDiscovery.byHand,
            reachability: AppReachability.unreachable,
          ),
          attachedApp(
            id: '10.0.0.2:5000/hand=',
            label: 'typed two',
            discovery: AppDiscovery.byHand,
            reachability: AppReachability.unreachable,
          ),
        ]),
      );
      await tester.runAsync(pumpEventQueue);
      await tester.pumpAndSettle();
      expect(container.read(paneFlutterAppIdProvider), isNull);
      expect(find.byType(FlutterConsole), findsNothing);
      expect(find.text('Choose an app'), findsOneWidget);
      expect(find.text('Attach by address'), findsOneWidget);
    });
  });
}
