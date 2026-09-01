import 'dart:convert';
import 'dart:io';

import 'package:karmashala/src/features/agents/domain/agent_descriptor.dart';
import 'package:karmashala/src/features/agents/domain/agent_ids.dart';
import 'package:karmashala/src/features/agents/domain/agent_registry.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_service.dart';
import 'package:karmashala/src/features/cli_detection/data/conversation_store_index.dart';
import 'package:karmashala/src/features/cli_detection/domain/conversation_presence.dart';
import 'package:karmashala/src/features/sessions/domain/session_launch.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

/// Detection for the Antigravity store.
///
/// the design note: the reader landed, the enum
/// value did not, and `CliDetectionService.readStores` switches exhaustively on
/// [AgentStoreFormat] — so the descriptor was pinned at
/// [AgentStoreFormat.none] and every Antigravity conversation was invisible to
/// detection, to adoption's store sweep and to the presence probe.
void main() {
  late Directory tmp;
  late String storeHome;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('karmashala_agy_detect_');
    storeHome = p.join(tmp.path, '.gemini', 'antigravity-cli');
  });
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows keeps a handle on a database a failing test left open.
    }
  });

  /// A conversation file with the real `trajectory_meta`/`steps` schema, copied
  /// off a live 1.1.22 store (see `antigravity_store_reader_test.dart`).
  void writeConversation(String id, {int steps = 0}) {
    final path = p.join(storeHome, 'conversations', '$id.db');
    Directory(p.dirname(path)).createSync(recursive: true);
    final db = sqlite3.open(path);
    db.execute(
      'CREATE TABLE `trajectory_meta` (`trajectory_id` text, `cascade_id` text,'
      ' `trajectory_type` integer, `source` integer,'
      ' PRIMARY KEY (`trajectory_id`));',
    );
    db.execute(
      'CREATE TABLE `steps` (`idx` integer, `step_type` integer NOT NULL '
      'DEFAULT 0, `status` integer NOT NULL DEFAULT 0, `metadata` blob, '
      '`step_payload` blob, `has_subtrajectory` integer NOT NULL DEFAULT 0);',
    );
    db.execute(
      "INSERT INTO trajectory_meta VALUES ('traj-$id', '$id', 4, 17);",
    );
    for (var i = 0; i < steps; i++) {
      db.execute(
        'INSERT INTO steps (idx, step_type, status) VALUES ($i, 15, 3);',
      );
    }
    db.close();
  }

  void writeLastConversations(Map<String, String> byDirectory) {
    File(p.join(storeHome, 'cache', 'last_conversations.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync(jsonEncode(byDirectory));
  }

  void writeAnnotation(String id, String title) {
    File(p.join(storeHome, 'annotations', '$id.pbtxt'))
      ..createSync(recursive: true)
      ..writeAsStringSync('title:"$title"\n');
  }

  void writeSummaries(List<(String id, String preview)> rows) {
    final path = p.join(storeHome, 'conversation_summaries.db');
    Directory(p.dirname(path)).createSync(recursive: true);
    final db = sqlite3.open(path);
    db.execute(
      'CREATE TABLE `conversation_summaries` (`conversation_id` text,'
      ' `title` text NOT NULL DEFAULT "", `preview` text NOT NULL DEFAULT "",'
      ' `step_count` integer NOT NULL DEFAULT 0,'
      ' `workspace_uris` text NOT NULL DEFAULT "",'
      ' PRIMARY KEY (`conversation_id`));',
    );
    for (final (id, preview) in rows) {
      db.execute('INSERT INTO conversation_summaries VALUES (?, ?, ?, 0, ?);', [
        id,
        '',
        preview,
        '',
      ]);
    }
    db.close();
  }

  CliStore store() => CliStore(
    environmentId: 'wsl:Ubuntu',
    homesByAgentId: {AgentIds.antigravity: storeHome},
  );

  group('the descriptor', () {
    test('declares a readable store, so detection reaches the reader', () {
      final descriptor = AgentRegistry.builtIn.byId(AgentIds.antigravity)!;
      expect(descriptor.store!.format, AgentStoreFormat.antigravityStore);
    });

    test('still offers no chat view — message content stays protobuf', () {
      // §8: `steps.step_payload` is an unpublished schema, so a readable store
      // is not a readable transcript. `agentSupportsChatView` is an allowlist
      // for exactly this reason.
      final descriptor = AgentRegistry.builtIn.byId(AgentIds.antigravity)!;
      expect(agentSupportsChatView(descriptor), isFalse);
      expect(defaultViewFor(descriptor), SessionView.terminal);
    });
  });

  group('CliDetectionService.readStores', () {
    test('maps each conversation the store places to a DetectedSession', () async {
      const id = 'df3c0708-1111-4222-8333-444455556666';
      writeConversation(id, steps: 6);
      writeLastConversations({'/home/me/proj': id});
      writeAnnotation(id, 'test me now');
      writeSummaries([(id, 'wHAT ?')]);

      final sessions = await const CliDetectionService().readStores([store()]);

      expect(sessions.length, 1);
      final session = sessions.single;
      expect(session.cli, AgentIds.antigravity);
      expect(session.sessionId, id);
      expect(session.cwd.path, '/home/me/proj');
      expect(session.cwd.environmentId, 'wsl:Ubuntu');
      expect(session.title, 'test me now');
      expect(session.preview, 'wHAT ?');
      expect(session.storeHome, storeHome);
    });

    test('leaves out a conversation the store places nowhere', () async {
      // `cache/last_conversations.json` holds one entry per *directory*, so an
      // older conversation in a directory that has since been used again has no
      // workspace at all. A session with no directory cannot be merged into a
      // project, and inventing one would file it under the wrong repository.
      const placed = 'aaaaaaaa-1111-4222-8333-444455556666';
      const orphan = 'bbbbbbbb-1111-4222-8333-444455556666';
      writeConversation(placed);
      writeConversation(orphan);
      writeLastConversations({'/home/me/proj': placed});

      final sessions = await const CliDetectionService().readStores([store()]);

      expect(sessions.map((s) => s.sessionId), [placed]);
    });

    test('a store that is not there is not an error', () async {
      final sessions = await const CliDetectionService().readStores([
        CliStore(
          environmentId: 'windows',
          homesByAgentId: {
            AgentIds.antigravity: p.join(tmp.path, 'nothing-here'),
          },
        ),
      ]);
      expect(sessions, isEmpty);
    });
  });

  group('ConversationStoreIndex', () {
    test('finds a conversation by its file name', () async {
      const id = 'cccccccc-1111-4222-8333-444455556666';
      writeConversation(id);
      expect(
        await const ConversationStoreIndex().presenceOf(
          storeHome: storeHome,
          format: AgentStoreFormat.antigravityStore,
          conversationId: id,
        ),
        ConversationPresence.present,
      );
    });

    test('calls one absent only when the store itself is readable', () async {
      const id = 'dddddddd-1111-4222-8333-444455556666';
      writeConversation('eeeeeeee-1111-4222-8333-444455556666');
      expect(
        await const ConversationStoreIndex().presenceOf(
          storeHome: storeHome,
          format: AgentStoreFormat.antigravityStore,
          conversationId: id,
        ),
        ConversationPresence.absent,
      );
      expect(
        await const ConversationStoreIndex().presenceOf(
          storeHome: p.join(tmp.path, 'nothing-here'),
          format: AgentStoreFormat.antigravityStore,
          conversationId: id,
        ),
        ConversationPresence.unknown,
      );
    });
  });
}
