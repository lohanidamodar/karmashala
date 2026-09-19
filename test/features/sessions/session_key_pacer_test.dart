import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/sessions/application/session_key_pacer.dart';

void main() {
  test('one keystroke per write, the longer pause after Enter', () async {
    final writes = <String>[];
    final waits = <Duration>[];
    final pacer = SessionKeyPacer(
      press: (_, keys) {
        writes.add(keys);
        return true;
      },
      afterKey: const Duration(milliseconds: 1),
      afterEnter: const Duration(milliseconds: 9),
      wait: (d) async => waits.add(d),
    );

    expect(await pacer.type('s1', '\r\x1b[B\x1b[BDurian\r'), isTrue);

    expect(writes, ['\r', '\x1b[B', '\x1b[B', 'Durian', '\r']);
    expect(waits, [
      const Duration(milliseconds: 9),
      const Duration(milliseconds: 1),
      const Duration(milliseconds: 1),
      const Duration(milliseconds: 1),
      const Duration(milliseconds: 9),
    ]);
  });

  test('no pane: false, and nothing more is pressed', () async {
    var presses = 0;
    final pacer = SessionKeyPacer(
      press: (_, _) {
        presses++;
        return false;
      },
      wait: (_) async {},
    );

    expect(await pacer.type('s1', '\x1b[B\r'), isFalse);
    expect(presses, 1);
  });
}
