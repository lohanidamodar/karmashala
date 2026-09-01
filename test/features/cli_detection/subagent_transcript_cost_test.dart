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
