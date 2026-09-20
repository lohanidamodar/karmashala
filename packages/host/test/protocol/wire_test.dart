import 'dart:typed_data';

import 'package:karmashala_host/karmashala_host.dart';
import 'package:test/test.dart';

void main() {
  group('WireWriter/WireReader', () {
    test('round-trips every primitive in order', () {
      final w = WireWriter()
        ..u8(0xfe)
        ..u16(0xbeef)
        ..u32(0xdeadbeef)
        ..u64(0x0102030405060708)
        ..boolean(true)
        ..boolean(false)
        ..str('kāla')
        ..strings(['/bin/sh', '-l'])
        ..map({'TERM': 'xterm-256color', 'HOME': '/root'})
        ..bytes(Uint8List.fromList([1, 2, 3]))
        ..rest(Uint8List.fromList([9, 9]));

      final r = WireReader(w.take());
      expect(r.u8(), 0xfe);
      expect(r.u16(), 0xbeef);
      expect(r.u32(), 0xdeadbeef);
      expect(r.u64(), 0x0102030405060708);
      expect(r.boolean(), isTrue);
      expect(r.boolean(), isFalse);
      expect(r.str(), 'kāla');
      expect(r.strings(), ['/bin/sh', '-l']);
      expect(r.map(), {'TERM': 'xterm-256color', 'HOME': '/root'});
      expect(r.bytes(), [1, 2, 3]);
      expect(r.rest(), [9, 9]);
      r.expectEnd();
    });

    test('a 64-bit offset survives, because a session outgrows 32 bits', () {
      const huge = 5 * 1024 * 1024 * 1024;
      final r = WireReader((WireWriter()..u64(huge)).take());
      expect(r.u64(), huge);
    });

    test('a truncated payload is an error, not a zero', () {
      final r = WireReader(Uint8List.fromList([0, 0]));
      expect(r.u32, throwsA(isA<WireFormatException>()));
    });

    test('a string longer than the payload is refused', () {
      final w = WireWriter()..u32(99);
      expect(WireReader(w.take()).str, throwsA(isA<WireFormatException>()));
    });

    test('trailing bytes are a version skew, not something to ignore', () {
      final r = WireReader(
        (WireWriter()
              ..u8(1)
              ..u8(2))
            .take(),
      );
      expect(r.u8(), 1);
      expect(r.expectEnd, throwsA(isA<WireFormatException>()));
    });

    test('an empty map and an empty list survive the round trip', () {
      final r = WireReader(
        (WireWriter()
              ..map({})
              ..strings([]))
            .take(),
      );
      expect(r.map(), isEmpty);
      expect(r.strings(), isEmpty);
      r.expectEnd();
    });
  });
}
