import 'dart:io';

import 'package:chitragupta/src/core/logging/app_logger.dart';
import 'package:chitragupta/src/core/logging/diagnostics.dart';
import 'package:chitragupta/src/core/logging/log_entry.dart';
import 'package:chitragupta/src/core/logging/log_file_sink.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';

LogEntry entry(
  String message, {
  Level level = Level.INFO,
  String channel = 'test',
}) => LogEntry(
  sequence: 0,
  time: DateTime(2026, 8, 31, 12, 0, 0),
  level: level,
  channel: channel,
  message: message,
);

void main() {
  late Directory dir;
  late Diagnostics previous;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('chitragupta-logs');
    previous = Diagnostics.instance;
  });
  tearDown(() async {
    Diagnostics.instance = previous;
    Logger.root.level = Level.INFO;
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  group('LogFileSink', () {
    test('writes readable, dated lines', () async {
      final sink = LogFileSink(directory: dir);
      sink
        ..add(entry('first'))
        ..add(entry('second', level: Level.WARNING, channel: 'remote'));
      await sink.flush();

      final text = await sink.file.readAsString();
      expect(text, contains('2026-08-31 12:00:00.000 I test: first'));
      expect(text, contains('2026-08-31 12:00:00.000 W remote: second'));
      expect(text.trim().split('\n'), hasLength(2));
    });

    test('add does no I/O — nothing is on disk until the flush', () async {
      final sink = LogFileSink(directory: dir);
      sink.add(entry('queued'));
      // The caller's stack is done; the file has not even been created.
      expect(sink.file.existsSync(), isFalse);
      await sink.flush();
      expect(sink.file.existsSync(), isTrue);
    });

    test('records below the floor are not written', () async {
      final sink = LogFileSink(directory: dir, minimumLevel: Level.WARNING);
      sink
        ..add(entry('chatter'))
        ..add(entry('trouble', level: Level.SEVERE));
      await sink.flush();

      final text = await sink.file.readAsString();
      expect(text, isNot(contains('chatter')));
      expect(text, contains('trouble'));
    });

    test('rotates, keeping a bounded number of files', () async {
      final sink = LogFileSink(directory: dir, maxBytes: 200, keep: 3);
      for (var i = 0; i < 40; i++) {
        sink.add(entry('line $i padded out to make the file grow quickly'));
        await sink.flush();
      }

      final names = dir.listSync().map((e) => e.uri.pathSegments.last).toList()
        ..sort();
      expect(names, [
        'chitragupta.1.log',
        'chitragupta.2.log',
        'chitragupta.log',
      ]);
      // The live file holds the newest line; the oldest have been rolled off.
      expect(await sink.file.readAsString(), contains('line 39'));
      expect(await sink.files(), hasLength(3));
    });

    test(
      'a directory that cannot be written does not reach the caller',
      () async {
        final sink = LogFileSink(
          directory: Directory('/proc/definitely-not-writable/logs'),
        );
        expect(() => sink.add(entry('anything')), returnsNormally);
        await sink.flush();
        expect(sink.lastError, isNotNull);
        // And logging carries on afterwards.
        expect(() => sink.add(entry('still here')), returnsNormally);
      },
    );

    test('the queue is bounded when the disk stops answering', () {
      final sink = LogFileSink(
        directory: Directory('/proc/definitely-not-writable/logs'),
        maxPending: 10,
        flushInterval: const Duration(hours: 1),
      );
      for (var i = 0; i < 100; i++) {
        sink.add(entry('line $i'));
      }
      expect(sink.droppedPending, 90);
    });
  });

  group('Diagnostics with a file', () {
    test('a token never reaches the file', () async {
      const token = 'sk-ant-api03-Zx9Qw8Lm2Nv4Bt7Rk1Cy6Hd0Sf3Jg5Pu-AA';
      const hostKey =
          'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH4tFbGqDLrRcYqPZ0mQeRs7WvKjBn';
      final sink = LogFileSink(directory: dir);
      final diagnostics = Diagnostics(echoToConsole: false, file: sink);
      Diagnostics.instance = diagnostics;
      AppLogger.initialize(level: Level.ALL);

      AppLogger.named('claude-auth').warning('refresh failed for $token');
      AppLogger.named('ssh.hostkey').warning('mismatch $hostKey');
      AppLogger.named('remote').warning(r'reading C:\Users\dlohani\.ssh');
      await sink.flush();

      final text = await sink.file.readAsString();
      expect(text, isNot(contains(token)));
      expect(text, isNot(contains('AAAAC3NzaC1lZDI1NTE5')));
      expect(text, isNot(contains('dlohani')));
      expect(text, contains('[redacted:token]'));
      expect(text, contains('[redacted:key]'));
    });

    test(
      'attaching backfills what was logged before the file opened',
      () async {
        final diagnostics = Diagnostics(echoToConsole: false);
        Diagnostics.instance = diagnostics;
        AppLogger.initialize(level: Level.ALL);
        AppLogger.named('bootstrap').info('Starting Chitragupta.');

        final sink = LogFileSink(directory: dir);
        diagnostics.attachFile(sink);
        await sink.flush();

        expect(
          await sink.file.readAsString(),
          contains('Starting Chitragupta.'),
        );
      },
    );
  });
}
