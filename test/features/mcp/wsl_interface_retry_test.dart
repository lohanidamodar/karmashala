import 'dart:io';

import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/mcp/launcher_control_server.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// Looking for the WSL switch once, at startup, and never again.
///
/// The owner's app started at 11:25, the switch was not enumerable at that
/// instant, and the code did `if (host == null) return;` — no log, no retry.
/// Every WSL session that morning launched with no tools and no hooks while
/// the adapter sat there the whole time. The moment an app that starts with
/// Windows looks is the moment it is least likely to be true: WSL starts
/// later.
void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('chitra_wslretry_'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// Stands in for the WSL switch. Deliberately NOT 127.0.0.1: the control
  /// server already holds that address on this port, so using it would test
  /// nothing but a collision — as it did on the first run of these tests.
  final switchAddress = InternetAddress('127.0.0.2');

  Future<int> freePort() async {
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = probe.port;
    await probe.close();
    return port;
  }

  Future<LauncherControlServer> start({
    required Future<InternetAddress?> Function() lookup,
    Duration retryEvery = const Duration(milliseconds: 20),
  }) async {
    final container = ProviderContainer(
      overrides: [clockProvider.overrideWithValue(FixedClock(testTime))],
    );
    final server = LauncherControlServer(container);
    await server.start(
      bridgeFilePath: p.join(tmp.path, 'mcp_bridge.json'),
      useLocalSocket: false,
      preferredPort: await freePort(),
      wslHostAddress: lookup,
      retryWslEvery: retryEvery,
    );
    addTearDown(() async {
      await server.stop();
      container.dispose();
    });
    return server;
  }

  test('a switch that appears later is still bound', () async {
    // Null at startup, present afterwards — an app launched with Windows,
    // before the first `wsl.exe` of the day.
    InternetAddress? found;
    final server = await start(lookup: () async => found);

    expect(
      server.wslHost,
      isNull,
      reason: 'nothing to bind yet, and that is not an error',
    );

    found = switchAddress;
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(
      server.wslHost,
      isNotNull,
      reason: 'the retry found it without anyone restarting the app',
    );
  });

  test('hooks skipped at startup are installed once it binds', () async {
    // Hooks are written at startup against the endpoint of that moment, so a
    // WSL store is skipped when there is no address. Nothing else in the app
    // ever revisited that, which is why WSL hooks stayed dead for a whole run.
    InternetAddress? found;
    var announced = 0;
    final server = await start(lookup: () async => found);
    server.onWslInterfaceBound = () => announced++;

    expect(announced, 0);

    found = switchAddress;
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(announced, 1, reason: 'exactly once, on the transition');
    expect(server.hookEndpoint!.wslHost, isNotNull);
  });

  test('a switch present at startup announces nothing', () async {
    // The ordinary case: bound on the first attempt, so hooks are already
    // being written against it and re-running them would be noise.
    var announced = 0;
    final server = await start(
      lookup: () async => switchAddress,
    );
    server.onWslInterfaceBound = () => announced++;

    await Future<void>.delayed(const Duration(milliseconds: 120));

    expect(server.wslHost, isNotNull);
    expect(announced, 0);
  });

  test('stopping ends the retry', () async {
    final server = await start(lookup: () async => null);
    await server.stop();

    // Nothing should still be looking; a pending timer would fail the test.
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(server.wslHost, isNull);
  });
}
