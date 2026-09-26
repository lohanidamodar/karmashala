import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart';
import 'package:karmashala_host/src/sessions/directory_attribution.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'sync_fixture.dart';

/// Learning which conversation a session launched for an agent whose store
/// records the last conversation per directory is on (Antigravity), at the
/// server (slice 2b; moved from the app's
/// `DirectoryConversationAttributionService`), over a real store in a temp
/// folder. The rules are the adapter's (`antigravity_session_resume_test`);
/// this is which rows the server applies them to, what it writes, and why it
/// refuses.
void main() {
  late Directory tmp;
  late String storeHome;
  late SyncFixture world;

  const conversation = 'df3c0708-1111-4222-8333-444455556666';
  const other = 'e921cb55-1111-4222-8333-444455556666';

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('karmashala_dir_attr_');
    storeHome = p.join(tmp.path, '.gemini', 'antigravity-cli');
    world = SyncFixture();
  });
  tearDown(() {
    world.close();
    tmp.deleteSync(recursive: true);
  });

  void writeConversation(String id, {Duration age = Duration.zero}) {
    File(p.join(storeHome, 'conversations', '$id.db'))
      ..createSync(recursive: true)
      ..writeAsStringSync('not read by attribution')
      ..setLastModifiedSync(launchedAt.add(age));
  }

  void writeLastConversations(Map<String, String> byDirectory) {
    File(p.join(storeHome, 'cache', 'last_conversations.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync(jsonEncode(byDirectory));
  }

  void insert({
    String id = 's1',
    String installation = 'a3',
    String? externalId,
    String? directory = repoPath,
    String? paneId,
  }) => world.insert(
    sessionRow(
      id: id,
      installation: installation,
      externalId: externalId,
      directory: directory,
      paneId: paneId,
    ),
  );

  DirectoryAttribution subject({Map<String, List<String>> tails = const {}}) =>
      DirectoryAttribution(
        rows: world.rows,
        locateStores: () async => [
          CliStore(
            environmentId: 'windows',
            homesByAgentId: {AgentIds.antigravity: storeHome},
          ),
        ],
        readTail: (session, lines) => tails[session.paneId] ?? const [],
      );

  group('what it learns', () {
    test('the conversation the directory names, once it is new', () async {
      writeConversation(conversation, age: const Duration(seconds: 5));
      writeLastConversations({repoPath: conversation});
      insert();

      final attribution = subject();
      expect(attribution.wantsStoreSweep, isTrue);
      expect(await attribution.attribute(), 1);
      expect(world.row('s1')!.externalSessionId, conversation);
      expect(world.toldRows, ['s1']);
      expect(attribution.wantsStoreSweep, isFalse);
    });

    test('what the agent printed in its pane beats the store', () async {
      writeConversation(other, age: const Duration(seconds: 5));
      writeLastConversations({repoPath: other});
      insert(paneId: 'pane-1');

      final attribution = subject(
        tails: {
          'pane-1': [
            'Resume with -c (or command below):',
            'agy --conversation=$conversation',
          ],
        },
      );
      expect(await attribution.attribute(), 1);
      expect(world.row('s1')!.externalSessionId, conversation);
    });

    test('the pane asked about is the row\'s, at the agent\'s depth', () {
      insert(paneId: 'pane-1');
      final attribution = subject();
      expect(attribution.waitingRows().single.paneId, 'pane-1');
      expect(attribution.tailLines, greaterThan(0));
    });
  });

  group('what it refuses, and why the reason differs', () {
    test('a directory the store never recorded a conversation for', () async {
      writeLastConversations({r'C:\elsewhere': other});
      insert();
      final attribution = subject();
      expect(await attribution.attribute(), 0);
      expect(attribution.reasonFor('s1'), contains('no conversation'));
      expect(world.told, isEmpty);
    });

    test('a conversation written before this session started', () async {
      writeConversation(conversation, age: const Duration(minutes: -5));
      writeLastConversations({repoPath: conversation});
      insert();
      final attribution = subject();
      expect(await attribution.attribute(), 0);
      expect(attribution.reasonFor('s1'), contains('earlier one'));
    });

    test('a conversation another session already holds', () async {
      writeConversation(conversation, age: const Duration(seconds: 5));
      writeLastConversations({repoPath: conversation});
      insert(id: 'held', externalId: conversation);
      insert(id: 's1');
      final attribution = subject();
      expect(await attribution.attribute(), 0);
      expect(attribution.reasonFor('s1'), contains('another session'));
    });

    test('two unattributed sessions in one directory', () async {
      writeConversation(conversation, age: const Duration(seconds: 5));
      writeLastConversations({repoPath: conversation});
      insert(id: 's1');
      insert(id: 's2');
      final attribution = subject();
      expect(await attribution.attribute(), 0);
      expect(world.row('s1')!.externalSessionId, isNull);
      expect(world.row('s2')!.externalSessionId, isNull);
      expect(attribution.reasonFor('s1'), contains('More than one session'));
    });

    test('stores that cannot be located change nothing', () async {
      insert();
      final attribution = DirectoryAttribution(
        rows: world.rows,
        locateStores: () async => throw const FileSystemException('gone'),
      );
      expect(await attribution.attribute(), 0);
      expect(world.row('s1')!.externalSessionId, isNull);
    });
  });

  group('which rows it looks at', () {
    test('never one that already has an id', () async {
      writeConversation(other, age: const Duration(seconds: 5));
      writeLastConversations({repoPath: other});
      insert(externalId: conversation);
      final attribution = subject();
      expect(attribution.wantsStoreSweep, isFalse);
      expect(await attribution.attribute(), 0);
      expect(world.row('s1')!.externalSessionId, conversation);
    });

    test('never another agent, whose store this is not', () async {
      writeConversation(conversation, age: const Duration(seconds: 5));
      writeLastConversations({repoPath: conversation});
      insert(installation: 'a1');
      final attribution = subject();
      expect(attribution.wantsStoreSweep, isFalse);
      expect(await attribution.attribute(), 0);
    });

    test('never an archived one', () async {
      writeConversation(conversation, age: const Duration(seconds: 5));
      writeLastConversations({repoPath: conversation});
      insert();
      world.sessions.markArchived('s1', launchedAt);
      expect(subject().wantsStoreSweep, isFalse);
      expect(await subject().attribute(), 0);
    });

    test('falls back to the checkout when no directory was recorded', () async {
      writeConversation(conversation, age: const Duration(seconds: 5));
      writeLastConversations({repoPath: conversation});
      insert(directory: null);
      expect(await subject().attribute(), 1);
      expect(world.row('s1')!.externalSessionId, conversation);
    });
  });
}
