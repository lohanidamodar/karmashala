@Tags(['live-android'])
library;

import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:karmashala_devices/devices.dart';
import 'package:test/test.dart';

/// Every slimming layer against a real emulator on this machine: SDK discovery
/// finds it, the launch flags boot it, both durable layers survive a cold boot,
/// and Restore leaves nothing of ours behind. Runs only when
/// `KARMASHALA_LIVE_AVD` names an AVD **made for it** — the durable layers
/// rewrite the AVD, so it must never be one somebody uses.
void main() {
  final avd = Platform.environment['KARMASHALA_LIVE_AVD'];

  test(
    'slimming survives a cold boot, and Restore puts back all of it',
    () async {
      const runner = LocalCommandRunner();
      final sdk = await AndroidSdkDiscoveryService(
        runner: runner,
        environment: ExecutionEnvironment(
          id: 'local',
          kind: EnvironmentKind.localPosix,
          name: 'This computer',
          createdAt: DateTime.utc(2026, 9, 24),
        ),
      ).discover();
      expect(sdk, isNotNull, reason: 'the SDK is found where the app looks');
      expect(sdk!.emulator, isNotNull, reason: 'and its emulator with it');

      final adb = AdbService(runner: runner, sdk: sdk);
      final slimming = AndroidSlimmingService(runner: runner, sdk: sdk);
      final all = AndroidSlimmingCategory.values.toSet();
      final flags = launchArguments(enabled: all);
      // ignore: avoid_print
      print('launch flags: $flags');

      var serial = await adb.bootAvdAndWait(avd!, extraArguments: flags);
      addTearDown(() => adb.stopEmulator(serial));

      // Stock first, whatever a run that stopped halfway left on it.
      await slimming.restore(serial);
      final stock = await slimming.status(serial);
      expect(stock.isSlimmed, isFalse, reason: 'Restore is where it starts');

      final report = await slimming.apply(serial, enabled: all);
      // ignore: avoid_print
      print('applied: $report');
      expect(report.failed, isEmpty);
      expect(report.absent, isNot(anyElement(isIn(report.applied))));
      final slimmed = await slimming.status(serial);
      expect(slimmed.settingsSlimmed, isTrue);
      expect(slimmed.disabledManaged, isNotEmpty);

      // A cold boot: the emulator stopped, and started without a snapshot.
      expect(await adb.stopEmulator(serial), isTrue);
      serial = await adb.bootAvdAndWait(
        avd,
        extraArguments: [...flags, '-no-snapshot-load'],
      );
      final rebooted = await slimming.status(serial);
      // ignore: avoid_print
      print('after a cold boot: ${rebooted.summary}');
      expect(rebooted.slimmedSettings, slimmed.slimmedSettings);
      expect(rebooted.disabledManaged, slimmed.disabledManaged);

      final restored = await slimming.restore(serial);
      expect(restored.failed, isEmpty);
      final after = await slimming.status(serial);
      // ignore: avoid_print
      print('after Restore: ${after.summary}');
      expect(after.isSlimmed, isFalse);
      expect(after.disabledUnmanaged, stock.disabledUnmanaged);
    },
    timeout: const Timeout(Duration(minutes: 12)),
    skip: avd == null
        ? 'set KARMASHALA_LIVE_AVD to an AVD made for this test'
        : null,
  );
}
