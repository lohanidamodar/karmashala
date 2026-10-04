import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/sessions/application/session_commands_providers.dart';
import 'package:karmashala/src/features/sessions/presentation/message_composer.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_ui/theme.dart';

import '../../support/fake_data_server.dart';
import '../../support/test_machine.dart';

/// **The agent's slash commands in the composer**: "/" lists them with the
/// agent's words, typing narrows them, and picking one — by tap or by key —
/// puts it in the box unsent.
void main() {
  const commands = [
    ComposerCommand(
      name: 'review',
      description: 'Review the changes',
      hint: 'what to focus on',
    ),
    ComposerCommand(name: 'compact', description: 'Compact the context'),
    ComposerCommand(name: 'init', description: 'Write an AGENTS.md'),
  ];

  final palette = find.byKey(const ValueKey('composer-command-palette'));

  Future<List<String>> pump(
    WidgetTester tester, {
    Size size = const Size(1440, 900),
    List<ComposerCommand>? offered = commands,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final sent = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: Column(
            children: [
              const Expanded(child: SizedBox()),
              MessageComposer(
                hintText: 'Message',
                commands: offered == null ? null : () => offered,
                onSend: (text) async => sent.add(text),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return sent;
  }

  TextField field(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField));

  testWidgets('"/" lists every command with its description and hint', (
    tester,
  ) async {
    await pump(tester);
    expect(palette, findsNothing);

    await tester.enterText(find.byType(TextField), '/');
    await tester.pump();

    expect(palette, findsOneWidget);
    expect(find.text('/review'), findsOneWidget);
    expect(find.text('what to focus on'), findsOneWidget);
    expect(find.text('Review the changes'), findsOneWidget);
    expect(find.text('/compact'), findsOneWidget);
    expect(find.text('/init'), findsOneWidget);
  });

  testWidgets('typing narrows the list; a space or plain text shuts it', (
    tester,
  ) async {
    await pump(tester);
    await tester.enterText(find.byType(TextField), '/co');
    await tester.pump();
    expect(find.text('/compact'), findsOneWidget);
    expect(find.text('/review'), findsNothing);

    await tester.enterText(find.byType(TextField), '/compact now');
    await tester.pump();
    expect(palette, findsNothing);

    await tester.enterText(find.byType(TextField), 'hello /');
    await tester.pump();
    expect(palette, findsNothing);
  });

  testWidgets('a tap puts the command in the box and sends nothing', (
    tester,
  ) async {
    final sent = await pump(tester);
    await tester.enterText(find.byType(TextField), '/');
    await tester.pump();

    await tester.tap(find.text('/review'));
    await tester.pump();

    expect(field(tester).controller!.text, '/review ');
    expect(palette, findsNothing);
    expect(sent, isEmpty);
  });

  testWidgets('Down then Enter picks; the next Enter sends it', (
    tester,
  ) async {
    final sent = await pump(tester);
    await tester.tap(find.byType(TextField));
    await tester.enterText(find.byType(TextField), '/');
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(field(tester).controller!.text, '/compact ');
    expect(sent, isEmpty, reason: 'Enter picked, it did not send');

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(sent, ['/compact']);
  });

  testWidgets('Esc shuts the palette until the box starts over', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.byType(TextField));
    await tester.enterText(find.byType(TextField), '/');
    await tester.pump();
    expect(palette, findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(palette, findsNothing);
    await tester.enterText(find.byType(TextField), '/r');
    await tester.pump();
    expect(palette, findsNothing);

    await tester.enterText(find.byType(TextField), '');
    await tester.pump();
    await tester.enterText(find.byType(TextField), '/');
    await tester.pump();
    expect(palette, findsOneWidget);
  });

  testWidgets('no commands, no palette', (tester) async {
    await pump(tester, offered: null);
    await tester.enterText(find.byType(TextField), '/');
    await tester.pump();
    expect(palette, findsNothing);
  });

  testWidgets('a phone draws the palette without overflowing', (tester) async {
    await pump(tester, size: const Size(390, 844));
    await tester.enterText(find.byType(TextField), '/');
    await tester.pump();
    expect(palette, findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('the provider follows what the server tells of a session', () async {
    final machine = TestMachine();
    final server = FakeDataServer()..runsOn(machine);
    final container = ProviderContainer(overrides: [await server.override()]);
    addTearDown(container.dispose);
    final read = container.listen(sessionCommandsProvider('s1'), (_, _) {});
    expect(read.read(), isEmpty);

    server.writeAsAnotherClient([
      const SessionCommandsChanged(
        sessionId: 's1',
        commands: [SessionCommand(name: 'compact', description: 'Compact')],
      ),
      const SessionCommandsChanged(sessionId: 's2', commands: []),
    ]);
    await Future<void>.delayed(Duration.zero);
    expect(read.read().single.name, 'compact');
  });
}
