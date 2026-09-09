import 'package:karmashala_core/logging.dart';
import 'package:test/test.dart';
import 'package:logging/logging.dart';

LogEntry entry(int i, {Level level = Level.INFO, String channel = 'test'}) =>
    LogEntry(
      sequence: i,
      time: DateTime.utc(2026, 8, 31, 12, 0, 0).add(Duration(milliseconds: i)),
      level: level,
      channel: channel,
      message: 'line $i',
    );

void main() {
  group('LogRingBuffer', () {
    test('holds what it is given, oldest first', () {
      final buffer = LogRingBuffer(capacity: 1000);
      for (var i = 0; i < 5; i++) {
        buffer.add(entry(i));
      }
      expect(buffer.snapshot().map((e) => e.message), [
        'line 0',
        'line 1',
        'line 2',
        'line 3',
        'line 4',
      ]);
      expect(buffer.length, 5);
      expect(buffer.dropped, 0);
    });

    test('the bound evicts the oldest', () {
      final buffer = LogRingBuffer(capacity: kMinLogBufferCapacity);
      for (var i = 0; i < kMinLogBufferCapacity + 50; i++) {
        buffer.add(entry(i));
      }
      final held = buffer.snapshot();
      expect(held, hasLength(kMinLogBufferCapacity));
      expect(held.first.message, 'line 50');
      expect(held.last.message, 'line ${kMinLogBufferCapacity + 49}');
      expect(buffer.dropped, 50);
    });

    test('capacity is clamped to something usable', () {
      expect(LogRingBuffer(capacity: 1).capacity, kMinLogBufferCapacity);
      expect(LogRingBuffer(capacity: 1 << 30).capacity, kMaxLogBufferCapacity);
    });

    test(
      'revision counts every record, so a UI can poll instead of listen',
      () {
        final buffer = LogRingBuffer(capacity: kMinLogBufferCapacity);
        expect(buffer.revision, 0);
        for (var i = 0; i < kMinLogBufferCapacity * 2; i++) {
          buffer.add(entry(i));
        }
        expect(buffer.revision, kMinLogBufferCapacity * 2);
      },
    );

    test('tail returns the newest n, oldest first', () {
      final buffer = LogRingBuffer(capacity: 1000);
      for (var i = 0; i < 10; i++) {
        buffer.add(entry(i));
      }
      expect(buffer.tail(3).map((e) => e.message), [
        'line 7',
        'line 8',
        'line 9',
      ]);
      expect(buffer.tail(100), hasLength(10));
    });

    test('shrinking keeps the newest records and stays consistent', () {
      final buffer = LogRingBuffer(capacity: 1000);
      for (var i = 0; i < 900; i++) {
        buffer.add(entry(i));
      }
      buffer.resize(kMinLogBufferCapacity);
      expect(buffer.capacity, kMinLogBufferCapacity);
      expect(buffer.length, kMinLogBufferCapacity);
      expect(buffer.snapshot().last.message, 'line 899');
      // The ring must keep working after the resize, not just read correctly.
      for (var i = 900; i < 900 + kMinLogBufferCapacity; i++) {
        buffer.add(entry(i));
      }
      expect(buffer.snapshot().first.message, 'line 900');
      expect(
        buffer.snapshot().last.message,
        'line ${899 + kMinLogBufferCapacity}',
      );
    });

    test('growing keeps everything it held', () {
      final buffer = LogRingBuffer(capacity: kMinLogBufferCapacity);
      for (var i = 0; i < kMinLogBufferCapacity; i++) {
        buffer.add(entry(i));
      }
      buffer.resize(1000);
      expect(buffer.length, kMinLogBufferCapacity);
      expect(buffer.snapshot().first.message, 'line 0');
      buffer.add(entry(9999));
      expect(buffer.snapshot().last.message, 'line 9999');
    });

    test('clear empties the ring but keeps the revision moving', () {
      final buffer = LogRingBuffer(capacity: 1000);
      for (var i = 0; i < 5; i++) {
        buffer.add(entry(i));
      }
      final before = buffer.revision;
      buffer.clear();
      expect(buffer.snapshot(), isEmpty);
      expect(buffer.revision, greaterThan(before));
    });
  });

  group('LogEntry', () {
    test('formats a panel line', () {
      final line = LogEntry(
        sequence: 0,
        time: DateTime(2026, 8, 31, 12, 4, 31, 907),
        level: Level.WARNING,
        channel: 'remote',
        message: 'pairing failed',
        error: 'timeout',
      ).format();
      expect(line, '12:04:31.907 W remote: pairing failed | error=timeout');
    });

    test('the file line carries the day too', () {
      final line = LogEntry(
        sequence: 0,
        time: DateTime(2026, 8, 31, 12, 4, 31, 907),
        level: Level.INFO,
        channel: 'bootstrap',
        message: 'Starting Karmashala.',
      ).format(withDate: true);
      expect(line, startsWith('2026-08-31 12:04:31.907 I bootstrap:'));
    });
  });
}
