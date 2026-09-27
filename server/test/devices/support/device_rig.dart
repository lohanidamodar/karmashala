import 'dart:convert';

import 'package:agent_cli/process.dart';
import 'package:karmashala_core/util.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_devices/karmashala_devices.dart';
import 'package:karmashala_host/src/devices/server_device_claims.dart';
import 'package:karmashala_host/src/devices/server_devices.dart';
import 'package:karmashala_host/src/mcp/tools/device_tool_set.dart';

import '../../mcp/tools/tool_harness.dart';
import '../../support/fake_command_runner.dart';

/// The Android SDK a rig's fake adb answers to.
const String kRigAdbPath = '/sdk/platform-tools/adb';
const String kRigEmulatorPath = '/sdk/emulator/emulator';

AndroidSdk rigSdk() => const AndroidSdk(
  root: EnvironmentPath(environmentId: 'localPosix', path: '/sdk'),
  adb: EnvironmentPath(environmentId: 'localPosix', path: kRigAdbPath),
  emulator: EnvironmentPath(
    environmentId: 'localPosix',
    path: kRigEmulatorPath,
  ),
);

/// The server's devices (slice 4a) over a fake machine: [runner] stands in for
/// adb, xcrun and plutil, [backend] for WebDriverAgent, and the sessions are
/// [harness]'s (s1 "Fix login", s2 "The verifier"). [call] answers a device
/// tool the way an agent's call was answered over the app's `/rpc` — `{ok,
/// result}` or `{ok: false, error}` — as JSON, so a moved test reads alike.
class DeviceRig {
  DeviceRig({
    ToolHarness? harness,
    required FakeCommandRunner runner,
    SimulatorBackend? backend,
    AndroidSdk? sdk,
    bool androidSdk = true,
    bool simulators = true,
    Clock? clock,
    Duration sdkDiscovery = Duration.zero,
  }) : harness = harness ?? ToolHarness() {
    final at = clock ?? const SystemClock();
    claims = ServerDeviceClaims(
      database: this.harness.db,
      tell: told.addAll,
      clock: at,
    );
    devices = ServerDevices(
      database: this.harness.db,
      claims: claims,
      runners: FakeCommandRunnerFactory(fallback: runner),
      canRunSimulators: simulators,
      backendFor: (_, _) => backend,
      findSdk: (_) async {
        if (sdkDiscovery > Duration.zero) {
          await Future<void>.delayed(sdkDiscovery);
        }
        return androidSdk ? (sdk ?? rigSdk()) : null;
      },
      clock: at,
    );
    tools = DeviceToolSet(devices);
  }

  final ToolHarness harness;
  late final ServerDeviceClaims claims;
  late final ServerDevices devices;
  late final DeviceToolSet tools;

  /// Every change the claims told clients.
  final told = <DataChange>[];

  /// [tool] as session [caller] calls it.
  Future<Map<String, dynamic>> call(
    String tool, [
    Map<String, Object?> arguments = const {},
    String? caller,
  ]) async {
    try {
      final result = await tools.call(
        tool,
        Map<String, dynamic>.from(arguments),
        caller,
      )!;
      return {'ok': true, 'result': jsonDecode(jsonEncode(result))};
    } on Object catch (error) {
      return {'ok': false, 'error': '$error'};
    }
  }

  Future<void> dispose() async {
    claims.close();
    await devices.close();
    harness.dispose();
  }
}

/// The answer of a call that worked.
Map<String, dynamic> rigOk(Map<String, dynamic> reply) {
  if (reply['ok'] != true) {
    throw StateError('RPC failed: ${reply['error']}');
  }
  return reply['result'] as Map<String, dynamic>;
}

/// The text blocks of a call that worked.
String rigText(Map<String, dynamic> reply) {
  final content = rigOk(reply)['_mcpContent'] as List;
  return [
    for (final block in content)
      if ((block as Map)['type'] == 'text') block['text'] as String,
  ].join('\n');
}

/// The refusal of a call that did not.
String rigError(Map<String, dynamic> reply) {
  if (reply['ok'] != false) {
    throw StateError('expected a refusal, got ${reply['result']}');
  }
  return reply['error'] as String;
}
