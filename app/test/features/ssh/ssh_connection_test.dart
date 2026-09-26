import 'dart:io';

import 'package:karmashala_store/database.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/features/ssh/data/known_host_dao.dart';
import 'package:karmashala_ssh/connection.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';

SshHost host({
  int port = 1,
  SshAuthMethod auth = SshAuthMethod.privateKey,
  EnvironmentPath? key = const EnvironmentPath(
    environmentId: 'windows',
    path: r'C:\keys\id_ed25519',
  ),
}) => SshHost(
  id: 'h1',
  name: 'closed-port',
  host: '127.0.0.1',
  port: port,
  username: 'dev',
  authMethod: auth,
  privateKey: key,
  createdAt: testTime,
);

void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase.memory());
  tearDown(() => db.close());

  SshConnection connection({
    SshHost? on,
    PrivateKeyReader? keyReader,
    SshSecretPrompt? passwordPrompt,
    int maxAttempts = 2,
  }) {
    final target = on ?? host();
    return SshConnection(
      host: target,
      verifier: SshHostKeyVerifier(
        knownHosts: KnownHostDao(db),
        host: target.host,
        port: target.port,
        clock: FixedClock(testTime),
      ),
      keyReader: keyReader ?? (_) async => 'not-a-real-key',
      passwordPrompt: passwordPrompt,
      maxAttempts: maxAttempts,
      connectTimeout: const Duration(seconds: 2),
    );
  }

  group('readLocalPrivateKey', () {
    test('refuses a key recorded in a remote environment', () {
      expect(
        () => readLocalPrivateKey(
          const EnvironmentPath(
            environmentId: 'ssh:h1',
            path: '/home/dev/.ssh/id_ed25519',
          ),
        ),
        throwsA(
          isA<SshConnectionException>().having(
            (e) => e.message,
            'message',
            contains('must live on a local environment'),
          ),
        ),
      );
    });

    test('reports a missing key file rather than a decode error later', () {
      expect(
        () => readLocalPrivateKey(
          const EnvironmentPath(
            environmentId: 'windows',
            path: r'C:\definitely\missing\key',
          ),
        ),
        throwsA(isA<SshConnectionException>()),
      );
    });
  });

  group('connect failures', () {
    // A server that accepts the TCP connection and then hangs up, which is what
    // a flaky link looks like from the client's side: reachable, then not.
    late ServerSocket rude;

    setUp(() async {
      rude = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      rude.listen((socket) => socket.destroy());
    });
    tearDown(() => rude.close());

    test('a dropped handshake retries, then fails loudly', () async {
      // Password auth so nothing is read from disk and the failure is purely
      // the transport dying mid-handshake.
      final c = connection(
        on: host(port: rude.port, auth: SshAuthMethod.password, key: null),
        passwordPrompt: (_) => 'never-sent',
      );
      final states = <SshConnectionState>[];
      c.states.listen(states.add);

      await expectLater(
        c.client(),
        throwsA(
          isA<SshConnectionException>()
              .having((e) => e.retryable, 'retryable', isTrue)
              .having(
                (e) => e.message,
                'message',
                contains('after 2 attempts'),
              ),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(c.isConnected, isFalse);
      expect(c.state.status, SshConnectionStatus.failed);
      expect(
        states.map((s) => s.status),
        containsAllInOrder([
          SshConnectionStatus.connecting,
          SshConnectionStatus.disconnected,
          SshConnectionStatus.connecting,
          SshConnectionStatus.failed,
        ]),
      );
      // The retry is announced with its wait, not silently slept through.
      final retry = states.firstWhere(
        (s) => s.status == SshConnectionStatus.disconnected,
      );
      expect(retry.nextRetryIn, reconnectBackoff(1));
      await c.close();
    });

    test(
      'a key host with no key path fails before touching the network',
      () async {
        final c = connection(on: host(port: rude.port, key: null));
        await expectLater(
          c.client(),
          throwsA(
            isA<SshConnectionException>()
                .having((e) => e.retryable, 'retryable', isFalse)
                .having(
                  (e) => e.message,
                  'message',
                  contains('no private key'),
                ),
          ),
        );
        expect(c.state.status, SshConnectionStatus.failed);
        await c.close();
      },
    );

    test(
      'a private key that cannot be decoded says so without echoing it',
      () async {
        final c = connection(
          on: host(port: rude.port),
          keyReader: (_) async =>
              '-----BEGIN OPENSSH PRIVATE KEY-----\nSUPERSECRET\n'
              '-----END OPENSSH PRIVATE KEY-----\n',
        );
        try {
          await c.client();
          fail('expected a connection failure');
        } on SshConnectionException catch (e) {
          expect(e.message, contains('could not be decoded'));
          expect(e.toString(), isNot(contains('SUPERSECRET')));
          expect(e.retryable, isFalse);
        }
        await c.close();
      },
    );

    test('a closed connection refuses to hand out a client', () async {
      final c = connection(
        on: host(port: rude.port, auth: SshAuthMethod.password, key: null),
      );
      await c.close();
      expect(c.client, throwsA(isA<SshConnectionException>()));
    });
  });
}
