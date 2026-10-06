import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/logging/server_log_tail.dart';
import 'package:karmashala_core/logging.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import '../../support/temp_directory.dart';

/// The Logs tab's Server source: `server.log` read back into the rows the App
/// source shows, so its filters mean the same thing.
void main() {
  late Directory dir;
  late File file;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('server_log_tail');
    file = File(p.join(dir.path, 'logs', 'server.log'));
  });
  tearDown(() => removeTempDirectory(dir));

  LogEntry entry(int sequence, Level level, String channel, String message) =>
      LogEntry(
        sequence: sequence,
        time: DateTime(2026, 10, 6, 9, 30, 1, 250),
        level: level,
        channel: channel,
        message: message,
      );

  test('a missing file reads as null, not as an empty log', () async {
    expect(await ServerLogTail(file).read(), isNull);
  });

  test('reads the lines the server writes back as entries', () async {
    file
      ..createSync(recursive: true)
      ..writeAsStringSync(
        [
          entry(0, Level.INFO, 'stdout', 'listening on 7420'),
          entry(1, Level.WARNING, 'stderr', 'relay: retrying'),
        ].map((e) => '${e.format(withDate: true)}\n').join(),
      );

    final entries = (await ServerLogTail(file).read())!;

    expect(entries.map((e) => e.channel), ['stdout', 'stderr']);
    expect(entries.map((e) => e.message), [
      'listening on 7420',
      'relay: retrying',
    ]);
    expect(entries.map((e) => e.level), [Level.INFO, Level.WARNING]);
    expect(entries.first.timestamp, '09:30:01.250');
  });

  test('a line that is not an entry belongs to the one above it', () async {
    file
      ..createSync(recursive: true)
      ..writeAsStringSync(
        '${entry(0, Level.SEVERE, 'serve', 'crashed').format(withDate: true)}'
        '\n#0 main (serve.dart:1)\n',
      );

    final entries = (await ServerLogTail(file).read())!;

    expect(entries, hasLength(1));
    expect(entries.single.message, 'crashed\n#0 main (serve.dart:1)');
  });

  test('reads only the end of a long file, from a whole line', () async {
    file.createSync(recursive: true);
    file.writeAsStringSync(
      [
        for (var i = 0; i < 2000; i++)
          entry(i, Level.INFO, 'stdout', 'line $i').format(withDate: true),
      ].join('\n'),
    );

    final entries = (await ServerLogTail(file, maxBytes: 4096).read())!;

    expect(entries.last.message, 'line 1999');
    expect(entries.length, lessThan(2000));
    // The cut lands mid-line; that fragment is not shown as an entry.
    expect(entries.first.message, matches(RegExp(r'^line \d+$')));
    expect(entries.first.channel, 'stdout');
  });

  test('an unchanged file is not read again', () async {
    file
      ..createSync(recursive: true)
      ..writeAsStringSync(
        '${entry(0, Level.INFO, 'a', 'one').format(withDate: true)}\n',
      );
    final tail = ServerLogTail(file);

    final first = await tail.read();
    final second = await tail.read();
    expect(identical(first, second), isTrue);

    file.writeAsStringSync(
      '${entry(1, Level.INFO, 'a', 'two').format(withDate: true)}\n',
      mode: FileMode.append,
    );
    final third = (await tail.read())!;
    expect(third.last.message, 'two');
  });
}
