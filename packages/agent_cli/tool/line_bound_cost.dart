import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/src/util/bounded_lines.dart';
import 'package:agent_cli/read.dart';

/// Two questions the bound has to answer: does it cap peak memory on an
/// oversized record, and does it cost anything on an ordinary transcript?
Future<void> main() async {
  final dir = await Directory.systemTemp.createTemp('ks-bound-');

  // 1. Peak RSS with one enormous record, now that the bound is in.
  for (final mib in [64, 256]) {
    final f = File('${dir.path}/g$mib.jsonl');
    final sink = f.openWrite();
    sink.write(
      '{"type":"user","message":{"role":"user","content":"before"}}\n',
    );
    sink.write('{"type":"user","message":{"role":"user","content":"');
    final blob = 'x' * (1 << 20);
    for (var i = 0; i < mib; i++) {
      sink.write(blob);
    }
    sink.write('"}}\n');
    sink.write('{"type":"user","message":{"role":"user","content":"after"}}\n');
    await sink.flush();
    await sink.close();
    final sw = Stopwatch()..start();
    final rows = await readCliTranscript(f.path, 'claudeCode');
    sw.stop();
    print(
      'GIANT line=${mib}MiB ms=${sw.elapsedMilliseconds} rows=${rows.length} '
      'maxRss=${ProcessInfo.maxRss >> 20}MiB',
    );
    await f.delete();
  }

  // 2. Throughput on a transcript shaped like a real one: 27k records, a
  //    handful over 64 KiB, one near 1 MiB - the distribution measured here.
  final big = File('${dir.path}/real.jsonl');
  final sink = big.openWrite();
  var bytes = 0;
  for (var i = 0; i < 27000; i++) {
    final len = i % 250 == 0 ? 120000 : (i % 7 == 0 ? 6000 : 1200);
    final line = jsonEncode({
      'type': i.isEven ? 'user' : 'assistant',
      'timestamp': '2026-09-20T10:00:00.000Z',
      'message': i.isEven
          ? {'role': 'user', 'content': 'u${'a' * len}'}
          : {
              'content': [
                {'type': 'text', 'text': 'a${'b' * len}'},
              ],
            },
    });
    bytes += line.length + 1;
    sink.write('$line\n');
  }
  sink.write(
    '${jsonEncode({
      'type': 'user',
      'message': {'role': 'user', 'content': 'z' * 1050000},
    })}\n',
  );
  await sink.flush();
  await sink.close();
  print(
    'fixture bytes=${await big.length()} (~${(bytes / (1 << 20)).round()} MiB)',
  );

  for (var round = 0; round < 3; round++) {
    // the reader under test
    var sw = Stopwatch()..start();
    final rows = await readCliTranscript(big.path, 'claudeCode');
    sw.stop();
    final bounded = sw.elapsedMilliseconds;

    // the splitter alone, bounded vs LineSplitter, over the same file
    sw = Stopwatch()..start();
    var n = 0;
    await for (final l in boundedLines(big)) {
      n += l.length;
    }
    sw.stop();
    final boundedSplit = sw.elapsedMilliseconds;

    sw = Stopwatch()..start();
    var m = 0;
    await for (final l
        in big
            .openRead()
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
      m += l.length;
    }
    sw.stop();
    print(
      'round $round: readCliTranscript=${bounded}ms rows=${rows.length} | '
      'split bounded=${boundedSplit}ms chars=$n | '
      'LineSplitter=${sw.elapsedMilliseconds}ms chars=$m',
    );
  }
  await dir.delete(recursive: true);
}
