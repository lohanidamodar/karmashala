import 'dart:convert';

import 'package:chitragupta/src/core/util/json_object_splice.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('replaceTopLevelJsonValue', () {
    test('replaces an object value, preserving everything else verbatim', () {
      const raw =
          '{\n'
          '  "a": 1,\n'
          '  "oauthAccount": {"emailAddress": "old@x.com", "org": {"n": 1}},\n'
          '  "b": [1, 2, 3]\n'
          '}';
      final out = replaceTopLevelJsonValue(
        raw,
        'oauthAccount',
        jsonEncode({'emailAddress': 'new@y.com'}),
      );
      final decoded = jsonDecode(out) as Map<String, dynamic>;
      expect((decoded['oauthAccount'] as Map)['emailAddress'], 'new@y.com');
      expect(decoded['a'], 1);
      expect(decoded['b'], [1, 2, 3]);
      // Untouched regions are byte-identical.
      expect(out.startsWith('{\n  "a": 1,\n'), isTrue);
      expect(out.trimRight().endsWith('"b": [1, 2, 3]\n}'), isTrue);
    });

    test('preserves sibling keys that differ only by case', () {
      // A decode→encode round-trip would collapse these two into one.
      const raw =
          '{"g:/x": 1, "G:/x": 2, "oauthAccount": {"emailAddress": "a@b.com"}}';
      final out = replaceTopLevelJsonValue(
        raw,
        'oauthAccount',
        jsonEncode({'emailAddress': 'c@d.com'}),
      );
      expect(out.contains('"g:/x": 1'), isTrue);
      expect(out.contains('"G:/x": 2'), isTrue);
      expect(out.contains('"c@d.com"'), isTrue);
      expect(out.contains('"a@b.com"'), isFalse);
    });

    test('handles values with braces and the key name inside strings', () {
      const raw =
          '{"note": "has } and oauthAccount text", "oauthAccount": {"a": "}{"}}';
      final out = replaceTopLevelJsonValue(raw, 'oauthAccount', '{"a":"z"}');
      final decoded = jsonDecode(out) as Map<String, dynamic>;
      expect(decoded['note'], 'has } and oauthAccount text');
      expect((decoded['oauthAccount'] as Map)['a'], 'z');
    });

    test('inserts the key as the first property when absent', () {
      const raw = '{"a": 1}';
      final out = replaceTopLevelJsonValue(raw, 'oauthAccount', '{"e":"x"}');
      final decoded = jsonDecode(out) as Map<String, dynamic>;
      expect((decoded['oauthAccount'] as Map)['e'], 'x');
      expect(decoded['a'], 1);
    });

    test('inserts into an empty object', () {
      final out = replaceTopLevelJsonValue('{}', 'oauthAccount', '{"e":"x"}');
      final decoded = jsonDecode(out) as Map<String, dynamic>;
      expect((decoded['oauthAccount'] as Map)['e'], 'x');
    });

    test('throws when the root is not an object', () {
      expect(
        () => replaceTopLevelJsonValue('[1,2]', 'k', '1'),
        throwsFormatException,
      );
    });
  });
}
