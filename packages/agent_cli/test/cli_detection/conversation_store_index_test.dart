import 'dart:io';

import 'package:agent_cli/src/agents/domain/agent_descriptor.dart';
import 'package:agent_cli/src/cli_detection/data/conversation_store_index.dart';
import 'package:agent_cli/src/cli_detection/domain/conversation_presence.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/temp_directory.dart';

void main() {
  late Directory tmp;
  const index = ConversationStoreIndex();

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('conv_index_test_');
  });

  tearDown(() {
    removeTempDirectory(tmp);
  });

  group('Antigravity store index', () {
    test('detects conversation present from .db file', () async {
      final file = File(p.join(tmp.path, 'conversations', 'conv-1.db'))
        ..createSync(recursive: true);
      file.writeAsStringSync('');

      final presence = await index.presenceOf(
        storeHome: tmp.path,
        format: AgentStoreFormat.antigravityStore,
        conversationId: 'conv-1',
      );

      expect(presence, ConversationPresence.present);
    });

    test('detects conversation present from .pb file', () async {
      final file = File(p.join(tmp.path, 'conversations', 'conv-2.pb'))
        ..createSync(recursive: true);
      file.writeAsStringSync('');

      final presence = await index.presenceOf(
        storeHome: tmp.path,
        format: AgentStoreFormat.antigravityStore,
        conversationId: 'conv-2',
      );

      expect(presence, ConversationPresence.present);
    });

    test('returns absent for non-existent conversation id', () async {
      final dir = Directory(p.join(tmp.path, 'conversations'))..createSync(recursive: true);
      expect(await dir.exists(), isTrue);

      final presence = await index.presenceOf(
        storeHome: tmp.path,
        format: AgentStoreFormat.antigravityStore,
        conversationId: 'non-existent',
      );

      expect(presence, ConversationPresence.absent);
    });

    test('idsIn lists both .db and .pb conversation ids', () async {
      File(p.join(tmp.path, 'conversations', 'conv-db.db'))
        ..createSync(recursive: true)
        ..writeAsStringSync('');
      File(p.join(tmp.path, 'conversations', 'conv-pb.pb'))
        ..createSync(recursive: true)
        ..writeAsStringSync('');
      File(p.join(tmp.path, 'conversations', 'ignore-me.txt'))
        ..createSync(recursive: true)
        ..writeAsStringSync('');

      final ids = await index.idsIn(
        storeHome: tmp.path,
        format: AgentStoreFormat.antigravityStore,
      );

      expect(ids, containsAll(['conv-db', 'conv-pb']));
      expect(ids, isNot(contains('ignore-me')));
    });

    test('returns unknown or null when conversations directory does not exist', () async {
      final presence = await index.presenceOf(
        storeHome: tmp.path,
        format: AgentStoreFormat.antigravityStore,
        conversationId: 'some-id',
      );
      expect(presence, ConversationPresence.unknown);

      final ids = await index.idsIn(
        storeHome: tmp.path,
        format: AgentStoreFormat.antigravityStore,
      );
      expect(ids, isNull);
    });
  });
}
