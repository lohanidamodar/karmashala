import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';
import 'package:karmashala_terminal_runtime/instances.dart';

/// The engine maps host ids back to rows by recomputing the id a pane names its
/// session with; the two live in different packages and must not drift.
void main() {
  test('the engine names a host session as the pane does', () {
    for (final id in ['s1', 'abc-123_X', 'a.b:c/d eé', '']) {
      expect(
        hostSessionIdOf(id),
        hostSessionIdFor(paneId: 'p1', agentSessionId: id),
        reason: 'session id "$id"',
      );
    }
  });
}
