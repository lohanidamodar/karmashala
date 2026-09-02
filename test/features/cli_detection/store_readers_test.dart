import 'dart:io';

import 'package:karmashala/src/features/agents/domain/agent_ids.dart';
import 'package:karmashala/src/features/cli_detection/data/claude_store_reader.dart';
import 'package:karmashala/src/features/cli_detection/data/codex_store_reader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('karmashala_cli_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  void write(String path, List<String> lines) {
    final f = File(p.join(tmp.path, path))..createSync(recursive: true);
    f.writeAsStringSync('${lines.join('\n')}\n');
  }

  group('ClaudeStoreReader', () {
    test('reads title precedence, cwd, preview, and entrypoint', () async {
      write('.claude/projects/-home-me-proj/abc.jsonl', [
        '{"type":"user","cwd":"/home/me/proj","entrypoint":"cli",'
            '"message":{"role":"user","content":[{"type":"text","text":"hello world"}]}}',
        '{"type":"ai-title","aiTitle":"AI Title"}',
        '{"type":"custom-title","sessionId":"abc","customTitle":"My Title"}',
      ]);

      final sessions = await ClaudeStoreReader().read(
        p.join(tmp.path, '.claude'),
        'windows',
      );
      expect(sessions.length, 1);
      final s = sessions.single;
      expect(s.cli, AgentIds.claudeCode);
      expect(s.sessionId, 'abc');
      expect(s.title, 'My Title'); // custom-title beats ai-title
      expect(s.preview, 'hello world');
      expect(s.cwd.path, '/home/me/proj');
      expect(s.isSubagent, isFalse);
    });

    test('flags sdk-spawned subagents', () async {
      write('.claude/projects/-x/sub.jsonl', [
        '{"type":"user","cwd":"/x","entrypoint":"sdk-cli",'
            '"message":{"content":[{"type":"text","text":"hi"}]}}',
      ]);
      final s = (await ClaudeStoreReader().read(
        p.join(tmp.path, '.claude'),
        'windows',
      )).single;
      expect(s.isSubagent, isTrue);
    });
  });

  group('CodexStoreReader', () {
    test('reads cwd from session_meta and title from session_index', () async {
      write('.codex/sessions/2026/01/01/rollout-2026-01-01T00-00-00-uuid.jsonl', [
        '{"timestamp":"t","type":"session_meta","payload":{"id":"u1","cwd":"/mnt/g/dev/x"}}',
        '{"timestamp":"t","type":"response_item","payload":{"type":"message",'
            '"role":"user","content":[{"type":"input_text","text":"do thing"}]}}',
      ]);
      write('.codex/session_index.jsonl', [
        '{"id":"u1","thread_name":"My Thread"}',
      ]);

      final sessions = await CodexStoreReader(cache: CodexRolloutCache()).read(
        p.join(tmp.path, '.codex'),
        'wsl:Ubuntu',
      );
      expect(sessions.length, 1);
      final s = sessions.single;
      expect(s.cli, AgentIds.codex);
      expect(s.sessionId, 'u1');
      expect(s.cwd.path, '/mnt/g/dev/x');
      expect(s.title, 'My Thread');
      expect(s.preview, 'do thing');
    });

    test('skips rollouts without a cwd', () async {
      write('.codex/sessions/rollout-x-uuid.jsonl', [
        '{"id":"u2","timestamp":"t"}',
      ]);
      final sessions = await CodexStoreReader(cache: CodexRolloutCache()).read(
        p.join(tmp.path, '.codex'),
        'wsl:Ubuntu',
      );
      expect(sessions, isEmpty);
    });
  });
}
