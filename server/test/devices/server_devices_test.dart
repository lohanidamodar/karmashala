import 'dart:convert';

import 'package:agent_cli/process.dart';
import 'package:karmashala_core/util.dart';
import 'package:karmashala_devices/karmashala_devices.dart';
import 'package:karmashala_host/src/devices/server_device_claims.dart';
import 'package:karmashala_host/src/devices/server_devices.dart';
import 'package:test/test.dart';

import '../mcp/tools/tool_harness.dart';
import '../support/fake_command_runner.dart';

class _Clock implements Clock {
  _Clock(this.now);
  DateTime now;
  void advance(Duration by) => now = now.add(by);
  @override
  DateTime nowUtc() => now.toUtc();
}

AndroidSdk _sdkAt(String root) => AndroidSdk(
  root: EnvironmentPath(environmentId: 'localPosix', path: root),
  adb: EnvironmentPath(
    environmentId: 'localPosix',
    path: '$root/platform-tools/adb',
  ),
);

/// The devices on the server's machine (slice 4a): its adb found by the one
/// rule — the `androidSdkPath` setting first — and kept while it stays put.
void main() {
  late ToolHarness harness;
  late _Clock clock;
  late ServerDeviceClaims claims;
  late FakeCommandRunner runner;
  late List<String?> asked;
  final logged = <String>[];

  setUp(() {
    harness = ToolHarness();
    clock = _Clock(DateTime.utc(2026, 9, 27, 12));
    claims = ServerDeviceClaims(
      database: harness.db,
      tell: (_) {},
      clock: clock,
    );
    runner = FakeCommandRunner(environmentId: 'localPosix');
    asked = [];
    logged.clear();
  });

  tearDown(() {
    claims.close();
    harness.dispose();
  });

  ServerDevices devices({bool sdk = true, bool simulators = false}) =>
      ServerDevices(
        database: harness.db,
        claims: claims,
        runners: FakeCommandRunnerFactory(fallback: runner),
        canRunSimulators: simulators,
        backendFor: (_, _) => null,
        findSdk: (handSet) async {
          asked.add(handSet);
          return sdk ? _sdkAt(handSet ?? '/env/sdk') : null;
        },
        clock: clock,
        log: logged.add,
      );

  void settings(Map<String, Object?> json) =>
      harness.db.writeMetadata('settings.v1', jsonEncode(json));

  test(
    'the SDK a person named in the settings is the one looked for',
    () async {
      settings({'androidSdkPath': '/chosen'});
      final found = await devices().sdk();
      expect(asked, ['/chosen']);
      expect(found!.root.path, '/chosen');
    },
  );

  test('with nothing named, the search is the environment\'s own', () async {
    await devices().sdk();
    expect(asked, [null]);
  });

  test('a reading is reused while fresh, and a changed setting is read at '
      'once', () async {
    final machine = devices();
    await machine.sdk();
    await machine.sdk();
    expect(asked, hasLength(1));

    settings({'androidSdkPath': '/chosen'});
    await machine.sdk();
    expect(asked, [null, '/chosen']);

    clock.advance(machine.sdkFreshFor);
    await machine.sdk();
    expect(asked, hasLength(3), reason: 'a stale reading is looked for again');
  });

  test('one adb while the SDK stays where it is', () async {
    final machine = devices();
    final first = await machine.adb();
    clock.advance(machine.sdkFreshFor);
    final second = await machine.adb();
    expect(identical(first, second), isTrue);

    settings({'androidSdkPath': '/elsewhere'});
    final third = await machine.adb();
    expect(identical(first, third), isFalse);
    expect(third!.sdk.adb.path, '/elsewhere/platform-tools/adb');
  });

  test('flutter run\'s ANDROID_HOME is the SDK root', () async {
    settings({'androidSdkPath': '/chosen'});
    expect(await devices().androidSdkRoot(), '/chosen');
    expect(await devices(sdk: false).androidSdkRoot(), isNull);
  });

  test('no SDK and no simulators: nothing to drive, said in words', () async {
    final fleet = await devices(sdk: false).fleet();
    expect(fleet.adb, isNull);
    expect(fleet.simctl, isNull);
    await expectLater(
      fleet.requireTarget(null, verb: 'device_tap'),
      throwsA(
        isA<DeviceRefusal>().having(
          (r) => r.message,
          'message',
          allOf(contains('No Android SDK'), contains('macOS')),
        ),
      ),
    );
  });

  Future<List<String>> bootOne() async {
    runner.processFactory = (request) {
      final handle = FakeProcessHandle();
      handle.complete();
      return handle;
    };
    final fleet = await devices(simulators: true).fleet();
    await fleet.bootSimulator('UDID-1');
    expect(fleet.simulatorIsBusy('UDID-1'), isFalse);
    return [
      for (final r in [...runner.requests, ...runner.startRequests])
        '${r.executable} ${r.arguments.join(' ')}',
    ];
  }

  test('a simulator is slimmed before it boots, as the settings say', () async {
    final lines = await bootOne();
    // The fake machine knows no such simulator, so the slimming it tried is
    // refused — and the boot goes ahead without it, said in the log.
    expect(logged.single, contains('without slimming'));
    expect(lines.where((l) => l.contains('boot')), isNotEmpty);
  });

  test('a simulator booted with slimming off is not slimmed', () async {
    settings({'simulatorSlimming': false});
    final lines = await bootOne();
    expect(logged, isEmpty, reason: 'slimming was not even tried');
    expect(lines.where((l) => l.contains('list')), isEmpty);
  });
}
