import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/data/metadata_keys.dart';

import '../../support/fake_data_server.dart';

void main() {
  group('bootstrapMetadata', () {
    test('marks the first run, once', () {
      final preferences = FakeDataServer().store;
      expect(bootstrapMetadata(preferences), isTrue);
      final firstRunAt = preferences.read(MetadataKeys.firstRunAt);
      expect(firstRunAt, isNotNull);
      expect(
        preferences.read(MetadataKeys.environmentHealthOnboarding),
        'pending',
      );

      expect(bootstrapMetadata(preferences), isFalse);
      // The original first-run timestamp is preserved.
      expect(preferences.read(MetadataKeys.firstRunAt), firstRunAt);
    });
  });
}
