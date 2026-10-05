import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/sessions/presentation/chat_transcript.dart';
import 'package:karmashala_ui/theme.dart';

const _envelope = '''<task-notification>
<task-id>aa4c10225ea0eed37</task-id>
<output-file>tasks/aa4c10225ea0eed37.output</output-file>
<status>completed</status>
<summary>Agent "Sleep 90 then report" finished</summary>
<result>first done</result>
</task-notification>''';

/// A background run's completion arrives in the parent transcript as a user
/// row nobody typed: it is drawn as a note naming the run, not as a bubble.
void main() {
  testWidgets('a task notification is a note, not an empty bubble', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: ChatTranscriptView(
            messages: const [
              ChatMessage(role: 'agent', text: 'Both are running.'),
              ChatMessage(role: 'user', text: _envelope),
              ChatMessage(role: 'agent', text: 'The first is done.'),
            ],
            onSaveNote: (_, _) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Agent "Sleep 90 then report" finished'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) => widget.runtimeType.toString() == '_UserMessageCard',
      ),
      findsNothing,
    );
  });
}
