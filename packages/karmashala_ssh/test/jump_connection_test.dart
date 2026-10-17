import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent_cli/process.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:karmashala_ssh/connection.dart';
import 'package:test/test.dart';

import 'support.dart';

/// A transport that answers with [reply] and then closes — enough to see
/// which socket a connection used, without an SSH server.
class _ScriptedSocket implements SSHSocket {
  _ScriptedSocket(List<int> reply) {
    scheduleMicrotask(() {
      _incoming
        ..add(Uint8List.fromList(reply))
        ..close();
    });
  }

  final _incoming = StreamController<Uint8List>();
  final _outgoing = StreamController<List<int>>();
  final _done = Completer<void>();

  @override
  Stream<Uint8List> get stream => _incoming.stream;

  @override
  StreamSink<List<int>> get sink => _outgoing.sink;

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> close() async {
    if (!_done.isCompleted) _done.complete();
  }

  @override
  void destroy() {
    if (!_done.isCompleted) _done.complete();
  }

  @override
  Future<void> flush() async {}
}

const _key = EnvironmentPath(
  environmentId: 'windows',
  path: r'C:\keys\id_ed25519',
);

SshHost _jumpHost(int port) => SshHost(
  id: 'box',
  name: 'build-box',
  host: '127.0.0.1',
  port: port,
  username: 'dev',
  authMethod: SshAuthMethod.privateKey,
  privateKey: _key,
  createdAt: testTime,
);

SshHost _container({String via = 'box'}) => SshHost(
  id: 'c1',
  name: 'sandbox',
  host: '127.0.0.1',
  port: 41022,
  username: 'karma',
  authMethod: SshAuthMethod.privateKey,
  privateKey: _key,
  createdAt: testTime,
  viaHostId: via,
  container: const SshContainer(
    environmentId: 'ssh:box',
    name: 'ks-sandbox',
    id: 'abc',
    image: 'ubuntu:24.04',
    cpus: 2,
    memoryMb: 4096,
  ),
);

Future<int> _closedPort() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = server.port;
  await server.close();
  return port;
}

void main() {
  test('a connection runs SSH over the socket its opener gives it', () async {
    final opened = <String>[];
    final connection = SshConnection(
      host: _container(),
      verifier: SshHostKeyVerifier(
        knownHosts: MemoryKnownHosts(),
        host: 'container:c1',
        port: 41022,
        clock: FixedClock(testTime),
      ),
      keyReader: (_) async => _validKey,
      openSocket: (host) async {
        opened.add('${host.host}:${host.port}');
        return _ScriptedSocket('SSH-1.0-not-a-server\r\n'.codeUnits);
      },
      maxAttempts: 1,
      connectTimeout: const Duration(seconds: 2),
    );
    addTearDown(connection.close);

    // Nothing listens on 127.0.0.1:41022 here: the handshake fails on the
    // scripted bytes, which only the opener's socket carries.
    await expectLater(
      connection.client(),
      throwsA(isA<SshConnectionException>()),
    );
    expect(opened, ['127.0.0.1:41022']);
  });

  test(
    'a container is dialled through its jump host, never directly',
    () async {
      final hosts = MemoryHosts()
        ..upsert(_jumpHost(await _closedPort()))
        ..upsert(_container());
      final pool = SshConnectionPool(
        hosts: hosts,
        knownHosts: MemoryKnownHosts(),
        keyReader: (_) async => _validKey,
      );
      addTearDown(pool.closeAll);

      await expectLater(
        pool.forHostId('c1').client(),
        throwsA(
          isA<SshConnectionException>().having(
            (e) => e.message,
            'message',
            allOf(contains('127.0.0.1:41022'), contains('Cannot reach')),
          ),
        ),
      );
      // The jump host was dialled, and that is what failed.
      expect(pool.forHostId('box').state.status, SshConnectionStatus.failed);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test('a container pins its key under its own name, not 127.0.0.1', () {
    final pool = SshConnectionPool(
      hosts: MemoryHosts(),
      knownHosts: MemoryKnownHosts(),
    );
    final verifier = pool.create(_container()).verifier;
    expect(verifier.host, 'container:c1');
    expect(verifier.onUnknownHostKey, isNotNull);
    expect(pool.create(_jumpHost(22)).verifier.host, '127.0.0.1');
  });

  test('a container pins a new key without asking, and refuses a changed '
      'one', () async {
    final known = MemoryKnownHosts();
    final pool = SshConnectionPool(hosts: MemoryHosts(), knownHosts: known);
    final verifier = pool.create(_container()).verifier;
    final first = Uint8List.fromList('SHA256:first'.codeUnits);
    final second = Uint8List.fromList('SHA256:second'.codeUnits);
    expect(await verifier.verify('ssh-ed25519', first), isTrue);
    expect(known.find('container:c1', 41022)!.fingerprint, 'SHA256:first');
    expect(await verifier.verify('ssh-ed25519', second), isFalse);
  });

  test('a host set to jump through itself is refused', () async {
    final pool = SshConnectionPool(
      hosts: MemoryHosts()..upsert(_container(via: 'c1')),
      knownHosts: MemoryKnownHosts(),
      keyReader: (_) async => _validKey,
    );
    addTearDown(pool.closeAll);
    await expectLater(
      pool.forHostId('c1').client(),
      throwsA(
        isA<SshConnectionException>().having(
          (e) => e.message,
          'message',
          contains('jump through itself'),
        ),
      ),
    );
  });
}

/// A throwaway unencrypted ed25519 key, generated for these tests only.
final _validKey = OpenSSHEd25519KeyPair(
  Uint8List(32),
  Uint8List(64),
  'test',
).toPem();
