import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/ask_toasts.dart';
import 'package:karmashala_ui/theme.dart';

/// The ask toast (UI overhaul spec §5), drawn from values.
void main() {
  const ask = OffScreenAsk(
    openId: 's1',
    label: 'Trail API pagination',
    imported: false,
    detail: 'Do you want to run npm test?',
    canAnswer: true,
  );

  Future<List<String>> pump(
    WidgetTester tester,
    OffScreenAsk ask, {
    bool answerable = true,
  }) async {
    final events = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: Center(
            child: AskToast(
              ask: ask,
              onAnswer: answerable
                  ? (approve) => events.add(approve ? 'yes' : 'no')
                  : null,
              onOpen: () => events.add('open'),
              onDismiss: () => events.add('dismiss'),
            ),
          ),
        ),
      ),
    );
    return events;
  }

  testWidgets('says who is asking and what, and answers in place', (
    tester,
  ) async {
    final events = await pump(tester, ask);
    expect(find.text('Trail API pagination needs you'), findsOneWidget);
    expect(find.text('Do you want to run npm test?'), findsOneWidget);

    await tester.tap(find.text('Yes'));
    await tester.tap(find.text('No'));
    await tester.tap(find.text('Open'));
    await tester.tap(find.byTooltip('Dismiss'));
    expect(events, ['yes', 'no', 'open', 'dismiss']);
  });

  testWidgets('an ask that can only be answered in its terminal offers Open', (
    tester,
  ) async {
    await pump(tester, ask, answerable: false);
    expect(find.text('Yes'), findsNothing);
    expect(find.text('No'), findsNothing);
    expect(find.text('Open'), findsOneWidget);
  });

  testWidgets('an ask with nothing readable still names the session', (
    tester,
  ) async {
    const quiet = OffScreenAsk(
      openId: 's2',
      label: 'Lake generator polish',
      imported: false,
      detail: null,
      canAnswer: false,
    );
    await pump(tester, quiet, answerable: false);
    expect(find.text('Lake generator polish needs you'), findsOneWidget);
  });
}
