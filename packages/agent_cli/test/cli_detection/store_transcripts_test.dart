import 'dart:io';

import 'package:agent_cli/descriptors.dart' show AgentStore;
import 'package:agent_cli/read.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/temp_directory.dart';

/// `AgentStore.transcripts`: every conversation a store holds, by id, with
/// the file its transcript is in — one walk of names, what the server's
/// conversation index locates a transcript by. `conversationIds` is its keys.
void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('store_transcripts_'));
  tearDown(() => removeTempDirectory(tmp));

  File touch(List<String> parts) => File(p.joinAll([tmp.path, ...parts]))
    ..createSync(recursive: true)
    ..writeAsStringSync('');

  Future<void> idsAreKeys(AgentStore store) async {
    final transcripts = await store.transcripts(tmp.path);
    expect(await store.conversationIds(tmp.path), transcripts!.keys.toSet());
  }

  group('Claude Code', () {
    const store = ClaudeCodeStore();

    test('every project bucket, top-level .jsonl only', () async {
      final a = touch(['projects', '-src-a', 'c1.jsonl']);
      final b = touch(['projects', '-src-b', 'c2.jsonl']);
      touch(['projects', '-src-b', 'notes.txt']);
      touch(['projects', '-src-b', 'c2', 'subagents', 'agent-x.jsonl']);

      expect(await store.transcripts(tmp.path), {'c1': a.path, 'c2': b.path});
      await idsAreKeys(store);
    });

    test('a missing store told us nothing', () async {
      expect(await store.transcripts(tmp.path), isNull);
      expect(await store.conversationIds(tmp.path), isNull);
    });
  });

  group('Codex', () {
    const store = CodexStore();

    test(
      'rollouts anywhere under sessions, keyed by the trailing UUID',
      () async {
        const id = '0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b';
        final rollout = touch([
          'sessions',
          '2026',
          '09',
          '27',
          'rollout-2026-09-27T10-00-00-$id.jsonl',
        ]);
        touch(['sessions', '2026', '09', '27', 'rollout-short.jsonl']);
        touch(['sessions', 'other.jsonl']);

        expect(await store.transcripts(tmp.path), {id: rollout.path});
        await idsAreKeys(store);
      },
    );

    test('a missing store told us nothing', () async {
      expect(await store.transcripts(tmp.path), isNull);
    });
  });

  group('Antigravity', () {
    const store = AntigravityStore();

    test('a .db wins over a .pb, whichever is listed first', () async {
      final db = touch(['conversations', 'both.db']);
      touch(['conversations', 'both.pb']);
      final pb = touch(['conversations', 'only.pb']);
      touch(['conversations', 'readme.md']);

      expect(await store.transcripts(tmp.path), {
        'both': db.path,
        'only': pb.path,
      });
      await idsAreKeys(store);
    });

    test('the path is one recordCandidates offers', () async {
      touch(['conversations', 'c.pb']);
      final found = (await store.transcripts(tmp.path))!['c'];
      expect(store.recordCandidates(tmp.path, 'c'), contains(found));
    });

    test('a missing store told us nothing', () async {
      expect(await store.transcripts(tmp.path), isNull);
    });
  });
}
