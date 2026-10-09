import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/quick_open/quick_open.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/features/projects/application/projects_controller.dart';
import 'package:karmashala/src/features/git/application/changes_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:karmashala_session/session.dart';

import '../../../features/terminal/fake_instance.dart';
import '../../../support/fakes.dart';
import '../../../support/fixtures.dart';
import '../../../support/fake_data_server.dart';
import 'package:flutter_riverpod/misc.dart' show Override;

/// **Search across every conversation, through the palette.**
///
/// The requirement these hold is not "an FTS5 query returns rows" — that is the
/// server's (`packages/karmashala_conversations`, `server/test/data`), asked
/// here of the fake server — but that the palette lists a conversation for something
/// *said* in it, opens it, and **never filters a result on whether anything on
/// disk still resolves**. That last one is the stated requirement and §20's
/// rule: a stored path is state, whether it resolves is a measurement.
void main() {
  late FakeDataServer server;
  late Override data;

  final indexedAt = DateTime.now().toUtc().subtract(const Duration(hours: 2));

  setUp(() async {
    server = FakeDataServer();
    data = await server.override();
    server.environmentRows.upsert(
      localHostEnvironment(FixedClock(testTime).nowUtc()),
    );
    server.projectRows.insert(project(name: 'Karmashala'));
    server.repositoryRows.insert(repository(name: 'app'));
    server.installationRows.insert(
      agentInstallation(agentId: AgentIds.claudeCode),
    );
  });

  void nativeSession({
    String id = 's1',
    String title = 'The worktree loop',
    String conversation = 'conv-1',
    EnvironmentPath? worktree,
    DateTime? archivedAt,
  }) => server.sessionRows.insert(
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
      archivedAt: archivedAt,
    ),
  );

  void importedSession({
    String id = 'i1',
    String conversation = 'conv-2',
    String title = 'Old history',
  }) => server.importedRows.insertIfAbsent(
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

  void said(String conversation, String text) =>
      server.conversations.say(conversation, text, indexedAt: indexedAt);

  Future<ProviderContainer> open(WidgetTester tester) async {
    final container = ProviderContainer(
      overrides: [data, ...fakeTerminalOverrides()],
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

  testWidgets('an archived session is still found by what was said, badged '
      'archived', (tester) async {
    nativeSession(archivedAt: testTime);
    said('conv-1', 'the cache key was the culprit');
    final container = await open(tester);

    await type(tester, 'cache key');

    expect(find.text('The worktree loop'), findsOneWidget);
    expect(find.textContaining('archived  ·'), findsOneWidget);
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

  testWidgets('conversations are listed in the order the search ranked them', (
    tester,
  ) async {
    nativeSession(id: 's1', title: 'Aardvark ramble', conversation: 'conv-1');
    nativeSession(id: 's2', title: 'Zebra retries', conversation: 'conv-2');
    // The fake server ranks in the order said: conv-2 is its best answer.
    said('conv-2', 'webhook webhook: the webhook retries');
    said(
      'conv-1',
      'a long ramble that touches the webhook once among many other words '
          'about deployment, caching and the release train',
    );
    await open(tester);

    await type(tester, '?webhook');

    // The titles run the other way alphabetically, and the palette breaks a
    // tie on the title — so only the server's rank can put this one first.
    final strong = tester.getTopLeft(find.text('Zebra retries')).dy;
    final weak = tester.getTopLeft(find.text('Aardvark ramble')).dy;
    expect(strong, lessThan(weak));
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
    final searches = server.conversations.searches;
    searches.clear();

    // A single character is not a search: it prefix-matches most of the store.
    await type(tester, 'c');
    expect(searches, isEmpty);

    // One request for the query as typed.
    await type(tester, 'caching');
    expect(searches.map((s) => s.query), ['caching']);

    // Adding the group's own sigil narrows the *list*; the query behind it has
    // not changed, so nothing is asked again.
    await type(tester, '?caching');
    expect(searches, hasLength(1));

    // And a sigil for another group means this group is not being asked at
    // all.
    await type(tester, '>caching');
    expect(searches, hasLength(1));
    expect(find.text('CONVERSATIONS'), findsNothing);
  });

  testWidgets('opening asks the server to catch up, and searches again when '
      'that found something', (tester) async {
    nativeSession();
    server.conversations
      ..catchUpChanges = 1
      ..onCatchUp = () => said('conv-1', 'written while the palette opened');
    // Held, so the query is typed before the catch-up answers.
    final hold = server.hold = Completer<void>();
    final container = ProviderContainer(
      overrides: [data, ...fakeTerminalOverrides()],
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
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'palette opened');
    await tester.pump();
    expect(find.text('CONVERSATIONS'), findsNothing);

    server.hold = null;
    hold.complete();
    await tester.pumpAndSettle();

    expect(server.conversations.catchUps, 1);
    expect(find.text('CONVERSATIONS'), findsOneWidget);
    expect(find.text('The worktree loop'), findsOneWidget);
  });

  group('coverage', () {
    const note = ValueKey('quickOpen.conversationCoverage');

    testWidgets('what the index has not read is said beside the results', (
      tester,
    ) async {
      nativeSession();
      said('conv-1', 'the heap doubled');
      server.conversations.coverage = (
        named: 12,
        unindexed: 3,
        unreadable: 1,
        backfilling: false,
      );
      await open(tester);

      await type(tester, 'heap');

      expect(
        tester.widget<Text>(find.byKey(note)).data,
        '· 3 of 12 conversations not indexed · '
        '1 could not be read, may be out of date',
      );
    });

    testWidgets('an empty search with gaps says so too', (tester) async {
      server.conversations.coverage = (
        named: 4,
        unindexed: 4,
        unreadable: 0,
        backfilling: true,
      );
      await open(tester);

      await type(tester, 'nothing said this');

      expect(
        tester.widget<Text>(find.byKey(note)).data,
        '· reading history · 4 of 4 conversations not indexed',
      );
    });

    testWidgets('a server that does not count coverage says nothing', (
      tester,
    ) async {
      nativeSession();
      said('conv-1', 'the heap doubled');
      await open(tester);
      await type(tester, 'heap');
      expect(find.text('The worktree loop'), findsOneWidget);
      expect(find.byKey(note), findsNothing);
    });

    testWidgets('no gap says nothing', (tester) async {
      nativeSession();
      said('conv-1', 'the heap doubled');
      server.conversations.coverage = (
        named: 1,
        unindexed: 0,
        unreadable: 0,
        backfilling: false,
      );
      await open(tester);
      await type(tester, 'heap');
      expect(find.text('The worktree loop'), findsOneWidget);
      expect(find.byKey(note), findsNothing);
    });

    testWidgets('fits a phone at text scale 1.6', (tester) async {
      tester.view
        ..physicalSize = const Size(360, 740)
        ..devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 1.6;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      nativeSession();
      said('conv-1', 'the heap doubled');
      server.conversations.coverage = (
        named: 1200,
        unindexed: 300,
        unreadable: 12,
        backfilling: true,
      );
      await open(tester);

      await type(tester, 'heap');

      expect(find.byKey(note), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
