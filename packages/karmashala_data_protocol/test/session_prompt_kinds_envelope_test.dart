import 'dart:convert';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:test/test.dart';

/// Whether a session's agent takes images in a prompt crosses the wire.
void main() {
  Map<String, Object?> wire(Object? json) =>
      (jsonDecode(jsonEncode(json)) as Map).cast<String, Object?>();

  for (final images in [true, false]) {
    test('sessionPromptKindsChanged carries images: $images', () {
      final change = SessionPromptKindsChanged(
        sessionId: 's1',
        images: images,
      );
      final read = DataChange.fromJson(wire(change.toJson()));
      expect(read, isA<SessionPromptKindsChanged>());
      read as SessionPromptKindsChanged;
      expect(read.sessionId, 's1');
      expect(read.images, images);
    });
  }
}
