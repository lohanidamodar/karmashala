import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/overview/presentation/overview_via_bot_label.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../support/fixtures.dart';

void main() {
  Widget host(Session? row, {double scale = 1}) => MaterialApp(
    theme: ThemeData(extensions: const []),
    home: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(scale)),
      child: Scaffold(
        body: SizedBox(
          width: Insets.xl * 3,
          child: Row(
            children: [Flexible(child: OverviewViaBotLabel(session: row))],
          ),
        ),
      ),
    ),
  );

  testWidgets('a session the bot started says so', (tester) async {
    await tester.pumpWidget(host(session(id: 's1').copyWith(viaBot: true)));
    expect(find.text('via Bot'), findsOneWidget);
    expect(find.byTooltip('The bot started this session'), findsOneWidget);
  });

  testWidgets('any other session says nothing', (tester) async {
    await tester.pumpWidget(host(session(id: 's1')));
    expect(find.text('via Bot'), findsNothing);
    await tester.pumpWidget(host(null));
    expect(find.text('via Bot'), findsNothing);
  });

  testWidgets('it does not overflow a narrow slot at 1.6', (tester) async {
    await tester.pumpWidget(
      host(session(id: 's1').copyWith(viaBot: true), scale: 1.6),
    );
    expect(tester.takeException(), isNull);
  });
}
