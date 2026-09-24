import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/sessions/application/quit_resume.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/settings/domain/settings.dart';
import 'package:karmashala/src/features/sessions/presentation/quit_sessions_dialog.dart';
import 'package:karmashala_ui/theme.dart';

/// The question itself. What matters is that it names what would stop and
/// promises no more than the app can do.
void main() {
  InterruptedSession interrupted({
    String id = 's1',
    String title = 'Port the importer',
    bool working = true,
    bool keepsRunning = false,
  }) => InterruptedSession(
    id: id,
    title: title,
    agentName: 'Claude Code',
    working: working,
    keepsRunning: keepsRunning,
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
    await tester.tap(find.text('Open these again next time'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Quit'));
    await tester.pumpAndSettle();
    expect(answer?.quit, isTrue);
    expect(answer?.reopen, isFalse);
  });

  testWidgets('a host session is said to keep running, and can be ended', (
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
                    sessions: [interrupted(keepsRunning: true)],
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
    expect(
      find.textContaining('keep running after Karmashala quits'),
      findsOne,
    );
    expect(find.textContaining('mid-turn. Quitting stops'), findsNothing);

    await tester.tap(find.text('Keep host sessions running'));
    await tester.pumpAndSettle();
    expect(find.textContaining('mid-turn. Quitting stops'), findsOne);

    await tester.tap(find.text("Don't ask again"));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Quit'));
    await tester.pumpAndSettle();
    expect(answer?.keepHosted, isFalse);
    expect(answer?.remember, isTrue);
  });

  group('the quit guard', () {
    Future<({bool quit, int asked, List<String> ended})> quit(
      WidgetTester tester, {
      required Settings settings,
      required List<InterruptedSession> sessions,
      QuitChoice? answer,
    }) async {
      final service = _FakeQuitResume(sessions);
      var asked = 0;
      bool? result;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            quitResumeServiceProvider.overrideWith((ref) => service..ref = ref),
            settingsControllerProvider.overrideWith(
              () => _StaticSettings(settings),
            ),
          ],
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, _) => TextButton(
                onPressed: () async =>
                    result = await confirmQuitWithRunningSessions(
                      context,
                      ref,
                      ask: (_) async {
                        asked++;
                        return answer;
                      },
                    ),
                child: const Text('quit'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('quit'));
      await tester.pumpAndSettle();
      return (quit: result!, asked: asked, ended: service.ended);
    }

    testWidgets('asking off: quits on the saved answers, unasked', (
      tester,
    ) async {
      final outcome = await quit(
        tester,
        settings: const Settings(quitAsks: false),
        sessions: [interrupted(working: false)],
      );
      expect(outcome.quit, isTrue);
      expect(outcome.asked, 0);
    });

    testWidgets('asking off still asks when a turn would stop midway', (
      tester,
    ) async {
      final outcome = await quit(
        tester,
        settings: const Settings(quitAsks: false),
        sessions: [interrupted(working: true)],
        answer: (quit: true, reopen: true, keepHosted: true, remember: false),
      );
      expect(outcome.asked, 1);
    });

    testWidgets('a mid-turn host session that is kept does not ask', (
      tester,
    ) async {
      final outcome = await quit(
        tester,
        settings: const Settings(quitAsks: false),
        sessions: [interrupted(working: true, keepsRunning: true)],
      );
      expect(outcome.asked, 0);
      expect(outcome.ended, isEmpty);
    });

    testWidgets('choosing not to keep them ends the host sessions', (
      tester,
    ) async {
      final outcome = await quit(
        tester,
        settings: const Settings(),
        sessions: [
          interrupted(id: 'h1', keepsRunning: true),
          interrupted(id: 'p1'),
        ],
        answer: (quit: true, reopen: false, keepHosted: false, remember: false),
      );
      expect(outcome.quit, isTrue);
      expect(outcome.ended, ['h1']);
    });
  });
}

class _StaticSettings extends SettingsController {
  _StaticSettings(this._settings);
  final Settings _settings;

  @override
  Settings build() => _settings;

  @override
  void setQuitAnswers({
    required bool asks,
    required bool reopens,
    required bool keepsHostSessions,
  }) {}
}

class _FakeQuitResume implements QuitResumeService {
  _FakeQuitResume(this._sessions);

  final List<InterruptedSession> _sessions;
  final ended = <String>[];
  late Ref ref;

  @override
  List<InterruptedSession> interrupted() => _sessions;

  @override
  Future<void> endHosted(Iterable<String> sessionIds) async =>
      ended.addAll(sessionIds);

  @override
  bool remember(List<String> sessionIds) => true;

  @override
  void forget() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
