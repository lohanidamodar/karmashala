import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:karmashala/src/features/devices/application/device_bindings.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala_devices/providers.dart';
import 'package:karmashala_devices/devices.dart';
import 'package:karmashala/src/features/mcp/launcher_control_server.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fixtures.dart';
import '../../support/fakes.dart' show MovableClock;

/// The pre-action safety net: `device_tap` looks at the screen immediately
/// before it touches it, and refuses a coordinate for a screen that is gone.
///
/// Every cost here is **counted**, never timed: what a vetted tap costs is the
/// list of adb invocations it made, which is a number a test can assert and a
/// stopwatch is not.
const _sdkRoot = r'C:\sdk';
const _adbPath = r'C:\sdk\platform-tools\adb.exe';

AndroidSdk _sdk() => const AndroidSdk(
  root: EnvironmentPath(environmentId: 'windows-native', path: _sdkRoot),
  adb: EnvironmentPath(environmentId: 'windows-native', path: _adbPath),
);

/// The login screen: one button, at a known rectangle.
String _screen({
  String label = 'Sign in',
  String bounds = '[300,700][780,860]',
  bool withDialog = false,
}) =>
    '<?xml version="1.0" encoding="UTF-8"?>'
    '<hierarchy rotation="0">'
    '<node index="0" class="android.widget.FrameLayout" '
    'package="com.example.app" bounds="[0,0][1080,2400]">'
    '<node index="0" text="$label" resource-id="com.example.app:id/signin" '
    'class="android.widget.Button" package="com.example.app" '
    'clickable="true" enabled="true" bounds="$bounds" />'
    '${withDialog ? '<node index="1" text="Discard changes?" '
              'resource-id="android:id/alertTitle" '
              'class="android.widget.TextView" package="com.example.app" '
              'enabled="true" bounds="[120,900][960,1000]" />' : ''}'
    '</node>'
    '</hierarchy>';

