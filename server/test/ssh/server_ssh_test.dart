import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_environments/ssh.dart';
import 'package:karmashala_host/data.dart';
import 'package:karmashala_host/src/ssh/server_ssh.dart';
import 'package:karmashala_store/database.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// The server's own SSH (slice 3a), through the data API as a client asks
/// it: a test connection, a disconnect, and a question put to the desktop
/// clients — answered by one, closed for all, the secret told to nobody. No
/// SSH server is dialled: the host is a closed port on this machine, and a
/// passphrase is asked before any socket opens.
void main() {
  final now = DateTime.utc(2026, 9, 27, 12);
  late Directory temp;
  late AppDatabase db;
  late DataService data;
  late ServerSsh ssh;
  late int closedPort;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('karmashala_server_ssh_');
    db = AppDatabase.memory();
    data = DataService(db, clock: () => now)
      ..ensureEnvironment(localHostEnvironment(now));
    ssh = ServerSsh(data: data, database: db)..attach();
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    closedPort = socket.port;
    await socket.close();
  });

  tearDown(() async {
    await ssh.close();
    db.close();
    temp.deleteSync(recursive: true);
  });

  SshHost host({
    SshAuthMethod auth = SshAuthMethod.password,
    EnvironmentPath? key,
  }) => SshHost(
    id: 'h1',
    name: 'box',
    host: '127.0.0.1',
    port: closedPort,
    username: 'dev',
    authMethod: auth,
    privateKey: key,
    createdAt: now,
  );

  ({DataSession link, List<DataChange> told}) client() {
    final told = <DataChange>[];
    final link = data.open((batch) => told.addAll(batch.changes));
    link.handle(const DataSubscribe());
    return (link: link, told: told);
  }

  /// An ed25519 key encrypted with [passphrase], made by this machine's
  /// `ssh-keygen` in the temp folder; null where there is none.
  EnvironmentPath? encryptedKey(String passphrase) {
    final path = p.join(temp.path, 'id_ed25519');
    try {
      final made = Process.runSync('ssh-keygen', [
        '-q',
        '-t',
        'ed25519',
        // One KDF round: dartssh2 decrypts in pure Dart, and the default
        // sixteen take longer than a test may.
        '-a',
        '1',
        '-N',
        passphrase,
        '-f',
        path,
      ]);
      if (made.exitCode != 0) return null;
    } on ProcessException {
      return null;
    }
    return EnvironmentPath(environmentId: localHostEnvironmentId, path: path);
  }

  test('a test connection that cannot reach the host says so', () async {
    final reply = await data.open((_) {}).handleLater(SshTest(draft: host()));
    expect(reply.value.connected, isFalse);
    expect(reply.value.message, contains('127.0.0.1'));
    expect(reply.value.rejectedKey, isNull);
  });

  test('a saved host is tested by id; an unknown id is refused', () async {
    final link = data.open((_) {});
    link.handle(SshHostPut(host()));
    final reply = await link.handleLater(const SshTest(hostId: 'h1'));
    expect(reply.value.connected, isFalse);
    expect(
      () => link.handleLater(const SshTest(hostId: 'ghost')),
      throwsA(isA<DataRefused>()),
    );
  });

  test('with no desktop client a passphrase is not asked, and the words say '
      'where to answer', () async {
    final key = encryptedKey('correct horse');
    if (key == null) {
      markTestSkipped('no ssh-keygen here to make an encrypted key');
      return;
    }
    final reply = await data
        .open((_) {})
        .handleLater(
          SshTest(
            draft: host(auth: SshAuthMethod.privateKey, key: key),
          ),
        );
    expect(reply.value.connected, isFalse);
    expect(reply.value.message, contains('Open Karmashala on any device'));
  });

  test('a passphrase is asked of every client, the first answer wins, and '
      'the secret is told to nobody', () async {
    const passphrase = 'correct horse';
    final key = encryptedKey(passphrase);
    if (key == null) {
      markTestSkipped('no ssh-keygen here to make an encrypted key');
      return;
    }
    final first = client();
    final second = client();
    final answering = data.open((_) {});

    final testing = answering.handleLater(
      SshTest(
        draft: host(auth: SshAuthMethod.privateKey, key: key),
      ),
    );
    await pumpUntil(() => first.told.whereType<SshPromptOpened>().isNotEmpty);
    final prompt = first.told.whereType<SshPromptOpened>().single;
    expect(prompt.kind, SshPromptKind.passphrase);
    expect(prompt.address, 'dev@127.0.0.1:$closedPort');
    expect(second.told.whereType<SshPromptOpened>(), hasLength(1));

    await second.link.handleLater(
      SshAnswerPrompt(prompt.promptId, secret: passphrase),
    );
    expect(
      () => first.link.handleLater(
        SshAnswerPrompt(prompt.promptId, secret: 'too late'),
      ),
      throwsA(
        isA<DataRefused>().having(
          (r) => r.code,
          'code',
          DataRefusalCode.notFound,
        ),
      ),
    );

    // The key opened with it; only the closed port stops the connection.
    final result = (await testing).value;
    expect(result.connected, isFalse);
    expect(result.message, contains('127.0.0.1'));
    expect(result.message, isNot(contains('decoded')));
    for (final told in [first.told, second.told]) {
      expect(told.whereType<SshPromptClosed>(), hasLength(1));
      expect(
        jsonEncode([for (final c in told) c.toJson()]),
        isNot(contains(passphrase)),
      );
    }
    expect(jsonEncode(result.toJson()), isNot(contains(passphrase)));
  });

  test('a client that joins while a question is open is told it', () async {
    final key = encryptedKey('pass');
    if (key == null) {
      markTestSkipped('no ssh-keygen here to make an encrypted key');
      return;
    }
    final first = client();
    final testing = data
        .open((_) {})
        .handleLater(
          SshTest(
            draft: host(auth: SshAuthMethod.privateKey, key: key),
          ),
        );
    await pumpUntil(() => first.told.whereType<SshPromptOpened>().isNotEmpty);

    final late = client();
    final prompt = late.told.whereType<SshPromptOpened>().single;
    await late.link.handleLater(SshAnswerPrompt(prompt.promptId));
    expect((await testing).value.connected, isFalse);
  });

  test(
    'a pooled connection\'s state is told, and a disconnect is idle',
    () async {
      final watcher = client();
      data.open((_) {}).handle(SshHostPut(host()));
      final runner = ssh.runners.forEnvironment(
        data.environments.firstWhere((e) => e.id == sshEnvironmentId('h1')),
      );
      await expectLater(
        runner.run(const CommandRequest(executable: 'true')),
        throwsA(anything),
      );
      await pumpUntil(
        () =>
            watcher.told
                .whereType<SshConnectionChanged>()
                .lastOrNull
                ?.state
                .status ==
            SshConnectionStatus.failed,
      );
      final states = watcher.told.whereType<SshConnectionChanged>().toList();
      expect(states.first.state.status, SshConnectionStatus.connecting);
      expect(states.last.state.status, SshConnectionStatus.failed);

      await data.open((_) {}).handleLater(const SshDisconnect('h1'));
      expect(
        watcher.told.whereType<SshConnectionChanged>().last.state.status,
        SshConnectionStatus.idle,
      );
    },
  );
}

Future<void> pumpUntil(bool Function() done) async {
  for (var i = 0; i < 200 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(done(), isTrue, reason: 'waited 2 s');
}
