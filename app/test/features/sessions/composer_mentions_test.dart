import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/sessions/presentation/message_composer.dart';
import 'package:karmashala_session/mentions.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_ui/tokens.dart';

/// A fixed list, filtered the way a host would: what "@" offers.
class _FakeMentions implements ComposerMentions {
  final asked = <String>[];

  static const _kinds = [
    ComposerMentionOption(
      kind: MentionKind.diff,
      label: '@diff',
      detail: 'Uncommitted changes',
      insert: '@diff',
    ),
    ComposerMentionOption(
      kind: MentionKind.terminal,
      label: '@terminal:…',
      detail: 'A terminal’s last lines',
      insert: '@terminal:',
      continues: true,
    ),
  ];
  static const _files = [
    ComposerMentionOption(
      kind: MentionKind.file,
      label: 'app/lib/main.dart',
      insert: '@app/lib/main.dart',
    ),
    ComposerMentionOption(
      kind: MentionKind.folder,
      label: 'app/lib/',
      detail: 'Folder',
      insert: '@app/lib/',
    ),
  ];

  @override
  Future<List<ComposerMentionOption>> options(String query) async {
    asked.add(query);
    if (query.startsWith('terminal:')) {
      return const [
        ComposerMentionOption(
          kind: MentionKind.terminal,
          label: 'Build server',
          insert: '@terminal:"Build server"',
        ),
      ];
    }
    return [
      for (final o in [..._kinds, ..._files])
        if (o.label.contains(query)) o,
    ];
  }

  @override
  Future<String> expand(String text) async => messageWithMentionContexts(text, [
    for (final m in findMentions(text))
      if (m.kind == MentionKind.terminal)
        MentionContext(
          token: text.substring(m.start, m.end),
          description: 'last 200 lines of ${m.argument}',
          body: 'npm run dev\nready on :3000',
          keepTail: true,
        ),
  ]);
}

