import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/sessions/application/quit_resume.dart';
import 'package:karmashala/src/features/sessions/presentation/quit_sessions_dialog.dart';
import 'package:karmashala_ui/theme.dart';

/// The question itself. What matters is that it names what would stop and
/// promises no more than the app can do.
void main() {
  InterruptedSession interrupted({
    String id = 's1',
    String title = 'Port the importer',
    bool working = true,
  }) => InterruptedSession(
    id: id,
    title: title,
    agentName: 'Claude Code',
    working: working,
  );

  Future<QuitChoice?> show(
    WidgetTester tester,
    List<InterruptedSession> sessions,
  ) async {
    QuitChoice? answer;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () async => answer = await QuitSessionsDialog.ask(
                    context,
                    sessions: sessions,
                  ),
                  child: const Text('go'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    return answer;
  }

  testWidgets('names every session, not just how many', (tester) async {
    await show(tester, [
      interrupted(title: 'Port the importer'),
      interrupted(id: 's2', title: 'Tidy the tests', working: false),
    ]);
    expect(find.text('2 sessions are still running'), findsOneWidget);
    expect(
      find.text('Port the importer — Claude Code, mid-turn'),
      findsOneWidget,
    );
    expect(find.text('Tidy the tests — Claude Code'), findsOneWidget);
  });

  testWidgets('says what quitting costs when something is mid-turn', (
    tester,
  ) async {
    await show(tester, [interrupted()]);
    expect(find.textContaining('stops the agent where it is'), findsOneWidget);
    // And the reassurance that is actually true.
    expect(
      find.textContaining('already written to disk stays'),
      findsOneWidget,
    );
  });

  testWidgets('with nothing mid-turn it does not imply work is lost', (
    tester,
  ) async {
    await show(tester, [interrupted(working: false)]);
    expect(find.text('A session is still running'), findsOneWidget);
    expect(find.textContaining('nothing in progress is lost'), findsOneWidget);
  });

  testWidgets('promises to reopen, and explicitly not to resume the turn', (
    tester,
  ) async {
    await show(tester, [interrupted()]);
    expect(find.text('Open these again next time'), findsOneWidget);
    expect(find.textContaining('does not send anything'), findsOneWidget);
    expect(
      find.textContaining('does not resume the turn that stops here'),
      findsOneWidget,
    );
  });

  testWidgets('Cancel holds the quit, and keeps the box\'s answer', (
    tester,
  ) async {
    QuitChoice? answer;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () async => answer = await QuitSessionsDialog.ask(
                    context,
                    sessions: [interrupted()],
                  ),
                  child: const Text('go'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(answer?.quit, isFalse);
  });

  testWidgets('Quit with the box ticked asks for them back', (tester) async {
    QuitChoice? answer;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () async => answer = await QuitSessionsDialog.ask(
                    context,
                    sessions: [interrupted()],
                  ),
                  child: const Text('go'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Quit'));
    await tester.pumpAndSettle();
    expect(answer?.quit, isTrue);
    expect(answer?.reopen, isTrue);

    // And unticking it is honoured.
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Quit'));
    await tester.pumpAndSettle();
    expect(answer?.quit, isTrue);
    expect(answer?.reopen, isFalse);
  });
}
