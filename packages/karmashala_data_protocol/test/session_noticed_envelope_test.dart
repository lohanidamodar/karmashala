import 'dart:convert';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:test/test.dart';

/// A sentence the server has for whoever watches a session crosses whole.
void main() {
  test('sessionNoticed carries the session and the words', () {
    const change = SessionNoticed(
      sessionId: 's1',
      message: 'shot.png was sent as its path, not as an image.',
    );
    final read = DataChange.fromJson(
      (jsonDecode(jsonEncode(change.toJson())) as Map).cast<String, Object?>(),
    );
    expect(read, isA<SessionNoticed>());
    read as SessionNoticed;
    expect(read.sessionId, 's1');
    expect(read.message, change.message);
  });
}
