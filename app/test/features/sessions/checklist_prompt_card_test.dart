import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/sessions/presentation/prompt_cards/checklist_prompt_card.dart';
import 'package:karmashala_remote/client.dart' show GatewayException;
import 'package:karmashala_remote/remote.dart';

/// Claude Code's project-MCP checklist as the card draws it: the agent's own
/// question, a box per server ticked as on screen, "Enable selected" and
/// "Reject all" — and nothing pressed until one of them is.
void main() {
  const menu = RemoteMenu(
    menuId: 'm1',
    prompt: [
      '2 new MCP servers found in this project',
      'Select any you wish to enable.',
      'MCP servers may execute code or access system resources. All tool '
          'calls require approval. Learn more in the MCP documentation.',
    ],
    options: ['dart', 'marionette', 'Enable selected'],
    highlighted: 2,
    checked: [true, true, null],
  );

  Future<({List<List<bool>> submitted, List<String> rejected})> pump(
    WidgetTester tester, {
    Size size = const Size(1440, 900),
    double textScale = 1,
    Object? failWith,
    VoidCallback? onOpenTerminal,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final submitted = <List<bool>>[];
    final rejected = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(
            size: size,
            textScaler: TextScaler.linear(textScale),
          ),
          child: Scaffold(
            body: SingleChildScrollView(
              child: ChecklistPromptCard(
                agentName: 'Claude Code',
                menu: menu,
                onSubmit: (ticks) async {
                  if (failWith != null) throw failWith;
                  submitted.add(ticks);
                },
                onReject: () async => rejected.add('rejected'),
                onOpenTerminal: onOpenTerminal,
              ),
            ),
          ),
        ),
      ),
    );
    return (submitted: submitted, rejected: rejected);
  }

  testWidgets('names the servers, ticked as on screen', (tester) async {
    await pump(tester);
    expect(
      find.text('Claude Code: 2 new MCP servers found in this project'),
      findsOneWidget,
    );
    expect(find.text('dart'), findsOneWidget);
    expect(find.text('marionette'), findsOneWidget);
    expect(find.text('Enable selected'), findsOneWidget);
    expect(find.text('Reject all'), findsOneWidget);
    expect(find.textContaining('Will enable dart, marionette'), findsOneWidget);
  });

  testWidgets('unticking a box submits the ticks chosen', (tester) async {
    final sent = await pump(tester);
    await tester.tap(find.text('marionette'));
    await tester.pump();
    expect(find.textContaining('Will enable dart.'), findsOneWidget);
    expect(sent.submitted, isEmpty, reason: 'a tick presses nothing');
    await tester.tap(find.byKey(const ValueKey('checklist-submit')));
    await tester.pumpAndSettle();
    expect(sent.submitted, [
      [true, false],
    ]);
  });

  testWidgets('Reject all rejects', (tester) async {
    final sent = await pump(tester);
    await tester.tap(find.byKey(const ValueKey('checklist-reject')));
    await tester.pumpAndSettle();
    expect(sent.rejected, ['rejected']);
    expect(sent.submitted, isEmpty);
  });

  testWidgets('an answer that did not land says so and offers the terminal', (
    tester,
  ) async {
    var opened = 0;
    await pump(
      tester,
      failWith: const GatewayException(
        'pressed Enter on "Enable selected", but the prompt is still on '
        'screen — check the terminal',
      ),
      onOpenTerminal: () => opened++,
    );
    await tester.tap(find.byKey(const ValueKey('checklist-submit')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('checklist-failure')), findsOneWidget);
    await tester.tap(find.text('Open the terminal'));
    expect(opened, 1);
  });

  testWidgets('fits a 360 px phone at text scale 1.6', (tester) async {
    await pump(tester, size: const Size(360, 800), textScale: 1.6);
    expect(tester.takeException(), isNull);
    expect(find.text('Reject all'), findsOneWidget);
  });
}
