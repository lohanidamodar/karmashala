import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/read.dart';

/// What a steady-state chat poll costs: a whole-file parse (before) against a
/// [CliTranscriptTail] read of a small append (after).
///
///     dart run tool/transcript_tail_cost.dart [metas]    # synthetic ~65 MB
///     dart run tool/transcript_tail_cost.dart <path> 60  # a live transcript
///
/// The live form only reads: it never writes to or copies the file, and waits
/// up to the given seconds for its writer to append. It prints numbers and
/// whether the tail agreed with a whole-file read — never content.
Future<void> main(List<String> args) async {
  final metas = int.tryParse(args.elementAtOrNull(0) ?? '40');
  if (metas == null) {
    await _live(
      args[0],
      Duration(seconds: int.parse(args.elementAtOrNull(1) ?? '60')),
    );
    return;
  }
  final dir = await Directory.systemTemp.createTemp('ks-tail-');
  try {
    await _synthetic(dir, metas);
  } finally {
    await dir.delete(recursive: true);
  }
}

Future<void> _synthetic(Directory dir, int metas) async {
  final file = File('${dir.path}/session.jsonl');
  final sink = file.openWrite();
  var i = 0;
  while (true) {
    sink.write(_pair(i++, 1200 + (i % 7 == 0 ? 6000 : 0)));
    if (i % 5000 == 0 && await file.length() > 65 << 20) break;
    if (i % 500 == 0) await sink.flush();
  }
  await sink.close();
  // A delegating session: the index is read on every result either way.
  final subagents = Directory('${dir.path}/session/subagents')
    ..createSync(recursive: true);
  for (var s = 0; s < metas; s++) {
    File('${subagents.path}/agent-$s.jsonl').writeAsStringSync('');
    File(
      '${subagents.path}/agent-$s.meta.json',
    ).writeAsStringSync(jsonEncode({'toolUseId': 'task_${s * 10}'}));
  }
  print(
    'fixture ${(await file.length()) >> 20} MiB, $i call/result pairs, $metas subagent metas',
  );

  for (var round = 0; round < 3; round++) {
    final sw = Stopwatch()..start();
    final rows = await readCliTranscriptOffThread(file.path, 'claudeCode');
    print(
      'BEFORE whole-file parse (off-thread, as the poll did): ${sw.elapsedMilliseconds} ms, ${rows.length} rows',
    );
  }

  final tail = CliTranscriptTail(file.path, 'claudeCode');
  var sw = Stopwatch()..start();
  await tail.read();
  print(
    'AFTER first read (${tail.lastRead!.name}): ${sw.elapsedMilliseconds} ms',
  );

  final ticks = <int>[];
  for (var t = 0; t < 20; t++) {
    final append = _pair(i++, 1500);
    file.writeAsStringSync(append, mode: FileMode.append);
    sw = Stopwatch()..start();
    await tail.read();
    ticks.add(sw.elapsedMicroseconds);
    if (tail.lastRead != TranscriptTailRead.delta) throw 'not a delta';
  }
  ticks.sort();
  print(
    'AFTER steady tick, ${utf8.encode(_pair(0, 1500)).length} B appended, on the caller: '
    'median ${ticks[ticks.length ~/ 2]} us, min ${ticks.first} us, max ${ticks.last} us',
  );

  // The largest append still parsed on the caller.
  final edge = StringBuffer();
  while (edge.length < kTranscriptTailOnCallerBytes - 4096) {
    edge.write(_pair(i++, 1500));
  }
  file.writeAsStringSync(edge.toString(), mode: FileMode.append);
  sw = Stopwatch()..start();
  await tail.read();
  print(
    'AFTER ${edge.length >> 10} KiB append (${tail.lastRead!.name}): '
    '${sw.elapsedMilliseconds} ms',
  );

  final big = StringBuffer();
  while (big.length < 1 << 20) {
    big.write(_pair(i++, 1500));
  }
  file.writeAsStringSync(big.toString(), mode: FileMode.append);
  sw = Stopwatch()..start();
  await tail.read();
  print(
    'AFTER 1 MiB append (${tail.lastRead!.name}): ${sw.elapsedMilliseconds} ms',
  );

  final same = _equal(
    await tail.read(),
    await readCliTranscript(file.path, 'claudeCode'),
  );
  print('tail equals whole-file read: $same');
}

Future<void> _live(String path, Duration window) async {
  final file = File(path);
  print('live transcript ${(await file.length()) >> 20} MiB');
  for (var round = 0; round < 3; round++) {
    final sw = Stopwatch()..start();
    final rows = await readCliTranscriptOffThread(path, 'claudeCode');
    print(
      'BEFORE whole-file parse: ${sw.elapsedMilliseconds} ms, ${rows.length} rows',
    );
  }
  final tail = CliTranscriptTail(path, 'claudeCode');
  var sw = Stopwatch()..start();
  await tail.read();
  print(
    'AFTER first read (${tail.lastRead!.name}): ${sw.elapsedMilliseconds} ms',
  );

  var size = await file.length();
  final deadline = DateTime.now().add(window);
  var ticks = 0;
  while (DateTime.now().isBefore(deadline) && ticks < 20) {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final now = await file.length();
    if (now == size) continue;
    sw = Stopwatch()..start();
    await tail.read();
    print(
      'AFTER tick: +${now - size} B, ${tail.lastRead!.name}, ${sw.elapsedMicroseconds} us',
    );
    size = now;
    ticks++;
  }

  // Equivalence on real data, only when nothing was appended mid-comparison.
  for (var attempt = 0; attempt < 5; attempt++) {
    final before = await file.length();
    final incremental = await tail.read();
    final whole = await readCliTranscript(path, 'claudeCode');
    if (await file.length() != before) continue;
    print(
      'tail equals whole-file read: ${_equal(incremental, whole)} (${whole.length} rows)',
    );
    return;
  }
  print('tail equality not checked: the file kept moving');
}

String _pair(int i, int size) {
  final id = 'task_$i';
  return '${jsonEncode({
    'type': 'assistant',
    'timestamp': '2026-09-21T10:00:00.000Z',
    'message': {
      'content': [
        {'type': 'text', 'text': 'step $i'},
        {
          'type': 'tool_use',
          'id': id,
          'name': i % 10 == 0 ? 'Agent' : 'Bash',
          'input': {'command': 'echo $i'},
        },
      ],
    },
  })}\n${jsonEncode({
    'type': 'user',
    'timestamp': '2026-09-21T10:00:01.000Z',
    'message': {
      'role': 'user',
      'content': [
        {'type': 'tool_result', 'tool_use_id': id, 'content': 'r' * size},
      ],
    },
  })}\n';
}

bool _equal(List<TranscriptMessage> a, List<TranscriptMessage> b) {
  if (a.length != b.length) return false;
  String d(TranscriptMessage m) => [
    m.role,
    m.text,
    m.thinking,
    m.at,
    m.pendingToolUseId,
    m.pendingBackgroundAgentId,
    m.compaction?.trigger,
    m.compaction == null,
    m.tool?.name,
    m.tool?.subject,
    m.tool?.output,
    m.tool?.isError,
    m.tool?.outputTruncated,
    m.tool?.imagePath,
    m.subagent?.filePath,
    m.subagent?.toolUseId,
  ].map((v) => jsonEncode('$v')).join(',');
  for (var i = 0; i < a.length; i++) {
    if (d(a[i]) != d(b[i])) return false;
  }
  return true;
}
