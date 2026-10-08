import 'dart:convert';

import 'package:karmashala_host/src/domain/input_line.dart';
import 'package:karmashala_host/src/sessions/session_input.dart'
    show heldTypedInput;
import 'package:test/test.dart';

void main() {
  group('InputLine', () {
    test('follows printable text and Backspace, and Enter sends it', () {
      final line = InputLine()..typed(utf8.encode('fix the cartx'));
      line.typed([0x7f]);
      expect(line.unsent, 'fix the cart');
      line.typed([0x0d]);
      expect(line.unsent, isEmpty);
    });

    test('skips cursor keys and keeps a bracketed paste', () {
      final line = InputLine()
        ..typed(utf8.encode('a\x1b[Db'))
        ..typed(utf8.encode('\x1b[200~pasted\x1b[201~'));
      expect(line.unsent, 'abpasted');
    });

    test('Ctrl+C and Ctrl+U clear it; a Return the server types sends it', () {
      final line = InputLine()..typed(utf8.encode('one'));
      line.typed([0x03]);
      expect(line.unsent, isEmpty);
      line
        ..typed(utf8.encode('two'))
        ..typedByServer(utf8.encode('message\r'));
      expect(line.unsent, isEmpty);
    });
  });

  group('heldTypedInput', () {
    const markers = ['❯'];
    List<String> screen(String field) => [
      '● Done.',
      '─' * 40,
      field.isEmpty ? '❯' : '❯ $field',
      '─' * 40,
    ];

    test('holds while the composer still shows what was typed', () {
      expect(
        heldTypedInput(
          'please also check the totals',
          rows: screen('please also check the totals'),
          markers: markers,
        ),
        'please also check the totals',
      );
    });

    test('lets go once the composer is empty, or cannot be read', () {
      expect(
        heldTypedInput('typed', rows: screen(''), markers: markers),
        isNull,
      );
      expect(
        heldTypedInput('typed', rows: screen('typed'), markers: null),
        isNull,
      );
      expect(
        heldTypedInput('   ', rows: screen('typed'), markers: markers),
        isNull,
      );
    });
  });
}
