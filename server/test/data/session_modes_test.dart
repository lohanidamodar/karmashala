import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/data.dart';
import 'package:karmashala_host/src/sessions/session_modes.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

/// `sessions.setMode` reaches the one seam the ACP runtime implements, and
/// says in words why nothing can be set until it does.
class _RecordingModes implements SessionModeChanger {
  final set = <(String, String)>[];

  @override
  Future<void> setMode(String sessionId, String modeId) async {
    set.add((sessionId, modeId));
  }
}

void main() {
  late AppDatabase db;
  late DataService service;

  setUp(() {
    db = AppDatabase.memory();
    service = DataService(db, clock: () => DateTime.utc(2026, 10, 2));
  });
  tearDown(() => db.close());

  test('the default refuses, in words, as a session with no modes', () async {
    final link = service.open((_) {});
    await expectLater(
      link.handleLater(const SessionSetMode(sessionId: 's1', modeId: 'plan')),
      throwsA(
        isA<DataRefused>()
            .having((r) => r.code, 'code', DataRefusalCode.invalid)
            .having(
              (r) => r.message,
              'message',
              'This session has no modes to set.',
            ),
      ),
    );
  });

  test(
    'a runtime set on sessionModes is handed the session and mode',
    () async {
      final modes = _RecordingModes();
      service.sessionModes = modes;
      final link = service.open((_) {});
      final reply = await link.handleLater(
        const SessionSetMode(sessionId: 's1', modeId: 'plan'),
      );
      expect(reply.value, isA<DataAck>());
      expect(modes.set, [('s1', 'plan')]);
    },
  );

  test('it is answered when done, never at once', () {
    final link = service.open((_) {});
    expect(
      () => link.handle(const SessionSetMode(sessionId: 's1', modeId: 'plan')),
      throwsA(
        isA<DataRefused>().having(
          (r) => r.code,
          'code',
          DataRefusalCode.invalid,
        ),
      ),
    );
  });
}
