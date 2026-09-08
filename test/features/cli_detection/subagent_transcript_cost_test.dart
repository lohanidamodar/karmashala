import 'dart:io';

import 'package:karmashala/src/features/agents/domain/agent_ids.dart';
import 'package:karmashala/src/features/cli_detection/data/cli_transcript_reader.dart';
import 'package:flutter_test/flutter_test.dart';

/// **What reading a session's subagents costs.**
///
/// Counted, never timed — the house rule
/// (`test/features/sessions/session_signal_cost_test.dart`,
/// `test/features/terminal/ingest_throughput_cost_test.dart`): a wall-clock
/// assertion over a few milliseconds fails whenever the machine is busy, and
/// the unit that actually matters here is countable exactly. The unit is
/// **files opened** — every `File(path)` this code constructs in order to read
/// it — captured through [IOOverrides], which is the same file the parser will
/// stream.
///
/// The number this gate exists for is the owner's own store. One session on
/// this machine has a **115 MB** parent transcript and **118 subagents whose
/// `.jsonl` files total 1,485 MiB**; their 118 `.meta.json` files total
/// **18,198 bytes**. Reading the metas to build the join is 0.001% of reading
/// the transcripts, and the transcripts are what a chat view would have to
/// re-read on every two-second poll. So: **the metas are read, the subagent
/// transcripts are not, until a row is expanded.**
void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('subagent_cost'));
  tearDown(() => root.deleteSync(recursive: true));

  String parentPath() => '${root.path}/s1.jsonl';

  /// A parent transcript that delegates [tasks] times, plus [subagents]
  /// subagents on disk answering the first [subagents] of them.
  ///
  /// [turnBytes] pads each subagent transcript, so a run can prove the cost is
  /// independent of how much the delegates actually said.
  void seed({
    required int tasks,
    required int subagents,
    int turnBytes = 0,
  }) {
    File(parentPath()).writeAsStringSync([
      '{"type":"user","message":{"role":"user","content":"go"}}',
      for (var i = 0; i < tasks; i++)
        '{"type":"assistant","message":{"content":[{"type":"tool_use",'
            '"id":"toolu_$i","name":"Task","input":{"description":"job $i"}}]}}',
    ].join('\n'));
    if (subagents == 0) return;
    final dir = Directory('${root.path}/s1/subagents')
      ..createSync(recursive: true);
    for (var i = 0; i < subagents; i++) {
      File('${dir.path}/agent-$i.meta.json').writeAsStringSync(
        '{"agentType":"Explore","description":"job $i","spawnDepth":1,'
        '"toolUseId":"toolu_$i"}',
      );
      File('${dir.path}/agent-$i.jsonl').writeAsStringSync(
        '{"type":"assistant","message":{"content":[{"type":"text",'
        '"text":"${'x' * turnBytes}"}]}}',
      );
    }
  }

  test('a session that never delegated opens nothing but its own file',
      () async {
    // No `Task` call means no join to make, so the directory is never even
    // stat-ed. This is the case almost every session is in.
    seed(tasks: 0, subagents: 0);

    final opened = await _filesOpenedBy(
      () => readCliTranscript(parentPath(), AgentIds.claudeCode),
    );

    expect(opened, [parentPath()]);
  });

  test('an unexpanded session reads every meta and no subagent transcript',
      () async {
    // The curve is read at three points. `subagents` doubles and the meta
    // reads double with it; nothing else moves, and no `agent-N.jsonl` is
    // opened at any scale.
    for (final count in [1, 10, 50]) {
      root.listSync().forEach((e) => e.deleteSync(recursive: true));
      seed(tasks: count, subagents: count);

      final opened = await _filesOpenedBy(
        () => readCliTranscript(parentPath(), AgentIds.claudeCode),
      );

      expect(
        opened.where((p) => p.endsWith('.meta.json')),
        hasLength(count),
        reason: 'one meta per subagent — that is the join',
      );
      expect(
        opened.where((p) => RegExp(r'agent-\d+\.jsonl$').hasMatch(p)),
        isEmpty,
        reason: 'a subagent transcript is read only when its row is expanded',
      );
      expect(opened, hasLength(count + 1), reason: 'the metas and the parent');
    }
  });

  test('the cost does not move with how much the subagents said', () async {
    seed(tasks: 4, subagents: 4, turnBytes: 200000);

    final opened = await _filesOpenedBy(
      () => readCliTranscript(parentPath(), AgentIds.claudeCode),
    );

    // 800 KB of delegate output on disk, none of it read.
    expect(opened, hasLength(5));
  });

  test('expanding one row reads exactly that one transcript', () async {
    seed(tasks: 10, subagents: 10);
    final messages = await readCliTranscript(parentPath(), AgentIds.claudeCode);
    final ref = messages[1].subagent!;

    final opened = await _filesOpenedBy(
      () => readSubagentTranscript(ref.filePath),
    );

    // One file. The delegate made no `Task` call of its own, so its own
    // subagent directory is never looked at either.
    expect(opened, [ref.filePath]);
  });

  /// A parent transcript that runs [count] subagents **in the background**, the
  /// way Claude Code actually runs them — the call answered at once with
  /// `async_launched`, the outcome arriving later in a `<task-notification>` —
  /// with a compaction re-enumerating what is live in between.
  ///
  /// [reported] of them report back and are retired; the rest stay in the
  /// ledger, which is the state a strip draws from.
  void seedBackground({required int count, required int reported}) {
    final lines = <String>[
      '{"type":"user","message":{"role":"user","content":"go"}}',
    ];
    for (var i = 0; i < count; i++) {
      lines
        ..add(
          '{"type":"assistant","timestamp":"2026-09-08T09:0$i:00.000Z",'
          '"message":{"content":[{"type":"tool_use","id":"toolu_$i",'
          '"name":"Agent","input":{"description":"job $i"}}]}}',
        )
        ..add(
          '{"type":"user","timestamp":"2026-09-08T09:0$i:01.000Z",'
          '"message":{"content":[{"type":"tool_result",'
          '"tool_use_id":"toolu_$i","content":"launched"}]},'
          '"toolUseResult":{"isAsync":true,"status":"async_launched",'
          '"agentId":"a$i","description":"job $i"}}',
        );
    }
    // The reconciliation point, and the CLI re-stating everything still live.
    lines.add(
      '{"type":"system","subtype":"compact_boundary",'
      '"timestamp":"2026-09-08T10:00:00.000Z"}',
    );
    for (var i = 0; i < count; i++) {
      lines.add(
        '{"type":"attachment","timestamp":"2026-09-08T10:00:01.000Z",'
        '"attachment":{"type":"task_status","taskId":"a$i",'
        '"taskType":"local_agent","status":"running","description":"job $i"}}',
      );
    }
    for (var i = 0; i < reported; i++) {
      lines.add(
        '{"type":"user","timestamp":"2026-09-08T11:0$i:00.000Z",'
        '"message":{"role":"user","content":"<task-notification>'
        '<task-id>a$i</task-id><status>completed</status>'
        '</task-notification>"}}',
      );
    }
    File(parentPath()).writeAsStringSync(lines.join('\n'));
    final dir = Directory('${root.path}/s1/subagents')
      ..createSync(recursive: true);
    for (var i = 0; i < count; i++) {
      File('${dir.path}/agent-$i.meta.json').writeAsStringSync(
        '{"agentType":"general-purpose","description":"job $i",'
        '"spawnDepth":1,"toolUseId":"toolu_$i"}',
      );
      File('${dir.path}/agent-$i.jsonl').writeAsStringSync(
        '{"type":"assistant","message":{"content":[{"type":"text",'
        '"text":"${'x' * 20000}"}]}}',
      );
    }
  }

  test('knowing which background subagents are running opens no extra file',
      () async {
    // **The promise this whole ledger is built to keep.** Whether a background
    // subagent is running is answered entirely from records the CLI wrote into
    // the *parent* transcript — the `async_launched` result, the compaction's
    // re-enumeration, the notification envelope — which is the one file the
    // chat view is reading anyway. Nothing here stats a delegate, reads one, or
    // opens anything the join did not already open.
    for (final count in [1, 10, 50]) {
      root.listSync().forEach((e) => e.deleteSync(recursive: true));
      seedBackground(count: count, reported: count ~/ 2);

      final opened = await _filesOpenedBy(
        () => readCliTranscript(parentPath(), AgentIds.claudeCode),
      );

      expect(
        opened,
        hasLength(count + 1),
        reason: 'the metas and the parent — the same count as before',
      );
      expect(
        opened.where((p) => RegExp(r'agent-\d+\.jsonl$').hasMatch(p)),
        isEmpty,
        reason: 'a running subagent is still not a transcript we read',
      );
    }
  });

  test('and the ledger it built is the one the strip draws', () async {
    // Counted, not timed: how many rows carry a live agent id, and which.
    seedBackground(count: 4, reported: 2);

    final messages = await readCliTranscript(parentPath(), AgentIds.claudeCode);

    expect(
      [
        for (final m in messages)
          if (m.pendingBackgroundAgentId != null) m.pendingBackgroundAgentId,
      ],
      ['a2', 'a3'],
    );
  });
}

/// The distinct files [body] opened, in the order it first reached each one.
///
/// [IOOverrides.createFile] is the single funnel every `File(path)` goes
/// through, so nothing this code reads can escape the count. Distinct paths,
/// not raw constructions: `openRead` re-opens the same path internally
/// (`_FileStream` makes its own handle), and the claim being pinned is *which
/// files are touched at all*, not how many handles dart:io wants for one.
Future<List<String>> _filesOpenedBy(Future<void> Function() body) async {
  final overrides = _CountingIO();
  await IOOverrides.runWithIOOverrides(body, overrides);
  return overrides.files.toList();
}

final class _CountingIO extends IOOverrides {
  final files = <String>{};

  @override
  File createFile(String path) {
    files.add(path);
    return super.createFile(path);
  }
}
