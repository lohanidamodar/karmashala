import 'dart:math';

import 'package:chitragupta/src/core/util/id_generator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RandomIdGenerator', () {
    test('produces RFC-4122 v4 formatted ids', () {
      final id = RandomIdGenerator(Random(1)).newId();
      final pattern = RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
      );
      expect(pattern.hasMatch(id), isTrue, reason: id);
    });

    test('produces distinct ids across many calls', () {
      final gen = RandomIdGenerator(Random(42));
      final ids = {for (var i = 0; i < 1000; i++) gen.newId()};
      expect(ids.length, 1000);
    });
  });
}
