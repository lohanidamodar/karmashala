import 'dart:io';

import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/mcp/launcher_control_server.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// Which port the control server listens on, and why it is no longer an
/// ephemeral one.
///
/// WSL2 reaches the host across a Hyper-V virtual switch, and Windows governs
/// that traffic with a separate firewall whose default inbound action is
/// Block. An agent in a distribution cannot reach this server at all unless a
/// Hyper-V rule names it — and those rules name **ports, never programs**. An
/// ephemeral port could therefore never be allowed: it moved every launch, and
/// the installer had no way to name it in advance. That is the whole reason a
/// hook posting from WSL failed on every prompt with `curl: (52) Empty reply
/// from server` while the identical request from Windows got a clean `401`.
///
/// The port is injected here rather than assumed free. These tests run beside
/// three other files that also start servers, and a test that raced them for
/// one global port passed or failed on who got there first.
void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('chitra_port_'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// A port nothing is listening on: bound to learn its number, then released.
  Future<int> freePort() async {
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = probe.port;
    await probe.close();
    return port;
  }

  Future<LauncherControlServer> startIn(String name, int preferred) async {
    final dir = Directory(p.join(tmp.path, name))..createSync(recursive: true);
    final container = ProviderContainer(
      overrides: [clockProvider.overrideWithValue(FixedClock(testTime))],
    );
    final server = LauncherControlServer(container);
    await server.start(
      bridgeFilePath: p.join(dir.path, 'mcp_bridge.json'),
      socketDirectory: p.join(dir.path, 'ipc'),
      preferredPort: preferred,
    );
    addTearDown(() async {
      await server.stop();
      container.dispose();
    });
    return server;
  }

  test('it takes the port it was told to prefer', () async {
    final wanted = await freePort();

    final server = await startIn('first', wanted);

    expect(
      server.hookEndpoint!.port,
      wanted,
      reason: 'the Hyper-V rule names one port, so this must be that port',
    );
  });

  test('a port already taken costs Windows nothing', () async {
    // Another copy of the app, or anything else holding it. Falling back is
    // not a failure: every Windows pane works on any port. What is lost is
    // WSL, and the app says so in the log rather than leaving it silent.
    final wanted = await freePort();
    final squatter = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      wanted,
    );
    addTearDown(squatter.close);

    final server = await startIn('second', wanted);

    expect(server.hookEndpoint!.port, isNot(wanted));
    expect(server.hookEndpoint!.port, greaterThan(0));

    // And it is a real server, not a husk.
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final request = await client.postUrl(
      Uri.parse(
        'http://127.0.0.1:${server.hookEndpoint!.port}/agent-hook'
        '?agent=claudeCode&event=Stop',
      ),
    );
    request.write('{}');
    final response = await request.close();
    await response.drain<void>();
    expect(
      response.statusCode,
      anyOf(200, 202, 401, 403),
      reason: 'it answered rather than closing the connection',
    );
  });

  test('the installer opens exactly the port the app asks for', () {
    // The two live in different files and different languages, and nothing
    // else would notice them drifting apart: the app would bind a port the
    // Hyper-V rule does not name, and WSL agents would go quiet again with
    // every test still green.
    final iss = File(
      p.join('windows', 'installer', 'karmashala.iss'),
    ).readAsStringSync();

    expect(
      iss,
      contains('-LocalPorts $preferredControlPort'),
      reason: 'the firewall rule must name the port the server binds',
    );
  });
}
