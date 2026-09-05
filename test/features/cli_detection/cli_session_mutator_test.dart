import 'dart:convert';
import 'dart:io';

import 'package:karmashala/src/features/agents/domain/agent_ids.dart';
import 'package:karmashala/src/features/cli_detection/data/cli_session_mutator.dart';
import 'package:karmashala/src/features/cli_detection/domain/detected_session.dart';
import 'package:karmashala/src/features/environments/domain/environment_path.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  // Fresh per test: it carries the cost counters the batch tests assert on.
  late CliSessionMutator mutator;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('karmashala_mut_');
    mutator = CliSessionMutator();
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('Claude rename appends a custom-title line', () async {
    final file = File(p.join(tmp.path, '.claude/projects/-x/abc.jsonl'))
      ..createSync(recursive: true)
      ..writeAsStringSync('{"type":"user","cwd":"/x"}\n');
    final session = DetectedSession(
      cli: AgentIds.claudeCode,
      sessionId: 'abc',
      cwd: const EnvironmentPath(environmentId: 'windows', path: '/x'),
      filePath: file.path,
      storeHome: p.join(tmp.path, '.claude'),
    );

    await mutator.rename(session, 'Renamed');

    final last = file.readAsLinesSync().last;
    final decoded = jsonDecode(last) as Map<String, dynamic>;
    expect(decoded['type'], 'custom-title');
    expect(decoded['customTitle'], 'Renamed');
    expect(decoded['sessionId'], 'abc');
  });

  // The mirror is only the fallback now — `codex_rename_test.dart` covers the
  // `thread/name/set` call that replaced it, and what happens when Codex
  // answers and when it cannot be reached.
  test('Codex rename with no way to reach Codex still updates the mirror', () async {
    final index = File(p.join(tmp.path, '.codex/session_index.jsonl'))
      ..createSync(recursive: true)
      ..writeAsStringSync('{"id":"u1","thread_name":"old"}\n');
    final rollout = File(p.join(tmp.path, '.codex/sessions/rollout-x-u1.jsonl'))
      ..createSync(recursive: true)
      ..writeAsStringSync('{}\n');
    final session = DetectedSession(
      cli: AgentIds.codex,
      sessionId: 'u1',
      cwd: const EnvironmentPath(environmentId: 'wsl:Ubuntu', path: '/x'),
      filePath: rollout.path,
      storeHome: p.join(tmp.path, '.codex'),
    );

    await mutator.rename(session, 'new name');
    expect(index.readAsStringSync(), contains('"thread_name":"new name"'));
  });

  test('Antigravity rename writes annotation file', () async {
    final conv = File(p.join(tmp.path, '.gemini/antigravity-cli/conversations/conv-1.db'))
      ..createSync(recursive: true);
    final session = DetectedSession(
      cli: AgentIds.antigravity,
      sessionId: 'conv-1',
      cwd: const EnvironmentPath(environmentId: 'windows', path: '/x'),
      filePath: conv.path,
      storeHome: p.join(tmp.path, '.gemini/antigravity-cli'),
    );

    await mutator.rename(session, 'my new agy title');
    final annotation = File(
      p.join(tmp.path, '.gemini/antigravity-cli/annotations/conv-1.pbtxt'),
    );
    expect(annotation.existsSync(), isTrue);
    expect(annotation.readAsStringSync(), 'title:"my new agy title"\n');
  });

  test('delete removes the session file', () async {
    final file = File(p.join(tmp.path, '.claude/projects/-x/abc.jsonl'))
      ..createSync(recursive: true)
      ..writeAsStringSync('{}\n');
    final session = DetectedSession(
      cli: AgentIds.claudeCode,
      sessionId: 'abc',
      cwd: const EnvironmentPath(environmentId: 'windows', path: '/x'),
      filePath: file.path,
      storeHome: p.join(tmp.path, '.claude'),
    );
    await mutator.delete(session);
    expect(file.existsSync(), isFalse);
  });

  group('deleteAll walks each store index once', () {
    DetectedSession claude(String id) => DetectedSession(
      cli: AgentIds.claudeCode,
      sessionId: id,
      cwd: const EnvironmentPath(environmentId: 'windows', path: '/x'),
      filePath: p.join(tmp.path, '.claude/projects/-x/$id.jsonl'),
      storeHome: p.join(tmp.path, '.claude'),
      title: 'Claude $id',
    );

    DetectedSession codex(String id) => DetectedSession(
      cli: AgentIds.codex,
      sessionId: id,
      cwd: const EnvironmentPath(environmentId: 'windows', path: '/x'),
      filePath: p.join(tmp.path, '.codex/sessions/rollout-$id.jsonl'),
      storeHome: p.join(tmp.path, '.codex'),
      title: 'Codex $id',
    );

    void seed(List<String> claudeIds, List<String> codexIds) {
      for (final id in claudeIds) {
        File(claude(id).filePath)
          ..createSync(recursive: true)
          ..writeAsStringSync('{}\n');
        File(p.join(tmp.path, '.claude/sessions/$id.json'))
          ..createSync(recursive: true)
          ..writeAsStringSync(jsonEncode({'sessionId': id}));
      }
      for (final id in codexIds) {
        File(codex(id).filePath)
          ..createSync(recursive: true)
          ..writeAsStringSync('{}\n');
      }
      File(p.join(tmp.path, '.codex/session_index.jsonl'))
        ..createSync(recursive: true)
        ..writeAsStringSync(
          codexIds.map((id) => jsonEncode({'id': id})).join('\n'),
        );
    }

    test('one listing and one index rewrite, whatever the batch size', () async {
      seed(['a', 'b', 'c'], ['u', 'v']);

      final report = await mutator.deleteAll([
        for (final id in ['a', 'b', 'c']) claude(id),
        for (final id in ['u', 'v']) codex(id),
      ]);

      expect(report.deleted, 5);
      expect(report.isComplete, isTrue);
      // The claim the whole batch exists for: the Claude resume index is listed
      // once and the Codex index rewritten once, not once per session.
      expect(mutator.storeScans, 2);
      expect(mutator.indexWrites, 4, reason: '3 Claude entries + 1 Codex write');
      expect(
        Directory(p.join(tmp.path, '.claude/sessions')).listSync(),
        isEmpty,
      );
      expect(
        File(p.join(tmp.path, '.codex/session_index.jsonl')).readAsStringSync(),
        isEmpty,
      );
    });

    test('entries for sessions not in the batch are left alone', () async {
      seed(['a', 'keep'], ['u', 'stay']);

      await mutator.deleteAll([claude('a'), codex('u')]);

      expect(
        File(p.join(tmp.path, '.claude/sessions/keep.json')).existsSync(),
        isTrue,
      );
      final index = File(
        p.join(tmp.path, '.codex/session_index.jsonl'),
      ).readAsStringSync();
      expect(index, contains('stay'));
      expect(index, isNot(contains('"u"')));
    });

    test('a session whose file is already gone is not a failure', () async {
      seed(['a'], const []);

      final report = await mutator.deleteAll([claude('a'), claude('vanished')]);

      expect(report.isComplete, isTrue, reason: 'nothing was left behind');
      expect(report.deleted, 2);
      expect(mutator.transcriptsDeleted, 1, reason: 'only one file existed');
    });

    test('an empty batch touches no store at all', () async {
      seed(['a'], ['u']);

      final report = await mutator.deleteAll(const []);

      expect(report.deleted, 0);
      expect(mutator.storeScans, 0);
      expect(File(claude('a').filePath).existsSync(), isTrue);
    });

    test('deleteAll removes antigravity conversation, annotations, and presence', () async {
      final store = p.join(tmp.path, '.gemini/antigravity-cli');
      final conv = File(p.join(store, 'conversations/conv-1.db'))
        ..createSync(recursive: true);
      final annot = File(p.join(store, 'annotations/conv-1.pbtxt'))
        ..createSync(recursive: true)
        ..writeAsStringSync('title:"test"\n');
      final pres = File(p.join(store, 'presence/conv-1.lock'))
        ..createSync(recursive: true);
      final session = DetectedSession(
        cli: AgentIds.antigravity,
        sessionId: 'conv-1',
        cwd: const EnvironmentPath(environmentId: 'windows', path: '/x'),
        filePath: conv.path,
        storeHome: store,
      );

      final report = await mutator.deleteAll([session]);
      expect(report.isComplete, isTrue);
      expect(conv.existsSync(), isFalse);
      expect(annot.existsSync(), isFalse);
      expect(pres.existsSync(), isFalse);
    });
  });
}
