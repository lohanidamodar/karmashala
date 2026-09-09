import 'dart:convert';
import 'dart:io';

import 'package:karmashala_core/logging.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/application/agent_status_providers.dart';
import 'package:karmashala/src/features/mcp/control_server_status.dart';
import 'package:karmashala/src/features/mcp/handshake_file_permissions.dart';
import 'package:karmashala/src/features/mcp/launcher_control_server.dart';
import 'package:karmashala_local_ipc/karmashala_local_ipc.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:agent_cli/process.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// What the control server does when the owner-only boundary cannot be
/// established.
///
/// The real-ACL tests in `handshake_file_permissions_test.dart` prove that
/// `icacls` works when it works. They cannot prove anything about the branch
/// that matters most: a permission call that returns `false`. The 2026-08-30
/// audit found that branch was being read and discarded — the directory ACL
/// result was ignored and the socket bound anyway, and the handshake wrote
/// cleartext tokens whether or not it could be locked down — precisely because
/// nothing could reach it. `HandshakePermissions` is the seam that fixes that,
/// and these are the assertions it exists for.
///
/// The invariant every case here checks is the same one: **no privileged
/// transport and no privileged credential is published**. `/agent-hook`, which
/// is deliberately low-privilege and whose token the threat model already
/// treats as public to this user, keeps working.
void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('karmashala_failclosed_'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  String bridgePath() => p.join(tmp.path, 'mcp_bridge.json');
  String socketDir() => p.join(tmp.path, 'ipc');

  ProviderContainer makeContainer() => ProviderContainer(
    overrides: [clockProvider.overrideWithValue(FixedClock(testTime))],
  );

  Map<String, Object?> handshake() =>
      jsonDecode(File(bridgePath()).readAsStringSync()) as Map<String, Object?>;

  /// Every assertion that together mean "nothing privileged got out".
  void expectNothingPrivilegedPublished() {
    final json = handshake();
    expect(
      json.containsKey('token'),
      isFalse,
      reason: 'the privileged credential must not reach the handshake',
    );
    expect(
      json.containsKey('socketPath'),
      isFalse,
      reason: 'the privileged transport must not be advertised',
    );
    // The hook half is still published: failing *closed* is about privilege,
    // not about taking status reporting away.
    expect(json['hookToken'], isA<String>());
    expect(json['port'], isA<int>());
    expect(json['pid'], pid);
    // And no socket node was left behind for anyone to find.
    expect(File(p.join(socketDir(), 'rpc.sock')).existsSync(), isFalse);
  }

  /// `POST` to the loopback server with an arbitrary bearer token.
  Future<HttpClientResponse> postRpc(int port, String? token) async {
    final client = HttpClient();
    try {
      final request = await client.postUrl(
        Uri.parse('http://127.0.0.1:$port/rpc'),
      );
      if (token != null) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      }
      request.write(jsonEncode({'tool': '__list_tools__'}));
      final response = await request.close();
      await response.drain<void>();
      return response;
    } finally {
      client.close(force: true);
    }
  }

  group('the socket directory ACL does not apply', () {
    late ProviderContainer container;
    late LauncherControlServer server;
    late _FakePermissions permissions;

    setUp(() async {
      container = makeContainer();
      permissions = _FakePermissions(directoryResult: false);
      server = LauncherControlServer(container, permissions: permissions);
      await server.start(
        bridgeFilePath: bridgePath(),
        socketDirectory: socketDir(),
      );
    });

    tearDown(() async {
      await server.stop();
      container.dispose();
    });

    test('the socket is never bound and nothing privileged is published', () {
      expect(permissions.directoryCalls, hasLength(1));
      expectNothingPrivilegedPublished();
    });

    test('the status names the stage that failed', () {
      final status = container.read(controlServerStatusProvider);
      expect(status.failedClosed, isTrue);
      expect(status.privilegedRpcAvailable, isFalse);
      expect(
        status.failureStage,
        ControlServerFailureStage.socketDirectoryPermissions,
      );
      expect(status.failureDetail, contains(socketDir()));
      expect(status.message, contains('Agent tools are off'));
      expect(status.hookEndpointAvailable, isTrue);
      expect(server.status, status);
    });

    test('/rpc over loopback stays shut, with or without a token', () async {
      final port = handshake()['port']! as int;
      // 404 would still be a leak of "the route exists but you got the token
      // wrong"; the point is that no request reaches a dispatcher.
      expect((await postRpc(port, null)).statusCode, HttpStatus.unauthorized);
      expect(
        (await postRpc(port, 'anything')).statusCode,
        HttpStatus.unauthorized,
      );
      // The interpolation hole: with no token minted, `Bearer $_token` used to
      // render as the literal string below, which anyone could send.
      expect((await postRpc(port, 'null')).statusCode, HttpStatus.unauthorized);
    });

    test('the low-privilege hook endpoint still answers', () async {
      final endpoint = server.hookEndpoint!;
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final request = await client.postUrl(
        endpoint.uriFor(
        agentId: 'claudeCode',
        event: 'Stop',
        environment: EnvironmentKind.windowsNative,
      )!,
      );
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer ${endpoint.token}',
      );
      request.write('{"session_id":"s1"}');
      final response = await request.close();
      await response.drain<void>();

      expect(response.statusCode, HttpStatus.ok);
      expect(
        container.read(agentHookReportsProvider).latest('claudeCode', 's1'),
        isNotNull,
      );
    });
  });

  group('the permission call throws instead of returning', () {
    test('is treated exactly like a refusal', () async {
      final container = makeContainer();
      final server = LauncherControlServer(
        container,
        permissions: _FakePermissions(
          directoryError: const FileSystemException('icacls is not on PATH'),
        ),
      );
      await server.start(
        bridgeFilePath: bridgePath(),
        socketDirectory: socketDir(),
      );
      addTearDown(() async {
        await server.stop();
        container.dispose();
      });

      expectNothingPrivilegedPublished();
      final status = container.read(controlServerStatusProvider);
      expect(status.failedClosed, isTrue);
      expect(status.failureStage, ControlServerFailureStage.socketBind);
      expect(status.failureDetail, contains('icacls is not on PATH'));
    });

    test('a throwing handshake ACL withholds the token too', () async {
      final container = makeContainer();
      final server = LauncherControlServer(
        container,
        permissions: _FakePermissions(
          fileError: const FileSystemException('access is denied'),
        ),
      );
      await server.start(
        bridgeFilePath: bridgePath(),
        socketDirectory: socketDir(),
      );
      addTearDown(() async {
        await server.stop();
        container.dispose();
      });

      expectNothingPrivilegedPublished();
      final status = container.read(controlServerStatusProvider);
      expect(
        status.failureStage,
        ControlServerFailureStage.handshakePermissions,
      );
      expect(status.failureDetail, contains('access is denied'));
    });
  });

  group('a partial ACL failure: the directory applies, the file does not', () {
    late ProviderContainer container;
    late LauncherControlServer server;
    late _FakePermissions permissions;

    setUp(() async {
      container = makeContainer();
      // The Windows shape of this is an `icacls /grant` that succeeds followed
      // by an `/inheritance:r` that does not, on one of the two entities.
      permissions = _FakePermissions(fileResult: false);
      server = LauncherControlServer(container, permissions: permissions);
      await server.start(
        bridgeFilePath: bridgePath(),
        socketDirectory: socketDir(),
      );
    });

    tearDown(() async {
      await server.stop();
      container.dispose();
    });

    test('the token is withheld and the bound socket is taken back down', () {
      expect(permissions.directoryCalls, hasLength(1));
      expect(permissions.fileCalls, hasLength(1));
      expectNothingPrivilegedPublished();
    });

    test('the socket stops answering, not just advertising', () async {
      expect(
        () => LocalRpcClient.call(
          p.join(socketDir(), 'rpc.sock'),
          jsonEncode({'tool': '__list_tools__'}),
          timeout: const Duration(seconds: 5),
        ),
        throwsA(isA<SocketException>()),
      );
    });

    test('the status names the handshake stage', () {
      final status = container.read(controlServerStatusProvider);
      expect(
        status.failureStage,
        ControlServerFailureStage.handshakePermissions,
      );
      expect(status.message, contains('handshake file'));
    });
  });

  group('when hardening applies', () {
    test('the socket and its credential are published as before', () async {
      final container = makeContainer();
      final permissions = _FakePermissions();
      final server = LauncherControlServer(container, permissions: permissions);
      await server.start(
        bridgeFilePath: bridgePath(),
        socketDirectory: socketDir(),
      );
      addTearDown(() async {
        await server.stop();
        container.dispose();
      });

      final json = handshake();
      expect(json['token'], isA<String>());
      expect(json['socketPath'], isA<String>());
      expect(File(json['socketPath']! as String).existsSync(), isTrue);
      expect(
        container.read(controlServerStatusProvider).transport,
        PrivilegedRpcTransport.ownerOnlySocket,
      );
      expect(container.read(controlServerStatusProvider).failedClosed, isFalse);

      // And it really dispatches — the fail-closed rework must not have cost
      // the working path.
      final raw = await LocalRpcClient.call(
        json['socketPath']! as String,
        jsonEncode({
          'tool': '__list_tools__',
          'arguments': const <String, Object?>{},
          'token': json['token'],
        }),
      );
      expect((jsonDecode(raw) as Map)['ok'], isTrue);
    });

    test('the deliberate loopback opt-out is still a running state', () async {
      final container = makeContainer();
      final server = LauncherControlServer(
        container,
        permissions: _FakePermissions(),
      );
      await server.start(bridgeFilePath: bridgePath(), useLocalSocket: false);
      addTearDown(() async {
        await server.stop();
        container.dispose();
      });

      expect(handshake()['token'], isA<String>());
      expect(
        container.read(controlServerStatusProvider).transport,
        PrivilegedRpcTransport.loopbackHttp,
      );
    });

    test('a failed handshake ACL closes the loopback opt-out too', () async {
      final container = makeContainer();
      final server = LauncherControlServer(
        container,
        permissions: _FakePermissions(fileResult: false),
      );
      await server.start(bridgeFilePath: bridgePath(), useLocalSocket: false);
      addTearDown(() async {
        await server.stop();
        container.dispose();
      });

      expect(handshake().containsKey('token'), isFalse);
      final port = handshake()['port']! as int;
      expect((await postRpc(port, 'null')).statusCode, HttpStatus.unauthorized);
    });
  });

  group('status lifecycle', () {
    test('stop() returns the status to not-running', () async {
      final container = makeContainer();
      addTearDown(container.dispose);
      final server = LauncherControlServer(
        container,
        permissions: _FakePermissions(),
      );
      expect(
        container.read(controlServerStatusProvider),
        ControlServerStatus.notStarted,
      );

      await server.start(
        bridgeFilePath: bridgePath(),
        socketDirectory: socketDir(),
      );
      expect(
        container.read(controlServerStatusProvider).privilegedRpcAvailable,
        isTrue,
      );

      await server.stop();
      expect(
        container.read(controlServerStatusProvider),
        ControlServerStatus.notStarted,
      );
    });

    test('a restart after a failure can recover', () async {
      final container = makeContainer();
      addTearDown(container.dispose);
      final permissions = _FakePermissions(directoryResult: false);
      final server = LauncherControlServer(container, permissions: permissions);
      await server.start(
        bridgeFilePath: bridgePath(),
        socketDirectory: socketDir(),
      );
      expect(container.read(controlServerStatusProvider).failedClosed, isTrue);

      await server.stop();
      permissions.directoryResult = true;
      await server.start(
        bridgeFilePath: bridgePath(),
        socketDirectory: socketDir(),
      );
      addTearDown(server.stop);

      expect(
        container.read(controlServerStatusProvider).transport,
        PrivilegedRpcTransport.ownerOnlySocket,
      );
      expect(handshake()['token'], isA<String>());
    });
  });
}

/// A [HandshakePermissions] whose answers the test chooses.
///
/// It also records what it was asked to restrict, so a test can assert that the
/// server asked at all — an implementation that skipped the call entirely would
/// otherwise pass the "nothing was published" assertions for the wrong reason.
class _FakePermissions extends HandshakePermissions {
  _FakePermissions({
    this.directoryResult = true,
    this.fileResult = true,
    this.directoryError,
    this.fileError,
  });

  bool directoryResult;
  bool fileResult;
  Object? directoryError;
  Object? fileError;

  final List<String> directoryCalls = [];
  final List<String> fileCalls = [];

  @override
  Future<bool> restrictDirectory(Directory dir, {AppLogger? logger}) async {
    directoryCalls.add(dir.path);
    if (directoryError case final error?) throw error;
    return directoryResult;
  }

  @override
  Future<bool> restrictFile(File file, {AppLogger? logger}) async {
    fileCalls.add(file.path);
    if (fileError case final error?) throw error;
    return fileResult;
  }
}
