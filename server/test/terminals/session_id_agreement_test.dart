import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';
import 'package:test/test.dart';

/// The engine maps host ids back to rows by recomputing the id an agent
/// pane's terminal runs under (`terminalSessionId`); the two live in
/// different packages and must not drift.
void main() {
  test('the engine names a host session as the terminals do', () {
    for (final id in ['s1', 'abc-123_X', 'a.b:c/d eé', '']) {
      expect(
        hostSessionIdOf(id),
        terminalSessionId(paneId: 'p1', agentSessionId: id),
        reason: 'session id "$id"',
      );
    }
  });
}
