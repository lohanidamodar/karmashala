import 'dart:io';

import 'package:agent_cli/src/agents/data/antigravity_store_reader.dart';
import 'package:test/test.dart';
import 'package:path/path.dart' as p;
import '../support/fake_sqlite.dart';

/// What the Antigravity CLI store actually gives up.
///
/// the design noterecorded the store as "permanently
/// unreadable" after reading one file in it. These fixtures are built from the
/// real schemas on a live 1.1.22 installation, and they are the standard of
/// evidence the descriptor's other claims are held to: every table, column and
/// file name below was copied off the owner's own store rather than guessed.
void main() {
  late Directory tmp;
  late String storeHome;
  late FakeSqliteFiles sqlite;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('karmashala_agy_');
    storeHome = p.join(tmp.path, '.gemini', 'antigravity-cli');
    sqlite = FakeSqliteFiles();
  });
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows keeps a handle on a database a failing test left open; the
      // temp directory is the OS's problem, not this suite's.
    }
  });

  void writeFile(String relative, String contents) {
    File(p.join(storeHome, relative))
      ..createSync(recursive: true)
      ..writeAsStringSync(contents);
  }

  /// A conversation file with the real `steps` schema, as rows rather than as
  /// a database — see [FakeSqliteFiles].
  void writeConversation(String id, {int steps = 0}) {
    sqlite.put(
      p.join(storeHome, 'conversations', '$id.db'),
      'steps',
      [for (var i = 0; i < steps; i++) {'idx': i, 'step_type': 15}],
    );
  }

  void writeSummaries(List<(String id, String preview, int steps)> rows) {
    sqlite.put(
      p.join(storeHome, 'conversation_summaries.db'),
      'conversation_summaries',
      [
        for (final (id, preview, steps) in rows)
          {
            'conversation_id': id,
            'title': '',
            'preview': preview,
            'step_count': steps,
            'workspace_uris': '',
          },
      ],
    );
  }

  AntigravityStoreReader reader() =>
      AntigravityStoreReader(readRows: sqlite.read);

  group('the conversation id', () {
    test('is the conversation file name', () async {
      writeConversation('df3c0708-a27f-4799-b761-57a657a84274');

      final conversations = await reader().read(storeHome);

      expect(conversations.single.id, 'df3c0708-a27f-4799-b761-57a657a84274');
    });

    test('a store with no conversations directory reads as empty', () async {
      expect(await reader().read(storeHome), isEmpty);
    });

    test('non-conversation files in the directory are ignored', () async {
      writeConversation('real-one');
      writeFile('conversations/notes.txt', 'not a conversation');
      writeFile('conversations/.db', 'no id at all');

      final conversations = await reader().read(storeHome);

      expect(conversations.map((c) => c.id), ['real-one']);
    });
  });

  group('the working directory', () {
    // This is the file `agy -c` reads, so it is both how a conversation is
    // attributed to a directory and the definition of what `--continue` means.
    test('comes from cache/last_conversations.json', () async {
      writeConversation('conv-a');
      writeFile('cache/last_conversations.json', '''
{
  "/mnt/c/Users/dlohani/projects/popupbits": "conv-a"
}
''');

      final conversations = await reader().read(storeHome);

      expect(
        conversations.single.workspace,
        '/mnt/c/Users/dlohani/projects/popupbits',
      );
    });

    test('is null for a conversation the file no longer names', () async {
      // The CLI keeps one entry per directory, so a second conversation in the
      // same directory overwrites the first's only record of where it ran.
      writeConversation('older');
      writeConversation('newer');
      writeFile('cache/last_conversations.json', '{"/work": "newer"}');

      final conversations = await reader().read(storeHome);

      expect(
        {for (final c in conversations) c.id: c.workspace},
        {'older': null, 'newer': '/work'},
      );
    });

    test('is null when two directories claim one conversation', () async {
      // Rather than picking one of them: a wrong directory is worse than none,
      // because a directory is what attributes a session to a project.
      writeConversation('shared');
      writeFile(
        'cache/last_conversations.json',
        '{"/one": "shared", "/two": "shared"}',
      );

      expect((await reader().read(storeHome)).single.workspace, isNull);
    });

    test('a malformed cache file is read as no directories at all', () async {
      writeConversation('conv-a');
      writeFile('cache/last_conversations.json', '{ this is not json');

      expect((await reader().read(storeHome)).single.workspace, isNull);
      expect(await reader().readLastConversations(storeHome), isEmpty);
    });

    test('history.jsonl supplements workspaces for older conversations', () async {
      writeConversation('older');
      writeConversation('newer');
      writeFile('cache/last_conversations.json', '{"/work/newer": "newer"}');
      writeFile(
        'history.jsonl',
        '{"display":"hi","workspace":"/work/older","conversationId":"older"}\n'
        '{"display":"hello","workspace":"/work/newer","conversationId":"newer"}\n',
      );

      final workspaces = await reader().readWorkspacesByConversation(storeHome);
      expect(workspaces['older'], '/work/older');
      expect(workspaces['newer'], '/work/newer');

      final convs = await reader().read(storeHome);
      expect(
        {for (final c in convs) c.id: c.workspace},
        {'older': '/work/older', 'newer': '/work/newer'},
      );
    });
  });

  group('the title', () {
    test('is what /rename wrote to annotations/<id>.pbtxt', () async {
      // The owner renamed a session and the sidebar went on saying
      // "New session". This file is where that rename landed.
      writeConversation('conv-a');
      writeFile('annotations/conv-a.pbtxt', 'title:"test me now"\n');

      expect((await reader().read(storeHome)).single.title, 'test me now');
    });

    test('unescapes what protobuf text format escaped', () async {
      writeConversation('conv-a');
      writeFile('annotations/conv-a.pbtxt', r'title:"a \"quoted\" name"');

      expect((await reader().read(storeHome)).single.title, 'a "quoted" name');
    });

    test('is null for a conversation nobody renamed', () async {
      writeConversation('conv-a');

      expect((await reader().read(storeHome)).single.title, isNull);
    });

    test('an annotation with an empty title is no title', () async {
      writeConversation('conv-a');
      writeFile('annotations/conv-a.pbtxt', 'title:""');

      expect((await reader().read(storeHome)).single.title, isNull);
    });

    test('displayTitle prefers the rename, then the summary, then '
        'nothing', () async {
      writeConversation('named');
      writeConversation('summarised');
      writeConversation('neither');
      writeFile('annotations/named.pbtxt', 'title:"test me now"');
      writeSummaries([
        ('named', 'Scoring YouTube Content Ideas', 3),
        ('summarised', 'Scoring YouTube Content Ideas', 3),
      ]);

      final byId = {for (final c in await reader().read(storeHome)) c.id: c};

      expect(byId['named']!.displayTitle, 'test me now');
      expect(byId['summarised']!.displayTitle, 'Scoring YouTube Content Ideas');
      // Not a placeholder: a caller has to be able to tell "unnamed" from a
      // name that happens to read like one.
      expect(byId['neither']!.displayTitle, isNull);
    });
  });

  group('what can be said about size and time', () {
    test('the step count is counted live from the conversation file', () async {
      writeConversation('conv-a', steps: 6);
      // Deliberately disagreeing with the live file: the summary table lags,
      // and the live count is the one to believe.
      writeSummaries([('conv-a', '', 3)]);

      expect((await reader().read(storeHome)).single.stepCount, 6);
    });

    test('a conversation with no steps counts zero, not null', () async {
      writeConversation('conv-a');

      expect((await reader().read(storeHome)).single.stepCount, 0);
    });

    test('an unreadable conversation file falls back to the summary', () async {
      File(p.join(storeHome, 'conversations', 'conv-a.db'))
        ..createSync(recursive: true)
        ..writeAsStringSync('not a database');
      writeSummaries([('conv-a', '', 3)]);

      expect((await reader().read(storeHome)).single.stepCount, 3);
    });

    test('and reports no step count when nothing can say', () async {
      File(p.join(storeHome, 'conversations', 'conv-a.db'))
        ..createSync(recursive: true)
        ..writeAsStringSync('not a database');

      expect((await reader().read(storeHome)).single.stepCount, isNull);
    });

    test('conversations come back newest first', () async {
      writeConversation('older');
      writeConversation('newer');
      File(
        p.join(storeHome, 'conversations', 'older.db'),
      ).setLastModifiedSync(DateTime(2026, 8, 25));
      File(
        p.join(storeHome, 'conversations', 'newer.db'),
      ).setLastModifiedSync(DateTime(2026, 9, 1));

      expect((await reader().read(storeHome)).map((c) => c.id), [
        'newer',
        'older',
      ]);
    });
  });

  group('the presence file', () {
    test('is reported as having been opened, not as being live', () async {
      writeConversation('opened');
      writeConversation('never-opened');
      writeFile('presence/opened.lock', '');

      final byId = {for (final c in await reader().read(storeHome)) c.id: c};

      expect(byId['opened']!.hasPresenceFile, isTrue);
      expect(byId['never-opened']!.hasPresenceFile, isFalse);
    });
  });

  group('the summary table', () {
    test('is a hint: a conversation missing from it is still read', () async {
      // The live installation held three conversations and one summary row.
      // A reader that listed the table would have shown the user one session.
      writeConversation('a');
      writeConversation('b');
      writeConversation('c');
      writeSummaries([('a', 'Scoring YouTube Content Ideas', 3)]);

      final conversations = await reader().read(storeHome);

      expect(conversations.map((c) => c.id).toSet(), {'a', 'b', 'c'});
      expect(
        conversations.singleWhere((c) => c.id == 'a').preview,
        'Scoring YouTube Content Ideas',
      );
      expect(conversations.singleWhere((c) => c.id == 'b').preview, isEmpty);
    });

    test('an absent summary database is not an error', () async {
      writeConversation('a');

      expect(await reader().readSummaries(storeHome), isEmpty);
      expect((await reader().read(storeHome)).single.preview, isEmpty);
    });
  });

  group('AntigravityStoreCache', () {
    test('serves cached workspaces and titles across sweeps', () async {
      final cache = AntigravityStoreCache();
      final cachedReader = AntigravityStoreReader(countSteps: false, cache: cache);

      writeConversation('c1');
      writeFile('history.jsonl', '{"conversationId":"c1","workspace":"/work"}\n');
      writeFile('annotations/c1.pbtxt', 'title:"Cached Title"');

      final first = await cachedReader.read(storeHome);
      expect(first.single.workspace, '/work');
      expect(first.single.title, 'Cached Title');

      final workspaces = await cachedReader.readHistoryWorkspaces(storeHome);
      expect(workspaces['c1'], '/work');
      final title = await cachedReader.readTitle(storeHome, 'c1');
      expect(title, 'Cached Title');
    });
  });
}
