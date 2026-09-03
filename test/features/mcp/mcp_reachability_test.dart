import 'dart:convert';
import 'dart:io';

import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/logging/app_logger.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/domain/agent_hook_transport.dart';
import 'package:karmashala/src/features/environments/domain/environment_kind.dart';
import 'package:karmashala/src/features/mcp/handshake_file_permissions.dart';
import 'package:karmashala/src/features/mcp/launcher_control_server.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../support/fakes.dart';
import '../../support/second_local_address.dart';
import '../../support/fixtures.dart';

/// The address each kind of session is told to dial, and what that address
/// answers.
///
/// A WSL2 distribution has its own network namespace, so the loopback URL the
/// endpoint shipped with is refused from inside it — which made the whole
/// control surface unreachable for most of this owner's sessions. The fix is a
/// second listener on the WSL virtual switch's host address, and the cases
/// below pin both halves of it: the right URL comes out per environment, and
/// the second listener serves `/mcp` and nothing else.
///
/// A second local address stands in for the switch address. It is a real
/// second address on a real second socket, so these are genuine two-interface
/// tests, and they run on a machine with no WSL installed. Which address that
/// is depends on the host — `127.0.0.2` on Windows and Linux, something else on
/// macOS, which assigns only `127.0.0.1` to `lo0`. See
/// [findSecondLocalAddress].
void main() async {
  // Resolved before the cases are declared so a machine with no second address
  // reports an honest skip rather than failing on a bind it could never make.
  final secondAddress = await findSecondLocalAddress();
  final skip = secondAddress == null ? noSecondAddressReason : null;

  late Directory tmp;
  late ProviderContainer container;
  late LauncherControlServer server;

  final wslStandIn = secondAddress ?? InternetAddress.loopbackIPv4;

  Future<LauncherControlServer> startServer({
    Future<InternetAddress?> Function()? wslHostAddress,
  }) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    container = ProviderContainer(
      overrides: [
        clockProvider.overrideWithValue(FixedClock(testTime)),
        databaseProvider.overrideWithValue(db),
      ],
    );
    final started = LauncherControlServer(container);
    await started.start(
      bridgeFilePath: p.join(tmp.path, 'mcp_bridge.json'),
      socketDirectory: p.join(tmp.path, 'ipc'),
      wslHostAddress: wslHostAddress ?? () async => null,
      // Every case here injects its own stand-in for the switch, so the WSL
      // listener is wanted whatever OS the suite is running on.
      hostCanHaveWsl: true,
    );
    addTearDown(() async {
      await started.stop();
      container.dispose();
    });
    return started;
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('karmashala_mcp_reach_');
    addTearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });
  });

  group('the URL a session is given', () {
    test('a Windows session keeps loopback', () async {
      server = await startServer(wslHostAddress: () async => wslStandIn);

      expect(
        server.mcpUrlFor('s1', environment: EnvironmentKind.windowsNative),
        startsWith('http://127.0.0.1:'),
      );
    });

    test('a WSL session is given the switch address instead', () async {
      server = await startServer(wslHostAddress: () async => wslStandIn);

      final url = server.mcpUrlFor('s1', environment: EnvironmentKind.wsl)!;
      expect(url, startsWith('http://${wslStandIn.address}:'));
      // The same port and the same session credential — one server, two doors.
      expect(
        Uri.parse(url).port,
        Uri.parse(
          server.mcpUrlFor('s1', environment: EnvironmentKind.windowsNative)!,
        ).port,
      );
      expect(server.callers.sessionFor(Uri.parse(url).pathSegments.last), 's1');
    });

    test('a WSL session on a host with no switch is given nothing', () async {
      // Rather than the loopback URL, which is refused from inside a
      // distribution: a session that cannot be wired launches as it always did.
      server = await startServer(wslHostAddress: () async => null);

      expect(server.mcpUrlFor('s1', environment: EnvironmentKind.wsl), isNull);
      expect(
        server.mcpUrlFor('s1', environment: EnvironmentKind.windowsNative),
        isNotNull,
      );
    });

    test('an SSH session is given nothing, on purpose', () async {
      // Every address this server listens on is local to the machine. Reaching
      // a remote host would mean binding an interface the LAN can see, and the
      // token in the URL opens the app's whole tool surface.
      server = await startServer(wslHostAddress: () async => wslStandIn);

      expect(server.mcpUrlFor('s1', environment: EnvironmentKind.ssh), isNull);
    });

    test(
      'nothing is offered anywhere when the endpoint has no credential',
      () async {
        final db = AppDatabase.memory();
        addTearDown(db.close);
        final closedContainer = ProviderContainer(
          overrides: [
            clockProvider.overrideWithValue(FixedClock(testTime)),
            databaseProvider.overrideWithValue(db),
          ],
        );
        final closed = LauncherControlServer(
          closedContainer,
          permissions: _RefusingPermissions(),
        );
        await closed.start(
          bridgeFilePath: p.join(tmp.path, 'closed.json'),
          socketDirectory: p.join(tmp.path, 'closed-ipc'),
          wslHostAddress: () async => wslStandIn,
          hostCanHaveWsl: true,
        );
        addTearDown(() async {
          await closed.stop();
          closedContainer.dispose();
        });

        expect(
          closed.mcpUrlFor('s1', environment: EnvironmentKind.wsl),
          isNull,
        );
        // The door is still bound, because `/agent-hook` is still served — the
        // same fail-*open* rule that keeps the hook route up on loopback when
        // hardening fails, since an agent that cannot report status is a worse
        // outcome than one that cannot drive a device. What it must not do is
        // serve `/mcp` there: a withheld credential is withheld on every door.
        expect(closed.wslHost, isNotNull);
        final port = closed.hookEndpoint!.port;
        expect(
          (await post(
            Uri.parse('http://${wslStandIn.address}:$port/mcp'),
            const <String, Object?>{},
          )).status,
          401,
        );
        expect(
          (await post(
            _switchHookUri(wslStandIn.address, port),
            const {'session_id': 's1'},
            token: closed.hookEndpoint!.token,
          )).status,
          200,
        );
      },
    );
  }, skip: skip);

  group('the second listener', () {
    test('answers /mcp', () async {
      server = await startServer(wslHostAddress: () async => wslStandIn);
      final url = server.mcpUrlFor('s1', environment: EnvironmentKind.wsl)!;

      final response = await post(Uri.parse(url), <String, Object?>{
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'tools/list',
        '_meta': <String, Object?>{
          'io.modelcontextprotocol/protocolVersion': '2026-07-28',
        },
      });

      expect(response.status, 200);
      final result =
          (jsonDecode(response.body) as Map<String, Object?>)['result']!
              as Map<String, Object?>;
      expect(result['tools'], isA<List<Object?>>());
    });

    test('answers 404 to everything else', () async {
      // The privileged `/rpc` envelope stays on loopback. Widening the address
      // is a decision about the two endpoints agents in a distribution need,
      // and this is where that stays true.
      server = await startServer(wslHostAddress: () async => wslStandIn);
      final port = Uri.parse(
        server.mcpUrlFor('s1', environment: EnvironmentKind.wsl)!,
      ).port;

      for (final path in ['/rpc', '/']) {
        final response = await post(
          Uri.parse('http://${wslStandIn.address}:$port$path'),
          const <String, Object?>{},
        );
        expect(response.status, 404, reason: path);
      }
    });

    test('still answers /agent-hook, for a hook an older build left', () async {
      // The installer no longer writes this address into a distribution's
      // endpoint file — those hooks report by spool — but one written by an
      // earlier build still names it, and a 404 there would be a hook firing
      // on every tool call and reporting nothing.
      server = await startServer(wslHostAddress: () async => wslStandIn);
      final endpoint = server.hookEndpoint!;

      final response = await post(
        _switchHookUri(wslStandIn.address, endpoint.port),
        const {'session_id': 's1'},
        token: endpoint.token,
      );

      expect(response.status, 200);
    });

    test('still demands the hook token on that door', () async {
      server = await startServer(wslHostAddress: () async => wslStandIn);
      final endpoint = server.hookEndpoint!;

      final response = await post(
        _switchHookUri(wslStandIn.address, endpoint.port),
        const {'session_id': 's1'},
        token: 'not-the-token',
      );

      expect(response.status, 401);
    });
  }, skip: skip);

  group('what the hook endpoint hands the installer for WSL', () {
    test('is a transport, and never this address', () async {
      // The switch address answers here — this is a stand-in loopback — and it
      // still must not be handed to a WSL agent, because on the machine this
      // was written for the real one completes the handshake and resets every
      // byte after it. A WSL hook writes a file instead.
      server = await startServer(wslHostAddress: () async => wslStandIn);

      expect(server.hookEndpoint!.hostFor(EnvironmentKind.wsl), isNull);
      expect(
        server.hookEndpoint!.transportFor(EnvironmentKind.wsl),
        isA<AgentHookSpoolTransport>(),
      );
      expect(
        server.hookEndpoint!.reaches(EnvironmentKind.wsl),
        isTrue,
        reason: 'this is what stops the installer skipping a WSL store',
      );
    });

    test('does not depend on the switch being bound at all', () async {
      // The whole point of the change: a host where the switch never came up
      // used to lose every WSL hook, and the file transport does not care.
      server = await startServer(wslHostAddress: () async => null);

      expect(server.hookEndpoint!.reaches(EnvironmentKind.wsl), isTrue);
      expect(
        server.hookEndpoint!.reaches(EnvironmentKind.windowsNative),
        isTrue,
      );
      expect(server.hookEndpoint!.reaches(EnvironmentKind.ssh), isFalse);
    });

    test(
      'the token is spelled in a shell command, so it stays shell-safe',
      () async {
        server = await startServer(wslHostAddress: () async => wslStandIn);
        // It is pasted verbatim into a `curl` line in the agent's own config and
        // run by whatever shell that agent has. A quote, a `$` or a backtick in
        // it would be a malformed hook in somebody's settings.json — installed,
        // silent, and reported by nothing.
        expect(
          server.hookEndpoint!.token,
          matches(RegExp(r'^[A-Za-z0-9_=-]+$')),
        );
      },
    );
  }, skip: skip);
}

/// One JSON POST, returning the status and the body.
Future<({int status, String body})> post(
  Uri uri,
  Object? body, {
  String? token,
}) async {
  final client = HttpClient();
  try {
    final request = await client.postUrl(uri);
    request.headers.contentType = ContentType.json;
    request.headers.set(
      HttpHeaders.acceptHeader,
      'application/json, text/event-stream',
    );
    if (token != null) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    }
    request.write(jsonEncode(body));
    final response = await request.close();
    return (
      status: response.statusCode,
      body: await response.transform(utf8.decoder).join(),
    );
  } finally {
    client.close(force: true);
  }
}

/// The `/agent-hook` URL on the switch listener, spelled out here because the
/// endpoint no longer builds one: a WSL agent is given a spool directory, and
/// this door survives only for a hook an earlier build installed.
Uri _switchHookUri(String host, int port) =>
    Uri.parse('http://$host:$port/agent-hook?agent=claudeCode&event=Stop');

/// Hardening that never applies, so nothing privileged is minted or served.
class _RefusingPermissions extends HandshakePermissions {
  @override
  Future<bool> restrictDirectory(Directory dir, {AppLogger? logger}) async =>
      false;

  @override
  Future<bool> restrictFile(File file, {AppLogger? logger}) async => false;
}
