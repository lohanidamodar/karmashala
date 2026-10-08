import 'package:agent_cli/stream.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/sessions/presentation/chat_transcript.dart';
import 'package:karmashala/src/features/sessions/presentation/tool_run.dart';
import 'package:karmashala/src/features/settings/domain/settings.dart';
import 'package:karmashala_ui/tokens.dart';

/// **The chat reads quieter**: tool calls are one line each with a status
/// dot, reads and searches in a row share a line, a failure stays in sight
/// with its first words, short narration is muted and a turn's final answer
/// is set apart.
void main() {
  ChatMessage tool(
    String name, {
    String? subject,
    String? output = 'done',
    bool isError = false,
    bool pending = false,
  }) => ChatMessage(
    role: 'tool',
    text: name,
    pending: pending,
    tool: ToolActivity(
      name: name,
      subject: subject,
      output: output,
      isError: isError,
    ),
  );
  ChatMessage said(String text) => ChatMessage(role: 'agent', text: text);
  const asked = ChatMessage(role: 'user', text: 'Fix the login test');

  group('grouping consecutive lookups', () {
    test('two or more reads and searches in a row share a line', () {
      final messages = [
        tool('Read', subject: 'a.dart'),
        tool('Grep', subject: 'redirect'),
        tool('Read', subject: 'b.dart'),
        tool('Bash', subject: 'flutter test'),
        tool('Read', subject: 'c.dart'),
        tool('Edit', subject: 'c.dart'),
        tool('Glob', subject: '**/*.dart'),
        tool('Read', subject: 'd.dart'),
      ];
      expect(toolCallLines(messages, 0, messages.length), [
        (0, 3),
        (3, 4),
        (4, 5),
        (5, 6),
        (6, 8),
      ]);
    });

    test('a failed, running or image read keeps a line of its own', () {
      final messages = [
        tool('Read', subject: 'a.dart'),
        tool('Read', subject: 'b.dart', isError: true),
        tool('Read', subject: 'c.dart'),
        tool('Read', subject: 'd.dart', output: null, pending: true),
      ];
      expect(toolCallLines(messages, 0, 4), [(0, 1), (1, 2), (2, 3), (3, 4)]);
    });

    test('a run that is all lookups gets a line each', () {
      final messages = [
        tool('Read', subject: 'a.dart'),
        tool('Grep', subject: 'x'),
      ];
      expect(toolCallLines(messages, 0, 2), [(0, 1), (1, 2)]);
    });
  });

  group('failures', () {
    test('a non-zero exit is a failure even when not flagged', () {
      expect(toolCallFailed(tool('Bash', output: 'Exit code 2\nboom')), isTrue);
      expect(toolCallFailed(tool('Bash', output: 'Exit code 0\nok')), isFalse);
      expect(toolCallFailed(tool('Bash', isError: true)), isTrue);
      expect(toolCallFailed(tool('Bash', output: 'all good')), isFalse);
    });

    test('the headline is the first line worth reading, with its exit', () {
      expect(
        toolErrorHeadline(
          const ToolActivity(
            name: 'Bash',
            output: 'Exit code 1\n\nExpected: "/home"\n  Actual: "/login"',
            isError: true,
          ),
        ),
        'exit 1 · Expected: "/home"',
      );
      expect(
        toolErrorHeadline(
          const ToolActivity(
            name: 'Read',
            output: 'File not found',
            isError: true,
          ),
        ),
        'File not found',
      );
      expect(
        toolErrorHeadline(
          const ToolActivity(name: 'Bash', output: 'Exit code 3'),
        ),
        'exit 3',
      );
      expect(toolErrorHeadline(const ToolActivity(name: 'Bash')), isNull);
      final long = toolErrorHeadline(
        ToolActivity(name: 'Bash', output: 'x' * 400, isError: true),
      )!;
      expect(long.length, kErrorHeadlineChars);
      expect(long.endsWith('…'), isTrue);
    });
  });

  group('narration and the final answer', () {
    test('short narration before a tool call is quiet; the last words of a '
        'finished turn of work are the answer', () {
      final messages = [
        asked,
        said('Let me look at the login flow.'),
        tool('Read'),
        said('Now I\'ll run the tests.'),
        tool('Bash'),
        said('Fixed. All tests pass.'),
      ];
      expect(agentProse(messages, lastTurnOver: true), {
        1: AgentProse.quiet,
        3: AgentProse.quiet,
        5: AgentProse.finalAnswer,
      });
    });

    test('narration that carries content keeps full strength', () {
      final long = said('${'The guard redirects too early. ' * 10}Next.');
      final listed = said('Two options:\n1. Await it\n2. Pump the test');
      final code = said('Run this:\n```\nflutter test\n```');
      final messages = [
        asked,
        long,
        tool('Read'),
        listed,
        tool('Read'),
        code,
        tool('Read'),
      ];
      expect(agentProse(messages, lastTurnOver: false), isEmpty);
      expect(isQuietNarration('Checking.\nAnd again.'), isTrue);
      expect(isQuietNarration('One.\nTwo.\nThree.'), isFalse);
      expect(isQuietNarration('# Plan'), isFalse);
    });

    test('no answer is marked while the turn runs, or in a turn of words '
        'alone', () {
      final working = [asked, tool('Read'), said('Still looking.')];
      expect(agentProse(working, lastTurnOver: false), isEmpty);
      expect(agentProse(working, lastTurnOver: true), {
        2: AgentProse.finalAnswer,
      });
      expect(agentProse([asked, said('Hello!')], lastTurnOver: true), isEmpty);
    });

    test('an earlier turn is over once the next one opens', () {
      final messages = [
        asked,
        tool('Read'),
        said('Done.'),
        const ChatMessage(role: 'user', text: 'And now?'),
        said('Looking.'),
        tool('Read'),
      ];
      expect(agentProse(messages, lastTurnOver: false), {
        2: AgentProse.finalAnswer,
        4: AgentProse.quiet,
      });
    });
  });

  group('the setting', () {
    test('is off by default and survives a round trip', () {
      expect(const Settings().chatSentencePerLine, isFalse);
      final on = const Settings().copyWith(chatSentencePerLine: true);
      expect(Settings.fromJson(on.toJson()).chatSentencePerLine, isTrue);
      expect(on == const Settings(), isFalse);
    });
  });

  group('on screen', () {
    final turn = [
      asked,
      said('Let me look at the login flow first.'),
      tool('Read', subject: 'lib/auth/login_page.dart'),
      tool('Read', subject: 'lib/auth/session_guard.dart'),
      tool('Grep', subject: 'redirectTo'),
      tool('Bash', subject: 'git status'),
      said('Now I\'ll run the failing test.'),
      tool(
        'Bash',
        subject: 'flutter test test/auth/login_test.dart',
        isError: true,
        output: 'Exit code 1\nExpected: "/home"\n  Actual: "/login"',
      ),
      tool('Edit', subject: 'lib/auth/session_guard.dart'),
      said(
        'Fixed. The guard now waits for the stored session. All 14 auth '
        'tests pass.',
      ),
    ];

    Widget view(
      List<ChatMessage> messages, {
      TranscriptTurn turn = TranscriptTurn.idle,
      bool sentencePerLine = false,
    }) => MaterialApp(
      home: Scaffold(
        body: ChatTranscriptView(
          messages: messages,
          turn: turn,
          sentencePerLine: sentencePerLine,
        ),
      ),
    );

    Finder shown(String text) => find.textContaining(text, findRichText: true);

    testWidgets('a settled run keeps its failure in sight, in the failure '
        'colour, with its first words', (tester) async {
      await tester.pumpWidget(view(turn));
      await tester.pumpAndSettle();

      final error = find.byKey(const ValueKey('chat-tool-error'));
      expect(error, findsOneWidget);
      expect(
        find.descendant(
          of: error,
          matching: shown('exit 1 · Expected: "/home"'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: error, matching: shown('flutter test')),
        findsOneWidget,
      );
      final context = tester.element(error);
      final failure = SemanticColors.of(context).failure;
      final headline = tester.widget<Text>(
        find.descendant(
          of: error,
          matching: find.text('exit 1 · Expected: "/home"'),
        ),
      );
      expect(headline.style?.color, failure);
      // The run's line counts it in the same colour.
      final line = tester.widget<RichText>(
        find.byWidgetPredicate(
          (w) => w is RichText && w.text.toPlainText().endsWith('· 1 failed'),
        ),
      );
      TextSpan? failedSpan;
      line.text.visitChildren((span) {
        if (span is TextSpan && span.text == ' · 1 failed') failedSpan = span;
        return true;
      });
      expect(failedSpan?.style?.color, failure);

      // A click opens the full card under it.
      await tester.tap(find.text('exit 1 · Expected: "/home"'));
      await tester.pumpAndSettle();
      expect(find.text('FAILED'), findsOneWidget);
    });

    testWidgets('opened, reads and searches in a row share one line', (
      tester,
    ) async {
      await tester.pumpWidget(view(turn));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Read 2 files', findRichText: true));
      await tester.pumpAndSettle();

      final group = find.byKey(const ValueKey('chat-tool-lookups'));
      expect(group, findsOneWidget);
      expect(
        find.descendant(
          of: group,
          matching: find.text('Read 2 files · ran 1 search'),
        ),
        findsOneWidget,
      );
      expect(shown('session_guard.dart'), findsNothing);
      await tester.tap(find.text('Read 2 files · ran 1 search'));
      await tester.pumpAndSettle();
      expect(shown('login_page.dart'), findsWidgets);
      expect(
        find.bySemanticsLabel(RegExp('^Read, lib/auth/login_page.dart, done')),
        findsOneWidget,
      );
    });

    testWidgets('narration is muted and the answer hangs off an accent rule', (
      tester,
    ) async {
      await tester.pumpWidget(view(turn));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('chat-narration-quiet')),
        findsNWidgets(2),
      );
      final answer = find.byKey(const ValueKey('chat-final-answer'));
      expect(answer, findsOneWidget);
      expect(
        find.descendant(of: answer, matching: shown('All 14 auth tests pass')),
        findsWidgets,
      );
      expect(find.bySemanticsLabel(RegExp('^Final answer')), findsOneWidget);
      final scheme = Theme.of(tester.element(answer)).colorScheme;
      final quiet = tester.widgetList<RichText>(
        find.descendant(
          of: find.byKey(const ValueKey('chat-narration-quiet')).first,
          matching: find.byType(RichText),
        ),
      );
      expect(
        quiet.any(
          (t) =>
              t.text.toPlainText().contains('Let me look') &&
              _colourOf(t.text, "Let me look") == scheme.onSurfaceVariant,
        ),
        isTrue,
      );

      // While the turn runs, nothing is the answer yet.
      await tester.pumpWidget(view(turn, turn: TranscriptTurn.working));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('chat-final-answer')), findsNothing);
    });

    testWidgets('one sentence per line breaks the answer at each sentence', (
      tester,
    ) async {
      await tester.pumpWidget(view(turn, sentencePerLine: true));
      await tester.pumpAndSettle();
      expect(
        shown('Fixed.\nThe guard now waits for the stored session.\nAll 14'),
        findsWidgets,
      );
      await tester.pumpWidget(view(turn));
      await tester.pumpAndSettle();
      expect(shown('Fixed. The guard now waits'), findsWidgets);
    });

    for (final width in [360.0, 1440.0]) {
      testWidgets('nothing overflows at $width px and text x1.6', (
        tester,
      ) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 900);
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MediaQuery(
            data: MediaQueryData(
              size: Size(width, 900),
              textScaler: const TextScaler.linear(1.6),
            ),
            child: view(turn),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tap(
          find.textContaining('Read 2 files', findRichText: true),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Read 2 files · ran 1 search'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }
  });
}

/// The colour the span holding [needle] is drawn in: the innermost one, as
/// `Text.rich` wraps the markdown's own span in the ambient style.
Color? _colourOf(InlineSpan span, String needle, [Color? inherited]) {
  if (span is! TextSpan) return null;
  final colour = span.style?.color ?? inherited;
  if (span.text?.contains(needle) ?? false) return colour;
  for (final child in span.children ?? const <InlineSpan>[]) {
    if (_colourOf(child, needle, colour) case final found?) return found;
  }
  return null;
}
