import 'dart:io';

import 'package:karmashala/src/features/agents/data/agent_state_file_status_source.dart';
import 'package:karmashala/src/features/agents/domain/agent_descriptor.dart';
import 'package:karmashala/src/features/agents/domain/agent_registry.dart';
import 'package:karmashala/src/features/agents/domain/agent_status.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  const source = AgentStateFileStatusSource();
  final claude = AgentRegistry.builtIn.byId('claudeCode')!;
  final codex = AgentRegistry.builtIn.byId('codex')!;
  final antigravity = AgentRegistry.builtIn.byId('antigravity')!;

  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('karmashala_status_'));
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

  test(
    'an assistant record that still carries a tool_use is not idle',
    () async {
      // The shape a Claude Code transcript really has while a subagent runs.
      // Copied from the owner's own store: the `Agent`/`Task` call is written
      // as an assistant record carrying a `tool_use` block, and the matching
      // `tool_result` does not arrive — in a *later* user record — until the
      // subagent finishes, which can be many minutes.
      //
      // `type == assistant` alone therefore reads a turn in flight as a
      // finished one, and a finished turn is what fires the "finished"
      // notification. Replaying the owner's live transcript
      // (`-mnt-c-...-8a817d98-....jsonl`) finds 6,291 points where the last
      // record is an assistant record with an unanswered tool_use — 18 hours
      // of wall time that would have been reported as idle, the longest single
      // window being 25 minutes on an `AskUserQuestion` the session was
      // literally waiting on the user for.
      final path = write('m.jsonl', [
        '{"type":"user","message":{"content":"delegate this"}}',
        '{"type":"assistant","message":{"role":"assistant","content":'
            '[{"type":"tool_use","id":"toolu_01","name":"Task",'
            '"input":{"subagent_type":"Explore"}}]}}',
      ]);

      final report = (await source.read(claude, path, fresh(path)))!;

      expect(report.status, AgentActivityStatus.working);
    },
  );

  test('a finished turn is still idle', () async {
    // The other half of the same rule. A turn that really ended writes an
    // assistant record whose content holds only text, so nothing here makes a
    // session that has stopped look busy.
    final path = write('n.jsonl', [
      '{"type":"user","message":{"content":"hi"}}',
      '{"type":"assistant","message":{"role":"assistant","content":'
          '[{"type":"text","text":"All done."}]}}',
    ]);

    final report = (await source.read(claude, path, stale(path)))!;

    expect(report.status, AgentActivityStatus.idle);
  });

  test(
    'a subagent call nobody has answered for hours is unknown, not idle',
    () async {
      // The staleness rule already says a `working` record stops meaning
      // working once nothing is writing the file. `unknown` is the honest
      // answer for a transcript frozen mid-tool-call, and — unlike `idle` — it
      // is not news, so it cannot fire a completion.
      final path = write('o.jsonl', [
        '{"type":"assistant","message":{"role":"assistant","content":'
            '[{"type":"tool_use","id":"toolu_02","name":"Task","input":{}}]}}',
      ]);

      final report = (await source.read(claude, path, stale(path)))!;

      expect(report.status, AgentActivityStatus.unknown);
    },
  );

  test('a broken Claude turn is failed, not finished', () async {
    // The exact last record of
    // `~/.claude/projects/G--dev-godot-proc-nepal/bbde0f77-9a6e-445e-b13d-
    // db7e3e92b95b/subagents/agent-a4772db3a758e9504.jsonl` (Claude Code
    // 2.1.197), trimmed to the fields that classify it. Its `type` is
    // `assistant` and its content is one `text` block, so the idle rule matched
    // it exactly and the app announced a session that broke as finished.
    final path = write('api-error.jsonl', [
      '{"type":"user","message":{"content":"go"}}',
      '{"type":"assistant","error":"server_error","isApiErrorMessage":true,'
          '"message":{"model":"<synthetic>","role":"assistant","content":'
          '[{"type":"text","text":"API Error: Unable to connect to API '
          '(FailedToOpenSocket)"}]}}',
    ]);

    final report = (await source.read(claude, path, stale(path)))!;

    expect(report.status, AgentActivityStatus.failed);
    expect(report.detail, 'isApiErrorMessage=true');
  });

  test('an OAuth failure is failed however long ago it happened', () async {
    // The other message the owner's store carries, three times, and the one
    // that made this worth fixing first: a session whose credentials expired
    // reported "finished". Staleness must not soften it — a failure that has
    // sat for hours is still a failure, unlike a `working` record.
    final path = write('oauth.jsonl', [
      '{"type":"assistant","error":"authentication_failed",'
          '"isApiErrorMessage":true,"message":{"model":"<synthetic>",'
          '"role":"assistant","content":[{"type":"text","text":'
          '"Failed to authenticate: OAuth session expired and could not be '
          'refreshed"}]}}',
    ]);

    expect(
      (await source.read(claude, path, stale(path)))!.status,
      AgentActivityStatus.failed,
    );
    expect(
      (await source.read(claude, path, fresh(path)))!.status,
      AgentActivityStatus.failed,
    );
  });

  test('a synthetic record that is not an error is still idle', () async {
    // Why the boolean is the key and `message.model` is not.
    // `"model":"<synthetic>"` is also how the CLI writes its "No response
    // requested." placeholder — 35 of them in the owner's store, all
    // `isApiErrorMessage: false`. Matching the model would have called every
    // one of those a failure.
    final path = write('synthetic-ok.jsonl', [
      '{"type":"assistant","isApiErrorMessage":false,"message":'
          '{"model":"<synthetic>","role":"assistant","content":'
          '[{"type":"text","text":"No response requested."}]}}',
    ]);

    expect(
      (await source.read(claude, path, stale(path)))!.status,
      AgentActivityStatus.idle,
    );
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
