import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/sessions/application/server_session_notices.dart';
import 'package:karmashala/src/features/sessions/application/session_notice.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

import '../../support/fake_data_server.dart';
import '../../support/test_machine.dart';

/// What the server has to say of a session — an image a queued message or a
/// resume's first turn gave the agent as a path — lands on that session's
/// notice bar, whichever way the message went.
void main() {
  test('a notice the server tells is posted for its session', () async {
    final machine = TestMachine();
    final server = FakeDataServer()..runsOn(machine);
    final container = ProviderContainer(overrides: [await server.override()]);
    addTearDown(container.dispose);
    container.listen(serverSessionNoticesProvider, (_, _) {});

    server.writeAsAnotherClient([
      const SessionNoticed(
        sessionId: 's1',
        message: 'shot.png was sent as its path, not as an image.',
      ),
    ]);
    await Future<void>.delayed(Duration.zero);

    expect(
      container.read(sessionNoticesProvider)['s1']?.message,
      'shot.png was sent as its path, not as an image.',
    );
    expect(container.read(sessionNoticesProvider).containsKey('s2'), isFalse);
  });
}
