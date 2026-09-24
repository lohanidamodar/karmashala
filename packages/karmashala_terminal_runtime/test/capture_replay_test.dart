import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xterm2/xterm.dart';

/// Replays a session host's capture through the emulator panes use, applying
/// each recorded resize at the byte it took effect — the screen a pane drew
/// live, reproduced offline so a rendering fault can be studied rather than
/// guessed at. Runs only when `KARMASHALA_CAPTURE` names a host session folder
/// (`~/.karmashala/sessions/<id>`); writes `replay.txt` beside it.
void main() {
  final folder = Platform.environment['KARMASHALA_CAPTURE'];

  test(
    'a capture replays at the sizes it was written at',
    () {
      final dir = Directory(folder!);
      final meta =
          jsonDecode(File('${dir.path}/meta.json').readAsStringSync())
              as Map<String, Object?>;
      final first = (meta['firstOffset'] as num?)?.toInt() ?? 0;
      final bytes = File('${dir.path}/out.bin').readAsBytesSync();
      final log = File('${dir.path}/resizes.log');
      final sizes = log.existsSync()
          ? [
              for (final line in log.readAsLinesSync())
                if (line.trim().isNotEmpty)
                  [for (final n in line.trim().split(' ')) int.parse(n)],
            ]
          : [
              [
                first,
                (meta['columns'] as num).toInt(),
                (meta['rows'] as num).toInt(),
              ],
            ];

      final terminal = Terminal(maxLines: 100000);
      final decoder = utf8.decoder.startChunkedConversion(
        StringConversionSink.withCallback(terminal.write),
      );
      var at = first;
      for (var i = 0; i < sizes.length; i++) {
        final [offset, columns, rows] = sizes[i];
        final until = i + 1 < sizes.length
            ? sizes[i + 1][0]
            : first + bytes.length;
        if (offset > at) {
          decoder.add(bytes.sublist(at - first, offset - first));
          at = offset;
        }
        terminal.resize(columns, rows);
        if (until > at) {
          decoder.add(bytes.sublist(at - first, until - first));
          at = until;
        }
      }
      decoder.close();

      final lines = terminal.mainBuffer.lines;
      final text = [
        for (var i = 0; i < lines.length; i++) lines[i].toString().trimRight(),
      ].join('\n');
      File('${dir.path}/replay.txt').writeAsStringSync(text);
      // ignore: avoid_print
      print(
        '${bytes.length} bytes, ${sizes.length} size(s), '
        '${lines.length} rows → ${dir.path}/replay.txt',
      );
    },
    skip: folder == null
        ? 'set KARMASHALA_CAPTURE to a session host folder to replay it'
        : null,
  );
}