void main() {
  late FakeCommandRunner adb;
  late ProviderContainer container;
  late LauncherControlServer server;
  late Directory tmp;
  late MovableClock clock;

  /// What `uiautomator dump` will produce on the next read. Reassigning it is
  /// how a test says "the screen moved".
  late String dumpXml;

  /// Set to make the dump fail, the way uiautomator does mid-animation.
  late bool dumpFails;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('karmashala_tap_net_');
    clock = MovableClock(testTime);
    dumpXml = _screen();
    dumpFails = false;
    adb = FakeCommandRunner(
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
          return dumpFails
              ? const CommandResult(
                  exitCode: 1,
                  stdout: '',
                  stderr: 'ERROR: could not get idle state.',
                )
              : const CommandResult(
                  exitCode: 0,
                  stdout: 'UI hierchary dumped to: /data/local/tmp/x.xml',
                  stderr: '',
                );
        }
        if (args.contains('cat')) {
          return CommandResult(exitCode: 0, stdout: dumpXml, stderr: '');
        }
        return const CommandResult(exitCode: 0, stdout: '', stderr: '');
      },
    );

    container = ProviderContainer(
      overrides: [
        // The app's half of `karmashala_devices`: its clock, its runner
        // factory, its settings and its shell, behind the package's ports.
        ...deviceBindings,
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(fallback: adb),
        ),
        androidSdkProvider.overrideWith((ref) => _sdk()),
        clockProvider.overrideWithValue(clock),
      ],
    );
    await container.read(androidSdkProvider.future);
    server = LauncherControlServer(container);
    await server.start(
      bridgeFilePath: '${tmp.path}${Platform.pathSeparator}bridge.json',
      useLocalSocket: false,
    );
  });

  tearDown(() async {
    await server.stop();
    container.dispose();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<Map<String, dynamic>> call(
    String tool, [
    Map<String, Object?> arguments = const {},
  ]) async {
    final handshake =
        jsonDecode(
              File(
                '${tmp.path}${Platform.pathSeparator}bridge.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    final client = HttpClient();
    try {
      final request = await client.post(
        '127.0.0.1',
        handshake['port'] as int,
        '/rpc',
      );
      request.headers.set(
        'authorization',
        'Bearer ${handshake['token'] as String}',
      );
      request.write(jsonEncode({'tool': tool, 'arguments': arguments}));
      final response = await request.close();
      return jsonDecode(await utf8.decoder.bind(response).join())
          as Map<String, dynamic>;
    } finally {
      client.close(force: true);
    }
  }

  Map<String, Object?> ok(Map<String, dynamic> reply) {
    expect(reply['ok'], isTrue, reason: 'RPC failed: ${reply['error']}');
    return (reply['result'] as Map).cast<String, Object?>();
  }

  String failure(Map<String, dynamic> reply) {
    expect(
      reply['ok'],
      isFalse,
      reason: 'expected a refusal, got ${reply['result']}',
    );
    return reply['error'] as String;
  }

  /// The adb command lines run since [from], as a countable list of work.
  List<String> workSince(int from) => [
    for (final request in adb.requests.skip(from)) request.arguments.join(' '),
  ];

  group('a coordinate for a screen that is gone', () {
    test('is refused, and the refusal says what moved', () async {
      ok(await call('device_ui_dump', {'serial': 'emulator-5554'}));

      // A dialog arrives between the look and the tap — the case the whole
      // check exists for.
      dumpXml = _screen(withDialog: true);
      clock.advance(const Duration(seconds: 8));

      final refusal = failure(
        await call('device_tap', {
          'serial': 'emulator-5554',
          'x': 540,
          'y': 780,
        }),
      );

      expect(refusal, contains('the screen has moved'));
      expect(refusal, contains('(540, 780)'));
      expect(refusal, contains('emulator-5554'));
      // The age of the reading it was checked against (§19).
      expect(refusal, contains('8s ago'));
      // What differs, not merely that something does.
      expect(refusal, contains('2 nodes then'));
      expect(refusal, contains('3 now'));
      // And the two ways out, both named.
      expect(refusal, contains('device_tap_element'));
      expect(refusal, contains('verify: false'));
    });

    test('nothing was tapped', () async {
      ok(await call('device_ui_dump', {'serial': 'emulator-5554'}));
      dumpXml = _screen(withDialog: true);
      final before = adb.requests.length;

      failure(
        await call('device_tap', {
          'serial': 'emulator-5554',
          'x': 540,
          'y': 780,
        }),
      );

      expect(
        workSince(before).where((line) => line.contains('input tap')),
        isEmpty,
      );
    });

    test('the identical retry is refused again', () async {
      ok(await call('device_ui_dump', {'serial': 'emulator-5554'}));
      dumpXml = _screen(withDialog: true);

      failure(
        await call('device_tap', {
          'serial': 'emulator-5554',
          'x': 540,
          'y': 780,
        }),
      );
      // A refusal that filed the screen it had just read would let this one
      // straight through, against a screen the caller never looked at.
      expect(
        failure(
          await call('device_tap', {
            'serial': 'emulator-5554',
            'x': 540,
            'y': 780,
          }),
        ),
        contains('the screen has moved'),
      );
    });

    test('looking again is what clears it', () async {
      ok(await call('device_ui_dump', {'serial': 'emulator-5554'}));
      dumpXml = _screen(withDialog: true);
      failure(
        await call('device_tap', {
          'serial': 'emulator-5554',
          'x': 540,
          'y': 780,
        }),
      );

      ok(await call('device_ui_dump', {'serial': 'emulator-5554'}));
      expect(
        ok(
          await call('device_tap', {
            'serial': 'emulator-5554',
            'x': 540,
            'y': 780,
          }),
        )['tapped'],
        '(540, 780)',
      );
    });

    test('a reading too old to be the one is a note, not a refusal', () async {
      ok(await call('device_ui_dump', {'serial': 'emulator-5554'}));
      dumpXml = _screen(withDialog: true);
      clock.advance(kDeviceLookWindow + const Duration(minutes: 1));

      final result = ok(
        await call('device_tap', {
          'serial': 'emulator-5554',
          'x': 540,
          'y': 780,
        }),
      );
      expect(result['checked'], contains('not refused'));
      expect(result['checked'], contains('6m ago'));
    });
  });

  group('a screen this app has never read', () {
    test('is a note, never a refusal: an unknown is not evidence', () async {
      final result = ok(
        await call('device_tap', {
          'serial': 'emulator-5554',
          'x': 540,
          'y': 780,
        }),
      );

      expect(result['tapped'], '(540, 780)');
      expect(
        result['checked'],
        contains('nothing this app has read says where (540, 780) came from'),
      );
      expect(result['checked'], contains('device_ui_dump'));
    });
  });

  group('a coordinate that still holds', () {
    test('names what is under the finger, and the call to prefer', () async {
      ok(await call('device_ui_dump', {'serial': 'emulator-5554'}));
      clock.advance(const Duration(seconds: 4));

      final result = ok(
        await call('device_tap', {
          'serial': 'emulator-5554',
          'x': 540,
          'y': 780,
        }),
      );

      expect(result['checked'], contains('matches the screen last read'));
      expect(result['checked'], contains('4s ago'));
      expect(result['under'], contains('Sign in'));
      expect(result['prefer'], contains('device_tap_element(text: "Sign in")'));
      // The argument that actually changes the choice.
      expect(result['prefer'], contains('costs exactly what this call costs'));
    });

    test(
      'a label that changed but a layout that did not still passes',
      () async {
        ok(await call('device_ui_dump', {'serial': 'emulator-5554'}));
        // A clock, a counter, a streaming response: text moves, the screen has
        // not. Fingerprinting text would refuse every tap on a live screen.
        dumpXml = _screen(label: 'Signing in…');

        expect(
          ok(
            await call('device_tap', {
              'serial': 'emulator-5554',
              'x': 540,
              'y': 780,
            }),
          )['checked'],
          contains('matches'),
        );
      },
    );

    test('the same labels in different places do not', () async {
      ok(await call('device_ui_dump', {'serial': 'emulator-5554'}));
      // A scroll: every label identical, every rectangle moved, and the
      // coordinate now points at whatever slid into its place.
      dumpXml = _screen(bounds: '[300,300][780,460]');

      expect(
        failure(
          await call('device_tap', {
            'serial': 'emulator-5554',
            'x': 540,
            'y': 780,
          }),
        ),
        contains('something moved, scrolled or was replaced'),
      );
    });
  });

  group('off the display', () {
    test('is refused rather than sent, because it reports success', () async {
      final refusal = failure(
        await call('device_tap', {
          'serial': 'emulator-5554',
          'x': 540,
          'y': 9000,
        }),
      );
      expect(refusal, contains('off a 1080x2400'));
      expect(refusal, contains('reports success'));
    });
  });

  group('what the check costs, counted', () {
    test('a vetted tap is one screen read plus the tap', () async {
      // Warm the fleet and the screen size so the count is the check itself.
      ok(await call('device_ui_dump', {'serial': 'emulator-5554'}));
      final before = adb.requests.length;

      ok(
        await call('device_tap', {
          'serial': 'emulator-5554',
          'x': 540,
          'y': 780,
        }),
      );

      final work = workSince(before);
      expect(
        work.where((line) => line.contains('input tap')),
        hasLength(1),
        reason: 'exactly one tap went out',
      );
      expect(
        work.where((line) => line.contains('uiautomator dump')),
        hasLength(1),
        reason: 'one screen read — the same one device_tap_element pays',
      );
    });

    test('verify: false reads nothing at all', () async {
      ok(await call('device_ui_dump', {'serial': 'emulator-5554'}));
      final before = adb.requests.length;

      final result = ok(
        await call('device_tap', {
          'serial': 'emulator-5554',
          'x': 540,
          'y': 780,
          'verify': false,
        }),
      );

      final work = workSince(before);
      expect(work.where((line) => line.contains('uiautomator')), isEmpty);
      expect(work.where((line) => line.contains('input tap')), hasLength(1));
      expect(result['checked'], contains('verify: false'));
      expect(result['under'], isNull);
    });

    test('a vetted tap costs what device_tap_element costs', () async {
      ok(await call('device_ui_dump', {'serial': 'emulator-5554'}));

      final beforeTap = adb.requests.length;
      ok(
        await call('device_tap', {
          'serial': 'emulator-5554',
          'x': 540,
          'y': 780,
        }),
      );
      final tapWork = workSince(beforeTap).length;

      final beforeElement = adb.requests.length;
      ok(
        await call('device_tap_element', {
          'serial': 'emulator-5554',
          'text': 'Sign in',
        }),
      );
      final elementWork = workSince(beforeElement).length;

      // The argument the policy rests on: the fallback is no longer cheaper.
      expect(tapWork, elementWork);
    });
  });

  group('a check that cannot be run', () {
    test('is reported, never raised — the tap still goes out', () async {
      dumpFails = true;

      final result = ok(
        await call('device_tap', {
          'serial': 'emulator-5554',
          'x': 540,
          'y': 780,
        }),
      );

      expect(result['tapped'], '(540, 780)');
      expect(result['checked'], contains('not checked'));
      expect(result['checked'], contains('sent unverified'));
    });
  });

  group('the dynamic path survives what the coordinate path cannot', () {
    test('device_tap_element is not refused when the screen moved', () async {
      ok(await call('device_ui_dump', {'serial': 'emulator-5554'}));
      dumpXml = _screen(withDialog: true);
      clock.advance(const Duration(seconds: 5));

      final reply = ok(
        await call('device_tap_element', {
          'serial': 'emulator-5554',
          'text': 'Sign in',
        }),
      );
      final text =
          ((reply['_mcpContent']! as List).first as Map)['text'] as String;

      expect(text, contains('Tapped'));
      // Not refused — but the caller is told its wider plan is stale.
      expect(text, contains('the screen changed since it was last read'));
      expect(text, contains('5s ago'));
      expect(text, contains('any coordinate you are still holding'));
    });
  });
}
