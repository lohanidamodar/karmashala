import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/sessions/presentation/approval_request_card.dart';

import '../../support/fake_data_server.dart';

/// An agent asking for a secret, in its own session's dock: the label and
/// reason, a masked field, Save securely and Decline. The value goes to the
/// server once and the card goes; another session's request is not shown.
void main() {
  late FakeDataServer server;

  Future<void> pump(
    WidgetTester tester, {
    Size size = const Size(1200, 900),
    double textScale = 1,
    bool touch = false,
  }) async {
    tester.view
      ..physicalSize = size
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final data = await server.override();
    final container = ProviderContainer(overrides: [data]);
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
              size: size,
              textScaler: TextScaler.linear(textScale),
            ),
            child: Scaffold(
              body: SingleChildScrollView(
                child: SecretRequestCard(sessionId: 's1', touch: touch),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  setUp(() {
    server = FakeDataServer(clock: () => DateTime.utc(2026, 10, 8));
  });

  testWidgets('nothing is drawn while no agent here is asking', (tester) async {
    server.secrets.ask('s2');
    await pump(tester);
    expect(find.byKey(const ValueKey('secret-value')), findsNothing);
  });

  testWidgets('Save securely sends the value once and the card goes', (
    tester,
  ) async {
    final request = server.secrets.ask(
      's1',
      label: 'Stripe signing secret',
      reason: 'To verify the webhook you asked for.',
    );
    await pump(tester);
    expect(find.text('The agent asks for Stripe signing secret'), findsOneWidget);
    expect(find.text('To verify the webhook you asked for.'), findsOneWidget);
    final field = tester.widget<TextField>(
      find.byKey(const ValueKey('secret-value')),
    );
    expect(field.obscureText, isTrue);

    await tester.enterText(
      find.byKey(const ValueKey('secret-value')),
      'whsec_123',
    );
    await tester.tap(find.byKey(const ValueKey('secret-save')));
    await tester.pumpAndSettle();
    expect(server.secrets.saved, {request.id: 'whsec_123'});
    expect(find.byKey(const ValueKey('secret-value')), findsNothing);
  });

  testWidgets('an empty value is not sent', (tester) async {
    server.secrets.ask('s1');
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('secret-save')));
    await tester.pumpAndSettle();
    expect(server.secrets.saved, isEmpty);
    expect(find.text('Enter the secret to save.'), findsOneWidget);
  });

  testWidgets('Decline answers the agent and keeps nothing', (tester) async {
    final request = server.secrets.ask('s1');
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('secret-decline')));
    await tester.pumpAndSettle();
    expect(server.secrets.declined, [request.id]);
    expect(server.secrets.saved, isEmpty);
    expect(find.byKey(const ValueKey('secret-value')), findsNothing);
  });

  for (final (name, size, scale, touch) in [
    ('a 360 px phone at text scale 1.6', const Size(360, 1200), 1.6, true),
    ('a wide desktop', const Size(1600, 900), 1.0, false),
  ]) {
    testWidgets('lays out without overflow on $name', (tester) async {
      server.secrets.ask(
        's1',
        label: 'A rather long label for a webhook signing secret',
        reason: 'A reason long enough to wrap across more than one line here.',
      );
      await pump(tester, size: size, textScale: scale, touch: touch);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('secret-save')), findsOneWidget);
    });
  }
}
