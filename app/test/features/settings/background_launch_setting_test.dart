import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/overview/application/overview_prefs.dart';
import 'package:karmashala/src/features/settings/presentation/general_pages.dart';

import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';

/// Settings › General › Session view: whether resuming and starting from the
/// palette, the dashboard and a session's menu stays in the background. Kept
/// per device, in the dashboard's own file.
void main() {
  late Directory prefs;

  setUp(() => prefs = Directory.systemTemp.createTempSync('ks-r56-setting'));
  tearDown(() {
    try {
      prefs.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows may still hold the file; the OS sweeps temp.
    }
  });

  Future<ProviderContainer> pump(
    WidgetTester tester, {
    Size size = const Size(1440, 900),
    double textScale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final server = FakeDataServer(clock: () => testTime);
    final container = ProviderContainer(
      overrides: [
        await server.override(),
        overviewPrefsDirectoryProvider.overrideWithValue(() async => prefs),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: const Scaffold(
            body: SingleChildScrollView(child: SessionViewSection()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  Finder toggle() => find.descendant(
    of: find.byKey(const ValueKey('settings-launch-in-background')),
    matching: find.byType(Switch),
  );

  testWidgets('it sits beside chat view, on, and writes the choice', (
    tester,
  ) async {
    final c = await pump(tester);

    expect(find.text('Open agent sessions in chat view'), findsOneWidget);
    expect(
      find.text('Resume and start sessions in the background'),
      findsOneWidget,
    );
    expect(tester.widget<Switch>(toggle()).value, isTrue);

    await tester.tap(toggle());
    await tester.pumpAndSettle();

    expect(c.read(overviewPrefsProvider).launchInBackground, isFalse);
    expect(tester.widget<Switch>(toggle()).value, isFalse);
  });

  testWidgets('at 360 px and text scale 1.6 the row fits', (tester) async {
    await pump(tester, size: const Size(360, 740), textScale: 1.6);

    expect(tester.takeException(), isNull);
    expect(
      find.text('Resume and start sessions in the background'),
      findsOneWidget,
    );
    final row = tester.getRect(
      find.byKey(const ValueKey('settings-launch-in-background')),
    );
    expect(row.right, lessThanOrEqualTo(360));
  });
}
