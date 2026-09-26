import 'dart:async';
import 'dart:io';

import 'package:karmashala_host/src/serve/surviving_sink.dart';
import 'package:test/test.dart';

/// A pipe whose reader has gone: every write fails, as stdout does once the
/// app that started the host has quit.
class _BrokenPipe implements StreamConsumer<List<int>> {
  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await stream.first;
    throw const SocketException(
      'Write failed',
      osError: OSError('Broken pipe', 32),
    );
  }

  @override
  Future<void> close() async {}
}

/// Runs [body] and returns the errors nobody handled — each one, in the
/// daemon's root zone, the end of its main isolate.
Future<List<Object>> _unhandled(Future<void> Function() body) async {
  final errors = <Object>[];
  final done = Completer<void>();
  unawaited(
    runZonedGuarded(() async {
      await body();
      // Long enough for a failed write to reach `done`.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      done.complete();
    }, (error, _) => errors.add(error)),
  );
  await done.future;
  return errors;
}

void main() {
  test('a bare sink over a broken pipe raises an error nobody handles — what '
      'killed the host on 2026-09-25', () async {
    final errors = await _unhandled(() async {
      IOSink(_BrokenPipe()).writeln('automations: run r1 is blocked');
    });
    expect(errors, isNotEmpty);
  });

  test('the surviving sink drops the line and everything after, and raises '
      'nothing', () async {
    late SurvivingSink sink;
    final errors = await _unhandled(() async {
      sink = SurvivingSink(IOSink(_BrokenPipe()))
        ..writeln('automations: run r1 is blocked');
      await sink.flush();
      sink
        ..writeln('and another')
        ..write('and more')
        ..add(const [1, 2, 3]);
      await sink.flush();
      await sink.done;
      await sink.close();
    });
    expect(errors, isEmpty);
    expect(sink.lost, isTrue);
  });

  test('while its reader is there, every line gets through', () async {
    final lines = <List<int>>[];
    final controller = StreamController<List<int>>();
    controller.stream.listen(lines.add);
    final sink = SurvivingSink(IOSink(controller.sink))
      ..writeln('serving')
      ..writeln('restored 0 session(s)');
    await sink.flush();
    await sink.close();
    expect(
      String.fromCharCodes(lines.expand((l) => l)),
      'serving\nrestored 0 session(s)\n',
    );
    expect(sink.lost, isFalse);
  });
}
