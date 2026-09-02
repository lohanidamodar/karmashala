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
  setUp(() => tmp = Directory.systemTemp.createTempSync('karmashala_mut_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  const mutator = CliSessionMutator();

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

  test('Codex rename rewrites thread_name in the index', () async {
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
}
