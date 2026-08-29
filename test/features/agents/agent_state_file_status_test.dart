import 'dart:io';

import 'package:chitragupta/src/features/agents/data/agent_state_file_status_source.dart';
import 'package:chitragupta/src/features/agents/domain/agent_descriptor.dart';
import 'package:chitragupta/src/features/agents/domain/agent_registry.dart';
import 'package:chitragupta/src/features/agents/domain/agent_status.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  const source = AgentStateFileStatusSource();
  final claude = AgentRegistry.builtIn.byId('claudeCode')!;
  final codex = AgentRegistry.builtIn.byId('codex')!;
  final antigravity = AgentRegistry.builtIn.byId('antigravity')!;

  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('chitra_status_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  /// Writes [lines] and returns the file's path.
  String write(String name, List<String> lines) {
    final file = File(p.join(tmp.path, name))..createSync(recursive: true);
    file.writeAsStringSync('${lines.join('\n')}\n');
    return file.path;
  }

  DateTime fresh(String path) =>
      File(path).statSync().modified.add(const Duration(seconds: 5));
  DateTime stale(String path) =>
      File(path).statSync().modified.add(const Duration(hours: 3));

  test('a Claude transcript ending in an assistant turn is idle', () async {
    final path = write('a.jsonl', [
      '{"type":"user","message":{"content":"hi"}}',
      '{"type":"assistant","message":{"content":"done"}}',
    ]);

    final report = (await source.read(claude, path, stale(path)))!;

    expect(report.status, AgentActivityStatus.idle);
    expect(report.source, AgentStatusSource.stateFile);
    expect(report.agentId, 'claudeCode');
  });

  test('a fresh Claude transcript ending mid-turn is working', () async {
    final path = write('b.jsonl', [
      '{"type":"assistant","message":{"content":"tool time"}}',
      '{"type":"user","message":{"content":"tool_result"}}',
    ]);

    final report = (await source.read(claude, path, fresh(path)))!;

    expect(report.status, AgentActivityStatus.working);
  });

  test('a stale transcript ending mid-turn is unknown, not working', () async {
    final path = write('c.jsonl', [
      '{"type":"user","message":{"content":"tool_result"}}',
    ]);

    final report = (await source.read(claude, path, stale(path)))!;

    expect(report.status, AgentActivityStatus.unknown);
  });

  test('a Codex rollout ending in an assistant message is idle', () async {
    final path = write('d.jsonl', [
      '{"type":"response_item","payload":{"type":"message","role":"user",'
          '"content":[{"type":"input_text","text":"go"}]}}',
      '{"type":"response_item","payload":{"type":"message","role":"assistant",'
          '"content":[{"type":"output_text","text":"ok"}]}}',
    ]);

    final report = (await source.read(codex, path, stale(path)))!;

    expect(report.status, AgentActivityStatus.idle);
  });

  test('a fresh Codex rollout ending in a tool call is working', () async {
    final path = write('e.jsonl', [
      '{"type":"response_item","payload":{"type":"function_call",'
          '"name":"shell"}}',
    ]);

    final report = (await source.read(codex, path, fresh(path)))!;

    expect(report.status, AgentActivityStatus.working);
  });

  test(
    'a corrupt final line falls back to the last decodable record',
    () async {
      final path = write('f.jsonl', [
        '{"type":"assistant","message":{"content":"done"}}',
        '{"type":"user","messa',
      ]);

      final report = (await source.read(claude, path, stale(path)))!;

      expect(report.status, AgentActivityStatus.idle);
    },
  );

  test(
    'classifies from the tail of a file larger than the tail window',
    () async {
      final padding = List.generate(
        4000,
        (i) => '{"type":"user","message":{"content":"${'x' * 40} $i"}}',
      );
      final path = write('g.jsonl', [
        ...padding,
        '{"type":"assistant","message":{"content":"done"}}',
      ]);
      expect(File(path).lengthSync(), greaterThan(65536));

      final report = (await source.read(claude, path, stale(path)))!;

      expect(report.status, AgentActivityStatus.idle);
    },
  );

  test('an empty file yields no report', () async {
    final path = p.join(tmp.path, 'h.jsonl');
    File(path).writeAsStringSync('');

    expect(await source.read(claude, path, DateTime.utc(2026)), isNull);
  });

  test('a missing file yields no report', () async {
    expect(
      await source.read(
        claude,
        p.join(tmp.path, 'nope.jsonl'),
        DateTime.utc(2026),
      ),
      isNull,
    );
  });

  test('an agent with no state-file rules yields no report', () async {
    final path = write('i.jsonl', [
      '{"type":"assistant","message":{"content":"done"}}',
    ]);

    expect(await source.read(antigravity, path, fresh(path)), isNull);
  });

  test('failed and awaitingApproval rules outrank idle and working', () async {
    const descriptor = AgentDescriptor(
      id: 'demo',
      displayName: 'Demo',
      binaries: AgentBinaries(windows: ['demo'], posix: ['demo']),
      stateFile: AgentStateFileRules(
        idle: [
          StateRecordMatcher(['type'], 'assistant'),
        ],
        working: [
          StateRecordMatcher(['type'], 'assistant'),
        ],
        awaitingApproval: [
          StateRecordMatcher(['state'], 'approval'),
        ],
        failed: [
          StateRecordMatcher(['state'], 'error'),
        ],
      ),
    );

    final approval = write('j.jsonl', [
      '{"type":"assistant","state":"approval"}',
    ]);
    final failure = write('k.jsonl', ['{"type":"assistant","state":"error"}']);

    expect(
      (await source.read(descriptor, approval, fresh(approval)))!.status,
      AgentActivityStatus.awaitingApproval,
    );
    expect(
      (await source.read(descriptor, failure, fresh(failure)))!.status,
      AgentActivityStatus.failed,
    );
  });

  test('an unclassifiable record is unknown', () async {
    final path = write('l.jsonl', ['{"type":"summary","summary":"x"}']);

    final report = (await source.read(claude, path, fresh(path)))!;

    expect(report.status, AgentActivityStatus.unknown);
  });
}
