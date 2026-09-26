/// A menu the agent drew on its screen, on the phone: the agent's own options,
/// a deliberate choice before anything is sent, the terminal's default named
/// for what it is — and never the Approve button, which would press Enter on
/// whatever is highlighted ("No, exit", on a folder-trust prompt).
library;

import 'package:karmashala_companion/widgets.dart';
import 'package:karmashala_remote/companion.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'companion_test_support.dart';

void main() {
  const trust = RemoteMenu(
    menuId: 'm1',
    prompt: [
      'Accessing workspace:',
      r'C:\work\demo',
      'Quick safety check: Is this a project you created or one you trust?',
    ],
    options: ['No, exit', 'Yes, I trust this folder'],
    highlighted: 0,
  );

  CompanionApproval asking(RemoteMenu menu) => CompanionApproval(
    id: 'a1',
    sessionId: 's1',
    agentName: 'Claude Code',
    waiting: RemoteWaitKind.approval,
    evidence: menu.prompt,
    menu: menu,
  );

  late List<int> chosen;
  setUp(() => chosen = []);

  Future<void> pump(
    WidgetTester tester,
    CompanionApproval approval, {
    bool canAnswer = true,
  }) => pumpPhone(
    tester,
    gateway: FakeCompanionGateway.paired(),
    home: Scaffold(
      body: CompanionApprovalCard(
        approval: approval,
        canAnswer: canAnswer,
        onAnswer: (_) async => fail('a menu is never approved'),
        onAnswerMenu: (option) async => chosen.add(option),
      ),
    ),
  );

  testWidgets('the options, the prompt, and no Approve anywhere', (
    tester,
  ) async {
    await pump(tester, asking(trust));

    expect(find.text('No, exit'), findsOneWidget);
    expect(find.text('Yes, I trust this folder'), findsOneWidget);
    expect(find.textContaining('Quick safety check'), findsOneWidget);
    expect(find.text('Approve'), findsNothing);
    expect(
      find.textContaining('what Enter alone would pick'),
      findsOneWidget,
      reason: 'the terminal default is named, once',
    );
  });

  testWidgets('nothing is sent until an option is picked', (tester) async {
    await pump(tester, asking(trust));
    final button = find.widgetWithText(FilledButton, 'Choose');

    expect(tester.widget<FilledButton>(button).onPressed, isNull);

    await tester.tap(find.text('Yes, I trust this folder'));
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();

    expect(chosen, [1]);
  });

  testWidgets('a new menu starts with nothing picked', (tester) async {
    await pump(tester, asking(trust));
    await tester.tap(find.text('Yes, I trust this folder'));
    await tester.pumpAndSettle();

    await pump(
      tester,
      asking(
        const RemoteMenu(
          menuId: 'm2',
          prompt: ['Do you want to proceed?'],
          options: ['Yes', 'No'],
          highlighted: 0,
        ),
      ),
    );

    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Choose'))
          .onPressed,
      isNull,
    );
  });

  testWidgets('a phone without approval rights is told so, and offered '
      'nothing', (tester) async {
    await pump(tester, asking(trust), canAnswer: false);

    expect(find.textContaining('not granted approval rights'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Choose'), findsNothing);
  });

  testWidgets('without a way to answer menus, the card falls back to the '
      'notice', (tester) async {
    await pumpPhone(
      tester,
      gateway: FakeCompanionGateway.paired(),
      home: Scaffold(
        body: CompanionApprovalCard(
          approval: asking(trust),
          onAnswer: (_) async => fail('a menu is never approved'),
        ),
      ),
    );

    expect(find.text('Approve'), findsNothing);
    expect(find.widgetWithText(FilledButton, 'Choose'), findsNothing);
  });
}
