import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/capabilities/capabilities.dart';
import 'package:karmashala/src/features/settings/presentation/new_session_grant_section.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';

/// Settings › Agents and accounts › New sessions: the server's "Let new
/// sessions operate Karmashala".
void main() {
  late FakeDataServer server;

  Future<void> pump(
    WidgetTester tester, {
    Size size = const Size(1440, 900),
    double textScale = 1,
    Set<String> features = const {SessionsOperateByDefaultSet.feature},
    bool on = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    server = FakeDataServer(clock: () => testTime)..operateNewSessions = on;
    final container = ProviderContainer(
      overrides: [
        await server.override(),
        serverOfferProvider.overrideWithValue(
          ServerOffer(sameMachine: true, features: features),
        ),
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
            body: SingleChildScrollView(child: NewSessionGrantSection()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder toggle() => find.descendant(
    of: find.byKey(const ValueKey('operate-new-sessions')),
    matching: find.byType(Switch),
  );

  bool shown(WidgetTester tester) => tester.widget<Switch>(toggle()).value;

  testWidgets('off until the person turns it on', (tester) async {
    await pump(tester);
    expect(find.text('Let new sessions operate Karmashala'), findsOneWidget);
    expect(shown(tester), isFalse);

    await tester.tap(toggle());
    await tester.pumpAndSettle();
    expect(server.operateNewSessions, isTrue);
    expect(shown(tester), isTrue);

    await tester.tap(toggle());
    await tester.pumpAndSettle();
    expect(server.operateNewSessions, isFalse);
    expect(shown(tester), isFalse);
  });

  testWidgets('shows what the server holds', (tester) async {
    await pump(tester, on: true);
    expect(shown(tester), isTrue);
  });

  testWidgets('says plainly what turning it on risks', (tester) async {
    await pump(tester);
    expect(find.textContaining('other sessions'), findsOneWidget);
    expect(find.textContaining('prompt injected'), findsOneWidget);
    expect(find.textContaining('not a sandbox'), findsOneWidget);
  });

  testWidgets('a refusal leaves the switch and says why', (tester) async {
    await pump(tester);
    server.operateRefusal = 'this device was not granted start_session';
    await tester.tap(toggle());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(shown(tester), isFalse);
    expect(find.textContaining('not granted start_session'), findsOneWidget);
  });

  testWidgets('an older server hides the row', (tester) async {
    await pump(tester, features: const {});
    expect(find.byKey(const ValueKey('operate-new-sessions')), findsNothing);
    expect(find.text('New sessions'), findsNothing);
  });

  for (final (name, size, scale) in const [
    ('a 360 px phone', Size(360, 740), 1.0),
    ('a phone at text scale 1.6', Size(360, 740), 1.6),
    ('the minimum window at text scale 1.6', Size(720, 560), 1.6),
    ('a wide desktop', Size(2560, 1440), 1.0),
  ]) {
    testWidgets('fits $name', (tester) async {
      await pump(tester, size: size, textScale: scale);
      expect(tester.takeException(), isNull);
      expect(toggle(), findsOneWidget);
    });
  }
}
