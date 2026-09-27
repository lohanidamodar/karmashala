import 'package:agent_cli/process.dart';
import 'package:karmashala_core/util.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_devices/karmashala_devices.dart';
import 'package:karmashala_session/session.dart';
import 'package:test/test.dart';

import '../support/fake_command_runner.dart';
import 'support/device_rig.dart';

/// The device lock on the server's machine (slice 4a), driven the way two
/// agents would collide: two sessions — the identity the MCP transport
/// establishes — reaching for one emulator through the server's device tools.
///
/// Nothing here is timed. The clock moves because a test moved it.
const _dumpXml =
    '<?xml version="1.0" encoding="UTF-8"?>'
    '<hierarchy rotation="0">'
    '<node index="0" class="android.widget.FrameLayout" '
    'package="com.example.app" bounds="[0,0][1080,2400]">'
    '<node index="0" text="Sign in" resource-id="com.example.app:id/signin" '
    'class="android.widget.Button" package="com.example.app" '
    'clickable="true" enabled="true" bounds="[300,700][780,860]" />'
    '</node>'
    '</hierarchy>';

class _Clock implements Clock {
  _Clock(this.now);
  DateTime now;
  void advance(Duration by) => now = now.add(by);
  @override
  DateTime nowUtc() => now.toUtc();
}

