import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/quick_open/quick_open.dart';
import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/cli_detection/data/conversation_index_dao.dart';
import 'package:karmashala/src/features/cli_detection/data/imported_session_dao.dart';
import 'package:agent_cli/read.dart';
import 'package:karmashala/src/features/environments/application/local_environment_bootstrap.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/features/projects/application/projects_controller.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/git/application/changes_providers.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala_session/session.dart';
import 'package:sqlite3/sqlite3.dart' hide Session;

import '../../../features/terminal/fake_instance.dart';
import '../../../support/fakes.dart';
import '../../../support/fixtures.dart';

/// An [AppDatabase] that records every statement, so a keystroke can be priced.
class _CountingDatabase extends AppDatabase {
  _CountingDatabase() : super(sqlite3.openInMemory());

  final List<String> statements = [];

  int get searches =>
      statements.where((sql) => sql.contains('conversation_turns_fts')).length;

  @override
  List<Map<String, Object?>> query(
    String sql, [
    List<Object?> params = const [],
  ]) {
    statements.add(sql);
    return super.query(sql, params);
  }

  @override
  void execute(String sql, [List<Object?> params = const []]) {
    statements.add(sql);
    super.execute(sql, params);
  }
}

/// **Search across every conversation, through the palette.**
///
/// The requirement these hold is not "an FTS5 query returns rows" — that is the
/// DAO's own file — but that the palette lists a conversation for something
/// *said* in it, opens it, and **never filters a result on whether anything on
/// disk still resolves**. That last one is the stated requirement and §20's
/// rule: a stored path is state, whether it resolves is a measurement.
void main() {
  late _CountingDatabase db;
  late ConversationIndexDao index;

  final indexedAt = DateTime.now().toUtc().subtract(const Duration(hours: 2));

  setUp(() {
    db = _CountingDatabase();
    index = ConversationIndexDao(db);
    ensureLocalEnvironment(ExecutionEnvironmentDao(db), FixedClock(testTime));
    ProjectDao(db).insert(project(name: 'Karmashala'));
    RepositoryDao(db).insert(repository(name: 'app'));
    AgentInstallationDao(db).insert(
      agentInstallation(agentId: AgentIds.claudeCode),
    );
  });
  tearDown(() => db.close());

  void nativeSession({
    String id = 's1',
    String title = 'The worktree loop',
    String conversation = 'conv-1',
    EnvironmentPath? worktree,
  }) => SessionDao(db).insert(
    Session(
      id: id,
      repositoryId: 'r1',
      agentInstallationId: 'a1',
      title: title,
      useWorktree: worktree != null,
      worktree: worktree,
      status: SessionStatus.running,
      createdAt: testTime,
      externalSessionId: conversation,
    ),
  );

  void importedSession({
    String id = 'i1',
    String conversation = 'conv-2',
    String title = 'Old history',
  }) => ImportedSessionDao(db).insertIfAbsent(
    ImportedSession(
      id: id,
      repositoryId: 'r1',
      cli: AgentIds.claudeCode,
      externalId: conversation,
      environmentId: 'windows',
      filePath: r'C:\store\gone.jsonl',
      storeHome: r'C:\store',
      isSubagent: false,
      preview: 'preview',
      title: title,
      createdAt: testTime,
    ),
  );

  void said(String conversation, String text, {int ordinal = 0}) =>
      index.replaceTurns(
        sessionId: conversation,
        cli: AgentIds.claudeCode,
        filePath: r'C:\store\$conversation.jsonl',
        turns: [
          ConversationTurn(ordinal: ordinal, role: 'user', text: text),
        ],
        indexedAt: indexedAt,
      );

  Future<ProviderContainer> open(WidgetTester tester) async {
    final container = ProviderContainer(
      overrides: [...fakeTerminalOverrides(database: db)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => QuickOpen.show(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    container.read(selectedProjectIdProvider.notifier).select('p1');
    container.read(selectedRepositoryIdProvider.notifier).select('r1');
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return container;
  }

  Future<void> type(WidgetTester tester, String query) async {
    await tester.enterText(find.byType(TextField), query);
    await tester.pumpAndSettle();
  }

  testWidgets('a phrase said in a conversation finds the conversation', (
    tester,
  ) async {
    nativeSession();
    said('conv-1', 'we decided to copy the gitignored paths in');
    await open(tester);

    await type(tester, 'gitignored');

    expect(find.text('CONVERSATIONS'), findsOneWidget);
    expect(find.text('The worktree loop'), findsOneWidget);
    expect(find.textContaining('gitignored'), findsWidgets);
  });

  testWidgets('the row says how old the reading is', (tester) async {
    nativeSession();
    said('conv-1', 'the heap doubled over five hours');
    await open(tester);

    await type(tester, 'heap');

    // §19: the index is only as current as the trigger that last read that
    // transcript, and the row admits it rather than implying the answer is
    // live.
    expect(find.textContaining('indexed 2h ago'), findsOneWidget);
  });

  testWidgets('Enter opens the conversation it found', (tester) async {
    nativeSession();
    said('conv-1', 'a phrase nothing else in the palette contains');
    final container = await open(tester);

    await type(tester, 'nothing else in the palette');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(container.read(selectedSessionIdProvider), 's1');
  });

  testWidgets('a conversation whose worktree is gone is still a result', (
    tester,
  ) async {
    nativeSession(
      worktree: const EnvironmentPath(
        environmentId: 'windows',
        path: r'C:\nowhere\a-worktree-that-was-removed',
      ),
    );
    said('conv-1', 'the decision made in the worktree that is gone');
    final container = await open(tester);

    await type(tester, 'the decision made in');

    // Not filtered, not greyed out, not missing. Opening it goes through the
    // same path a clicked session row uses, which selects first and only then
    // tries to resume — so it lands on screen read-only rather than
    // disappearing from the answer.
    expect(find.text('CONVERSATIONS'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(container.read(selectedSessionIdProvider), 's1');
  });

  testWidgets('read-only history is a result too, and opens as history', (
    tester,
  ) async {
    importedSession();
    said('conv-2', 'the answer is in the imported record');
    final container = await open(tester);

    await type(tester, 'imported record');

    expect(find.text('Old history'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(container.read(selectedImportedSessionIdProvider), 'i1');
  });

  testWidgets('a conversation no row names any more is not offered', (
    tester,
  ) async {
    // The index keeps rows for a session the user has since deleted. There is
    // nothing left to open, so the hit is dropped rather than drawn as a row
    // that does nothing.
    said('conv-orphan', 'said in a session that no longer exists');
    await open(tester);

    await type(tester, 'no longer exists');

    expect(find.text('CONVERSATIONS'), findsNothing);
  });

  testWidgets('the ? sigil searches conversations and nothing else', (
    tester,
  ) async {
    nativeSession(title: 'Fix login redirect');
    said('conv-1', 'the redirect was the session cookie');
    await open(tester);

    await type(tester, '?redirect');

    expect(find.text('CONVERSATIONS'), findsOneWidget);
    expect(find.text('SESSIONS'), findsNothing);
  });

  testWidgets('one search per query, and none the query cannot need', (
    tester,
  ) async {
    nativeSession();
    said('conv-1', 'the caching decision');
    await open(tester);
    db.statements.clear();

    // A single character is not a search: it prefix-matches most of the store.
    await type(tester, 'c');
    expect(db.searches, 0);

    await type(tester, 'caching');
    expect(db.searches, 1);

    // Adding the group's own sigil narrows the *list*; the query behind it has
    // not changed, so nothing is asked again.
    await type(tester, '?caching');
    expect(db.searches, 1);

    // And a sigil for another group means this group is not being asked at
    // all.
    await type(tester, '>caching');
    expect(db.searches, 1);
    expect(find.text('CONVERSATIONS'), findsNothing);
  });
}
