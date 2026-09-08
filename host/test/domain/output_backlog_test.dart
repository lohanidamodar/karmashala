import 'dart:typed_data';

import 'package:karmashala_host/karmashala_host.dart';
import 'package:test/test.dart';

Uint8List bytes(List<int> values) => Uint8List.fromList(values);
Uint8List filled(int count, int value) => Uint8List(count)..fillRange(0, count, value);

void main() {
  group('OutputBacklog', () {
    test('starts empty and answers nothing at offset zero', () {
      final backlog = OutputBacklog(capacityBytes: 16);
      expect(backlog.totalBytes, 0);
      expect(backlog.firstAvailableOffset, 0);
      final slice = backlog.since(0);
      expect(slice.isEmpty, isTrue);
      expect(slice.offset, 0);
      expect(slice.droppedBytes, 0);
    });

    test('offsets are absolute byte counts across many writes', () {
      final backlog = OutputBacklog(capacityBytes: 64);
      backlog.add(bytes([1, 2, 3]));
      backlog.add(bytes([4, 5]));
      backlog.add(bytes([6]));

      expect(backlog.totalBytes, 6);
      expect(backlog.since(0).bytes, [1, 2, 3, 4, 5, 6]);
      expect(backlog.since(3).bytes, [4, 5, 6]);
      expect(backlog.since(3).offset, 3);
      expect(backlog.since(6).isEmpty, isTrue);
    });

    test('wraps without losing order once the ring is full', () {
      final backlog = OutputBacklog(capacityBytes: 8);
      for (var i = 1; i <= 12; i++) {
        backlog.add(bytes([i]));
      }

      expect(backlog.totalBytes, 12);
      expect(backlog.firstAvailableOffset, 4);
      expect(backlog.heldBytes, 8);
      expect(backlog.since(4).bytes, [5, 6, 7, 8, 9, 10, 11, 12]);
    });

    test('a chunk straddling the wrap comes back contiguous', () {
      final backlog = OutputBacklog(capacityBytes: 8);
      backlog.add(bytes([1, 2, 3, 4, 5, 6]));
      backlog.add(bytes([7, 8, 9, 10]));

      expect(backlog.totalBytes, 10);
      expect(backlog.since(2).bytes, [3, 4, 5, 6, 7, 8, 9, 10]);
    });

    test('an offset older than the ring is clamped and the shortfall reported', () {
      final backlog = OutputBacklog(capacityBytes: 8);
      backlog.add(filled(20, 7));

      final slice = backlog.since(0);
      expect(slice.droppedBytes, 12);
      expect(slice.offset, 12);
      expect(slice.bytes, hasLength(8));
      expect(slice.nextOffset, 20);
    });

    test('a chunk larger than the ring keeps only its tail', () {
      final backlog = OutputBacklog(capacityBytes: 4);
      backlog.add(bytes([1, 2, 3, 4, 5, 6, 7, 8, 9]));

      expect(backlog.totalBytes, 9);
      expect(backlog.firstAvailableOffset, 5);
      expect(backlog.since(0).bytes, [6, 7, 8, 9]);
      expect(backlog.since(0).droppedBytes, 5);
    });

    test('an offset ahead of what exists yields nothing rather than guessing', () {
      final backlog = OutputBacklog(capacityBytes: 16);
      backlog.add(bytes([1, 2, 3]));

      final slice = backlog.since(99);
      expect(slice.isEmpty, isTrue);
      expect(slice.offset, 3, reason: 'the client is told where the host really is');
      expect(slice.droppedBytes, 0);
    });

    test('holds a realistic 4 MiB without growing past it', () {
      final backlog = OutputBacklog();
      final megabyte = filled(1024 * 1024, 65);
      for (var i = 0; i < 6; i++) {
        backlog.add(megabyte);
      }

      expect(backlog.totalBytes, 6 * 1024 * 1024);
      expect(backlog.heldBytes, OutputBacklog.defaultCapacityBytes);
      expect(backlog.firstAvailableOffset, 2 * 1024 * 1024);
      expect(backlog.since(0).bytes, hasLength(OutputBacklog.defaultCapacityBytes));
    });
  });

  group('restored from a record', () {
    test('keeps the absolute numbering the session really had', () {
      // A session that produced 40_000 bytes and kept the last 10: the two
      // numbers are separately true, and a restarted host that reset the total
      // would hand every client an offset from a different numbering.
      final backlog = OutputBacklog.restored(
        capacityBytes: 16,
        totalBytes: 40000,
        tail: filled(10, 90),
      );

      expect(backlog.totalBytes, 40000);
      expect(backlog.heldBytes, 10);
      expect(backlog.firstAvailableOffset, 39990);
      expect(backlog.since(39990).bytes, hasLength(10));
      expect(backlog.since(39995).offset, 39995);
      expect(backlog.since(39995).bytes, hasLength(5));
    });

    test('tells a client from before the bound how much it lost', () {
      final backlog = OutputBacklog.restored(
        capacityBytes: 16,
        totalBytes: 1000,
        tail: filled(16, 65),
      );
      final slice = backlog.since(0);
      expect(slice.droppedBytes, 984);
      expect(slice.offset, 984);
      expect(slice.bytes, hasLength(16));
    });

    test('carries on from where the record left off', () {
      final backlog = OutputBacklog.restored(
        capacityBytes: 16,
        totalBytes: 100,
        tail: filled(4, 65),
      )..add(filled(3, 66));

      expect(backlog.totalBytes, 103);
      expect(backlog.since(96).bytes, hasLength(7));
    });
  });
}