void main() {
  late DeviceRig rig;
  late _Clock clock;

  setUp(() {
    clock = _Clock(DateTime.utc(2026, 9, 27, 12));
    final adb = FakeCommandRunner(
      environmentId: 'localPosix',
      responder: (request) {
        final args = request.arguments;
        if (args.contains('devices')) {
          return const CommandResult(
            exitCode: 0,
            stdout:
                'List of devices attached\n'
                'emulator-5554  device product:sdk model:Pixel transport_id:7\n',
            stderr: '',
          );
        }
        if (args.contains('wm')) {
          return const CommandResult(
            exitCode: 0,
            stdout: 'Physical size: 1080x2400',
            stderr: '',
          );
        }
        if (args.contains('uiautomator')) {
          return const CommandResult(
            exitCode: 0,
            stdout: 'UI hierchary dumped to: /data/local/tmp/x.xml',
            stderr: '',
          );
        }
        if (args.contains('cat')) {
          return const CommandResult(exitCode: 0, stdout: _dumpXml, stderr: '');
        }
        return const CommandResult(exitCode: 0, stdout: '', stderr: '');
      },
    );
    rig = DeviceRig(runner: adb, simulators: false, clock: clock);
  });

  tearDown(() => rig.dispose());

  Future<({bool isError, String text})> callAs(
    String? session,
    String name, [
    Map<String, Object?> arguments = const {},
  ]) async {
    final reply = await rig.call(name, arguments, session);
    return reply['ok'] == true
        ? (isError: false, text: '${reply['result']}')
        : (isError: true, text: reply['error'] as String);
  }

  void setStatus(String id, String status) => rig.harness.db.execute(
    'UPDATE sessions SET status = ? WHERE id = ?;',
    [status, id],
  );

  group('two agents, one phone', () {
    test('the second caller is refused, and told who is driving', () async {
      final first = await callAs('s1', 'device_tap', {'x': 540, 'y': 780});
      expect(first.isError, isFalse, reason: first.text);

      final second = await callAs('s2', 'device_tap', {'x': 100, 'y': 100});

      expect(second.isError, isTrue);
      expect(second.text, contains('Fix login'));
      expect(second.text, contains('s1'));
      expect(second.text, contains('emulator-5554'));
      expect(second.text, contains('lapses on its own'));
    });

    test('every acting tool is refused, not only the tap', () async {
      await callAs('s1', 'device_tap', {'x': 540, 'y': 780});

      for (final call in <(String, Map<String, Object?>)>[
        ('device_tap', {'x': 1, 'y': 1}),
        ('device_tap_element', {'text': 'Sign in'}),
        ('device_type', {'text': 'hello'}),
        ('device_key', {'key': 'back'}),
        ('device_launch_app', {'appId': 'com.example.app'}),
        ('device_terminate_app', {'appId': 'com.example.app'}),
      ]) {
        final refused = await callAs('s2', call.$1, call.$2);
        expect(
          refused.isError,
          isTrue,
          reason: '${call.$1} was allowed through while s1 was driving',
        );
        expect(refused.text, contains('Fix login'));
      }
    });

    test('reading the device is never blocked', () async {
      await callAs('s1', 'device_tap', {'x': 540, 'y': 780});

      for (final name in <String>[
        'device_ui_dump',
        'device_find_elements',
        'device_screenshot',
        'device_logcat',
      ]) {
        final read = await callAs(
          's2',
          name,
          name == 'device_find_elements' ? {'text': 'Sign in'} : const {},
        );
        if (name == 'device_screenshot' && read.isError) {
          // The fake adb writes no PNG back; a refusal about the picture is
          // not a refusal about the claim.
          expect(read.text, isNot(contains('being driven')));
          continue;
        }
        expect(
          read.isError,
          isFalse,
          reason: '$name was blocked: ${read.text}',
        );
      }
    });

    test('an unattributed caller respects the claim', () async {
      await callAs('s1', 'device_tap', {'x': 540, 'y': 780});
      final refused = await callAs(null, 'device_tap', {'x': 1, 'y': 1});
      expect(refused.isError, isTrue);
      expect(refused.text, contains('Fix login'));
    });

    test('the holder keeps driving without re-asking', () async {
      await callAs('s1', 'device_tap', {'x': 540, 'y': 780});
      clock.advance(const Duration(seconds: 30));
      final again = await callAs('s1', 'device_type', {'text': 'hello'});
      expect(again.isError, isFalse, reason: again.text);
    });

    test('every client is told who holds the device', () async {
      await callAs('s1', 'device_tap', {'x': 540, 'y': 780});
      final hold = rig.told.whereType<DeviceClaimsChanged>().last.holds.single;
      expect(hold.deviceId, 'emulator-5554');
      expect(hold.holderSessionId, 's1');
      expect(hold.holderTitle, 'Fix login');
    });
  });

  group('a holder that goes away', () {
    test('a session that ended does not keep the device', () async {
      await callAs('s1', 'device_tap', {'x': 540, 'y': 780});
      setStatus('s1', 'completed');

      final second = await callAs('s2', 'device_tap', {'x': 100, 'y': 100});
      expect(second.isError, isFalse, reason: second.text);
    });

    test('a session we merely lost sight of keeps it', () async {
      await callAs('s1', 'device_tap', {'x': 540, 'y': 780});
      setStatus('s1', 'unknown');

      final second = await callAs('s2', 'device_tap', {'x': 100, 'y': 100});
      expect(second.isError, isTrue);
      expect(second.text, contains('Fix login'));
    });

    test('a claim lapses once its holder goes quiet', () async {
      await callAs('s1', 'device_tap', {'x': 540, 'y': 780});
      clock.advance(kDeviceClaimLapse);

      final second = await callAs('s2', 'device_tap', {'x': 100, 'y': 100});
      expect(second.isError, isFalse, reason: second.text);
    });

    test('the ending the server is told of frees the device at once', () async {
      await callAs('s1', 'device_tap', {'x': 540, 'y': 780});
      setStatus('s1', 'completed');
      // The row as the server tells it: the claims watch the batch.
      rig.claims.watch([
        SessionRowChanged(
          Session(
            id: 's1',
            repositoryId: 'r1',
            agentInstallationId: 'a1',
            title: 'Fix login',
            useWorktree: false,
            status: SessionStatus.completed,
            createdAt: clock.now,
          ),
        ),
      ]);
      await pumpEventQueue();

      expect(rig.claims.registry.held, isEmpty);
    });
  });
}
