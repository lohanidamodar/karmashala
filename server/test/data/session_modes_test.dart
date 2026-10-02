import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/data.dart';
import 'package:karmashala_host/src/sessions/session_modes.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

/// `sessions.setMode` and `sessions.setConfigOption` reach the one seam the
/// ACP runtime implements, and say in words why nothing can be set until it
/// does.
class _RecordingModes implements SessionModeChanger {
  final set = <(String, String)>[];
  final options = <(String, String, Object)>[];

  @override
  Future<void> setMode(String sessionId, String modeId) async {
    set.add((sessionId, modeId));
  }

  @override
  Future<void> setConfigOption(
    String sessionId,
    String configId,
    Object value,
  ) async {
    options.add((sessionId, configId, value));
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

  test('sessions.setConfigOption lands on the same seam, with a choice or a '
      'flag, and the default refuses it in words', () async {
    final link = service.open((_) {});
    await expectLater(
      link.handleLater(
        const SessionSetConfigOption(
          sessionId: 's1',
          configId: 'model',
          value: 'opus',
        ),
      ),
      throwsA(
        isA<DataRefused>().having(
          (r) => r.message,
          'message',
          'This session has no config options to set.',
        ),
      ),
    );

    final modes = _RecordingModes();
    service.sessionModes = modes;
    final reply = await link.handleLater(
      const SessionSetConfigOption(
        sessionId: 's1',
        configId: 'model',
        value: 'opus',
      ),
    );
    expect(reply.value, isA<DataAck>());
    await link.handleLater(
      const SessionSetConfigOption(
        sessionId: 's1',
        configId: 'thinking',
        value: true,
      ),
    );
    expect(modes.options, [('s1', 'model', 'opus'), ('s1', 'thinking', true)]);
    expect(
      () => link.handle(
        const SessionSetConfigOption(
          sessionId: 's1',
          configId: 'model',
          value: 'opus',
        ),
      ),
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
