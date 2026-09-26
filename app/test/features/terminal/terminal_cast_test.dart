import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_terminal_runtime/recording.dart';
import 'package:karmashala_terminal_core/cast.dart';

/// A clock a test drives by hand, because a recording is about time and a test
/// that read a real one would assert on how long it took to run.
class _ManualClock {
  Duration now = Duration.zero;
  Duration read() => now;
  void advance(Duration by) => now += by;
}

Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));

void main() {
  group('CastRecorder', () {
    test('stamps each chunk with when it arrived', () {
      final clock = _ManualClock();
      final recorder = CastRecorder(columns: 80, rows: 24, clock: clock.read);

      recorder.addOutput(_bytes('hello'));
      clock.advance(const Duration(milliseconds: 1500));
      recorder.addOutput(_bytes(' world'));

      final cast = recorder.stop();
      expect(cast.events, hasLength(2));
      expect(cast.events[0].at, Duration.zero);
      expect(cast.events[0].data, 'hello');
      expect(cast.events[1].at, const Duration(milliseconds: 1500));
      expect(cast.events[1].data, ' world');
      expect(cast.duration, const Duration(milliseconds: 1500));
    });

    test('holds back a codepoint split across two reads', () {
      final recorder = CastRecorder(columns: 80, rows: 24);
      // U+2713 CHECK MARK is three bytes; hand over two of them, then the third
      // — which is what a 1 KB PTY read does at a chunk boundary.
      final full = _bytes('✓');
      recorder.addOutput(Uint8List.fromList(full.sublist(0, 2)));
      expect(recorder.eventCount, 0, reason: 'nothing decodable yet');
      recorder.addOutput(Uint8List.fromList(full.sublist(2)));

      final cast = recorder.stop();
      expect(cast.events.single.data, '✓');
    });

    test('records a resize as its own event and skips a no-op one', () {
      final clock = _ManualClock();
      final recorder = CastRecorder(columns: 80, rows: 24, clock: clock.read);

      recorder.addResize(80, 24); // already the grid — nothing happened
      clock.advance(const Duration(seconds: 1));
      recorder.addResize(120, 40);
      recorder.addResize(120, 40);

      final cast = recorder.stop();
      expect(cast.events, hasLength(1));
      expect(cast.events.single.kind, CastEventKind.resize);
      expect(cast.events.single.data, '120x40');
      expect(cast.events.single.grid, (columns: 120, rows: 40));
      expect(cast.events.single.at, const Duration(seconds: 1));
    });

    test('widestGrid frames for the largest the grid ever was', () {
      final recorder = CastRecorder(columns: 80, rows: 24);
      recorder.addResize(200, 10);
      recorder.addResize(60, 50);

      final cast = recorder.stop();
      expect(cast.widestGrid, (columns: 200, rows: 50));
    });

    test('stops adding at the byte cap and says it was truncated', () {
      final recorder = CastRecorder(columns: 80, rows: 24, maxBytes: 8);
      recorder.addOutput(_bytes('12345'));
      recorder.addOutput(_bytes('67890'));

      final cast = recorder.stop();
      expect(cast.events, hasLength(1));
      expect(cast.truncated, isTrue);
      expect(recorder.isTruncated, isTrue);
    });

    test('ignores output arriving after stop', () {
      final recorder = CastRecorder(columns: 80, rows: 24);
      final cast = recorder.stop();
      recorder.addOutput(_bytes('late'));

      expect(cast.events, isEmpty);
      expect(recorder.snapshot().events, isEmpty);
    });
  });

  group('asciicast v2', () {
    test('round-trips output and resize through the documented format', () {
      final cast = TerminalCast(
        columns: 80,
        rows: 24,
        recordedAt: DateTime.utc(2026, 9, 8, 10, 30),
        title: 'pwsh',
        events: [
          const CastEvent.output(Duration.zero, 'PS> '),
          CastEvent.resize(const Duration(milliseconds: 250), 120, 40),
          const CastEvent.output(Duration(milliseconds: 1250), 'ok\r\n'),
        ],
      );

      final decoded = decodeCast(encodeCast(cast));
      expect(decoded.columns, 80);
      expect(decoded.rows, 24);
      expect(decoded.title, 'pwsh');
      expect(decoded.recordedAt, DateTime.utc(2026, 9, 8, 10, 30));
      expect(decoded.events.map((e) => e.kind), [
        CastEventKind.output,
        CastEventKind.resize,
        CastEventKind.output,
      ]);
      expect(decoded.events.map((e) => e.at), [
        Duration.zero,
        const Duration(milliseconds: 250),
        const Duration(milliseconds: 1250),
      ]);
      expect(decoded.events.last.data, 'ok\r\n');
    });

    test('header is one JSON object and every event one JSON array', () {
      final text = encodeCast(
        TerminalCast(
          columns: 80,
          rows: 24,
          recordedAt: DateTime.utc(2026, 1, 1),
          events: const [CastEvent.output(Duration(seconds: 2), 'hi')],
        ),
      );
      final lines = const LineSplitter().convert(text);
      expect(lines, hasLength(2));
      expect(jsonDecode(lines[0]), {
        'version': 2,
        'width': 80,
        'height': 24,
        'timestamp': DateTime.utc(2026, 1, 1).millisecondsSinceEpoch ~/ 1000,
      });
      expect(jsonDecode(lines[1]), [2, 'o', 'hi']);
    });

    test('skips event kinds this app does not model', () {
      final text = [
        '{"version":2,"width":80,"height":24,"timestamp":0}',
        '[0.5,"i","ls\\r"]',
        '[0.6,"o","ls\\r\\n"]',
        '[0.7,"m","chapter"]',
        '',
      ].join('\n');

      final cast = decodeCast(text);
      expect(cast.events, hasLength(1));
      expect(cast.events.single.kind, CastEventKind.output);
    });

    test('refuses a version it cannot read', () {
      expect(
        () => decodeCast('{"version":3,"width":80,"height":24}'),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
