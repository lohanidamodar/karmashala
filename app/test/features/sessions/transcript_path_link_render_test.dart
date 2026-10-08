import 'package:agent_cli/stream.dart';
import 'package:karmashala/src/features/sessions/presentation/chat_transcript.dart';
import 'package:karmashala/src/features/sessions/presentation/tool_activity_row.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/tool_runs.dart';

/// What the reader actually sees: which tokens are underlined, and what a click
/// on one reports. The false-positive list is the point of the exercise — an
/// underlined `and/or` that does nothing on click makes the whole feature look
/// broken.
void main() {
  late List<String> tapped;

  setUp(() => tapped = []);

  /// Every span in the tree that carries a tap recognizer.
  ///
  /// Markdown already turns a bare URL into one of these on its own, so this
  /// counts *links*, not *path links* — [links] is the one that answers which
  /// tokens this feature claimed.
  List<TapGestureRecognizer> recognizers(WidgetTester tester) {
    final found = <TapGestureRecognizer>[];
    void collect(InlineSpan root) {
      root.visitChildren((span) {
        if (span is TextSpan && span.recognizer is TapGestureRecognizer) {
          found.add(span.recognizer! as TapGestureRecognizer);
        }
        return true;
      });
    }

    for (final widget in tester.widgetList<SelectableText>(
      find.byType(SelectableText),
    )) {
      if (widget.textSpan != null) collect(widget.textSpan!);
    }
    for (final widget in tester.widgetList<RichText>(find.byType(RichText))) {
      collect(widget.text);
    }
    return found;
  }

  /// What clicking every link in the tree reports back.
  ///
  /// The honest measure of "is this token a path link": a URL markdown
  /// autolinked is a link too, and clicking it must report nothing here.
  List<String> links(WidgetTester tester) {
    tapped.clear();
    for (final recognizer in recognizers(tester)) {
      recognizer.onTap?.call();
    }
    return tapped;
  }

  Future<void> pumpProse(
    WidgetTester tester,
    String text, {
    bool clickable = true,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatTranscriptView(
            messages: [ChatMessage(role: 'agent', text: text)],
            onPathTap: clickable ? tapped.add : null,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('prose', () {
    testWidgets('a file path becomes a link', (tester) async {
      await pumpProse(
        tester,
        'Built windows/installer/output/Karmashala-Setup-1.4.0.exe just now.',
      );

      expect(links(tester), [
        'windows/installer/output/Karmashala-Setup-1.4.0.exe',
      ]);
    });

    testWidgets('a link suffix travels with the token', (tester) async {
      await pumpProse(tester, 'Failing at lib/main.dart:12 today.');

      expect(links(tester), ['lib/main.dart:12']);
    });

    testWidgets('with nowhere to send it, nothing is a link', (tester) async {
      await pumpProse(tester, 'See lib/main.dart.', clickable: false);

      expect(links(tester), isEmpty);
    });

    testWidgets('a URL is left to markdown, and is never carved up', (
      tester,
    ) async {
      await pumpProse(
        tester,
        'Read https://example.com/docs/setup.html first.',
      );

      // Markdown autolinks it, as it always did — one link, and not ours.
      expect(recognizers(tester), hasLength(1));
      expect(links(tester), isEmpty);
    });

    testWidgets('a link the author wrote stays the link it is', (tester) async {
      await pumpProse(tester, 'See [lib/main.dart](https://example.com/x).');

      // One link, and it is the author's: the label is not linkified a second
      // time on top of it, so clicking it reports nothing to us.
      expect(recognizers(tester), hasLength(1));
      expect(links(tester), isEmpty);
    });

    testWidgets('a fenced code block is not touched', (tester) async {
      await pumpProse(tester, 'Run this:\n\n```sh\ncat lib/main.dart\n```\n');

      expect(links(tester), isEmpty);
    });

    // The owner (2026-10-08): a path an agent puts in backticks must open on
    // click, as it does in the terminal — agents nearly always quote paths.
    testWidgets('an inline code span that is a path is a link', (tester) async {
      await pumpProse(
        tester,
        r'Run `app\windows\installer\Output\Karmashala-Setup-1.34.2.exe` now.',
      );

      expect(links(tester), [
        r'app\windows\installer\Output\Karmashala-Setup-1.34.2.exe',
      ]);
    });

    testWidgets('a quoted path keeps its line suffix', (tester) async {
      await pumpProse(tester, 'Failing at `lib/main.dart:12` today.');

      expect(links(tester), ['lib/main.dart:12']);
    });

    testWidgets('a code span with more than a path in it is untouched', (
      tester,
    ) async {
      await pumpProse(tester, 'Run `cat lib/main.dart` and `a/b`.');

      expect(links(tester), isEmpty);
    });

    testWidgets('prose that merely holds a slash or a dot is prose', (
      tester,
    ) async {
      await pumpProse(
        tester,
        'Use and/or, n/a, 1/2, he/she/they — e.g. version 1.4.0 of Node.js.',
      );

      expect(links(tester), isEmpty);
    });
  });

  group('tool rows', () {
    Future<void> pumpTool(WidgetTester tester, String subject) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChatTranscriptView(
              messages: [
                ChatMessage(
                  role: 'tool',
                  text: 'Read($subject)',
                  tool: ToolActivity(name: 'Read', subject: subject),
                ),
              ],
              onPathTap: tapped.add,
            ),
          ),
        ),
      );
      await tester.pump();
      // A finished call is folded under its turn's line: open it to its card.
      await openToolRuns(tester);
    }

    testWidgets('the file a Read touched is a link', (tester) async {
      await pumpTool(tester, 'lib/src/features/sessions/session.dart');
      await tester.pumpAndSettle();

      expect(links(tester), ['lib/src/features/sessions/session.dart']);
    });

    testWidgets('a command with no path in it is unchanged', (tester) async {
      await pumpTool(tester, 'git status --short');
      await tester.pumpAndSettle();

      expect(links(tester), isEmpty);
      // In the card; the run's index line above it names the call too.
      expect(
        find.descendant(
          of: find.byType(ToolActivityBody),
          matching: find.text('git status --short'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('a path inside a command is clickable', (tester) async {
      await pumpTool(tester, 'cat /home/me/src/app/pubspec.yaml');
      await tester.pumpAndSettle();

      expect(links(tester), ['/home/me/src/app/pubspec.yaml']);
    });
  });
}
