import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/read.dart';

/// Measures what one oversized JSONL record costs `readCliTranscript`:
/// wall time and peak RSS, for a line of N MiB.
Future<void> main(List<String> args) async {
  final dir = await Directory.systemTemp.createTemp('ks-giant-');
  for (final mib in [1, 16, 64, 128, 256]) {
    final f = File('${dir.path}/t$mib.jsonl');
    final sink = f.openWrite();
    // Two ordinary rows, then one enormous user turn, then one more row.
    sink.write(
      '${jsonEncode({
        'type': 'user',
        'message': {'role': 'user', 'content': 'before'},
      })}\n',
    );
    sink.write('{"type":"user","message":{"role":"user","content":"');
    const chunk = 1 << 20;
    final blob = 'x' * chunk;
    for (var i = 0; i < mib; i++) {
      sink.write(blob);
    }
    sink.write('"}}\n');
    sink.write(
      '${jsonEncode({
        'type': 'user',
        'message': {'role': 'user', 'content': 'after'},
      })}\n',
    );
    await sink.flush();
    await sink.close();

    final rss0 = ProcessInfo.currentRss;
    final sw = Stopwatch()..start();
    List<dynamic> rows;
    String? failure;
    try {
      rows = await readCliTranscript(f.path, 'claudeCode');
    } catch (e) {
      rows = const [];
      failure = e.runtimeType.toString();
    }
    sw.stop();
    final peak = ProcessInfo.maxRss;
    print(
      'line=${mib}MiB fileBytes=${await f.length()} '
      'ms=${sw.elapsedMilliseconds} rows=${rows.length} '
      'rssBefore=${rss0 >> 20}MiB maxRss=${peak >> 20}MiB '
      'textLenOfBigRow=${rows.length >= 2 ? (rows[1] as TranscriptMessage).text.length : null} '
      'failure=$failure',
    );
    await f.delete();
  }
  await dir.delete(recursive: true);
}