void main() {
  final palette = find.byKey(const ValueKey('composer-mention-palette'));
  Finder row(String insert) => find.byKey(ValueKey('composer-mention-$insert'));

  late _FakeMentions mentions;
  late MentionTextController controller;

  Future<List<String>> pump(
    WidgetTester tester, {
    Size size = const Size(1440, 900),
    double textScale = 1.0,
    bool touch = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    mentions = _FakeMentions();
    controller = MentionTextController();
    addTearDown(controller.dispose);
    final sent = <String>[];
    final composer = MessageComposer(
      hintText: 'Message',
      controller: controller,
      mentions: mentions,
      onSend: (text) async => sent.add(text),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: (touch ? UiDensity.touch : UiDensity.pointer).themeFor(
          AppTheme.dark(),
        ),
        builder: (context, app) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: UiDensityScope(
            density: touch ? UiDensity.touch : UiDensity.pointer,
            child: app!,
          ),
        ),
        home: Scaffold(
          body: Column(
            children: [
              const Expanded(child: SizedBox()),
              composer,
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return sent;
  }

  Future<void> type(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField), text);
    await tester.pumpAndSettle();
  }

  testWidgets('"@" opens the list; typing narrows it; a space shuts it', (
    tester,
  ) async {
    await pump(tester);
    expect(palette, findsNothing);

    await type(tester, 'Look at @');
    expect(palette, findsOneWidget);
    expect(row('@diff'), findsOneWidget);
    expect(row('@app/lib/main.dart'), findsOneWidget);

    await type(tester, 'Look at @main');
    expect(row('@app/lib/main.dart'), findsOneWidget);
    expect(row('@diff'), findsNothing);
    expect(mentions.asked.last, 'main');

    await type(tester, 'Look at @main ');
    expect(palette, findsNothing);

    await type(tester, 'mail a@b');
    expect(palette, findsNothing);
  });

  testWidgets('arrows move, Enter picks; Tab picks; Esc shuts', (tester) async {
    final sent = await pump(tester);
    await type(tester, '@');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    // The kind continues: its own entries follow, nothing sent.
    expect(controller.text, '@terminal:');
    expect(row('@terminal:"Build server"'), findsOneWidget);
    expect(sent, isEmpty);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(controller.text, '@terminal:"Build server" ');
    expect(palette, findsNothing);

    await type(tester, 'x @');
    expect(palette, findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(palette, findsNothing);
    expect(controller.text, 'x @');
  });

  testWidgets('a tapped file goes in as its path, drawn as a chip, and one '
      'backspace takes the whole chip', (tester) async {
    await pump(tester);
    await type(tester, 'Fix @ma');
    await tester.tap(row('@app/lib/main.dart'));
    await tester.pumpAndSettle();
    expect(controller.text, 'Fix @app/lib/main.dart ');

    final span = controller.buildTextSpan(
      context: tester.element(find.byType(TextField)),
      withComposing: false,
    );
    final chip = span.children!.cast<TextSpan>().firstWhere(
      (s) => s.text == '@app/lib/main.dart',
    );
    expect(chip.style?.background, isNotNull);

    // Past the trailing space, then a backspace into the chip.
    controller.value = const TextEditingValue(
      text: 'Fix @app/lib/main.dart',
      selection: TextSelection.collapsed(offset: 22),
    );
    controller.value = const TextEditingValue(
      text: 'Fix @app/lib/main.dar',
      selection: TextSelection.collapsed(offset: 21),
    );
    expect(controller.text, 'Fix ');
    expect(controller.selection.baseOffset, 4);
  });

  testWidgets('sending puts what a terminal mention names after the words, '
      'fenced: what a terminal agent is typed and an ACP agent is sent', (
    tester,
  ) async {
    final sent = await pump(tester);
    await type(
      tester,
      'Why does @terminal:"Build server" fail in @app/lib/main.dart',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(sent, [
      'Why does @terminal:"Build server" fail in @app/lib/main.dart\n\n'
          '@terminal:"Build server" — last 200 lines of Build server:\n'
          '```text\nnpm run dev\nready on :3000\n```',
    ]);
    expect(controller.text, isEmpty);
  });

  testWidgets('a draft put back keeps its chips', (tester) async {
    await pump(tester);
    // What a parked draft or a queued message puts back: words alone.
    controller.value = const TextEditingValue(
      text: 'See @diff and @terminal:"Build server"',
      selection: TextSelection.collapsed(offset: 38),
    );
    await tester.pump();
    expect(controller.mentions.map((m) => m.kind), [
      MentionKind.diff,
      MentionKind.terminal,
    ]);
    final span = controller.buildTextSpan(
      context: tester.element(find.byType(TextField)),
      withComposing: false,
    );
    final chips = [
      for (final s in span.children!.cast<TextSpan>())
        if (s.style?.background != null) s.text,
    ];
    expect(chips, ['@diff', '@terminal:"Build server"']);
  });

  testWidgets('on touch, the "@" button opens the list as a sheet; a kind '
      'narrows it, an entry goes in at the caret', (tester) async {
    await pump(tester, size: const Size(390, 844), touch: true);
    await type(tester, 'Check');
    // On a phone's width "@" is one of the tools under "+".
    await tester.tap(find.byKey(const ValueKey('composer-tools')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('composer-tool-mention')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('composer-mention-search')), findsOne);

    await tester.tap(row('@terminal:'));
    await tester.pumpAndSettle();
    await tester.tap(row('@terminal:"Build server"'));
    await tester.pumpAndSettle();
    expect(controller.text, 'Check @terminal:"Build server" ');
  });

  for (final (name, size, scale, touch) in [
    ('360 px at text scale 1.6, touch', const Size(360, 740), 1.6, true),
    ('360 px at text scale 1.6, pointer', const Size(360, 740), 1.6, false),
    ('desktop', const Size(1440, 900), 1.0, false),
  ]) {
    testWidgets('no overflow with the list open: $name', (tester) async {
      await pump(tester, size: size, textScale: scale, touch: touch);
      await type(tester, 'A long line that wraps before the mention @');
      expect(palette, findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
