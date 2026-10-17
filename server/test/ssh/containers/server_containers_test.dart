import 'dart:async';
import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:karmashala_containers/karmashala_containers.dart';
import 'package:karmashala_core/logging.dart';
import 'package:karmashala_core/util.dart' show Clock;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_environments/ssh.dart';
import 'package:karmashala_environments/store.dart' show KnownHostDao;
import 'package:karmashala_host/data.dart';
import 'package:karmashala_host/src/ssh/containers/server_containers.dart';
import 'package:karmashala_host/src/ssh/ssh_domain.dart';
import 'package:karmashala_mcp/access.dart' show HandshakePermissions;
import 'package:karmashala_store/database.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../support/fake_command_runner.dart';

/// Owner-only is the platform's job; here it always succeeds.
class _Permissive extends HandshakePermissions {
  const _Permissive();

  @override
  Future<bool> restrictFile(File file, {AppLogger? logger}) async => true;

  @override
  Future<bool> restrictDirectory(Directory dir, {AppLogger? logger}) async =>
      true;
}

/// A streamed script: answers once the script has been written and stdin
/// closed, as `sh -s` would.
class _ScriptHandle extends FakeProcessHandle {
  _ScriptHandle(this.answer);

  final ({List<String> lines, int code}) Function(String script) answer;

  @override
  Future<void> closeStdin() async {
    await super.closeStdin();
    final reply = answer(written.join('\n'));
    scheduleMicrotask(() {
      reply.lines.forEach(emitStdout);
      complete(reply.code);
    });
  }
}

/// A Docker host as the scripts see it, scripted per test.
class _DockerHost {
  String check =
      'user=karma\narch=x86_64\ncores=8\nmemfree_kb=8388608\n'
      'docker_rc=0\ndocker_out=27.3.1\ndiskfree_kb=99999999\n';
  String listening = 'LISTEN 0 128 127.0.0.1:41000 0.0.0.0:*';
  String volumeExists = 'no';
  CommandResult runResult = const CommandResult(
    exitCode: 0,
    stdout: 'abc123def\n',
    stderr: '',
  );
  CommandResult deleteResult = const CommandResult(
    exitCode: 0,
    stdout: '',
    stderr: '',
  );
  int pullCode = 0;
  ({List<String> lines, int code}) setup = (
    lines: ['karmashala: installing ssh', 'KARMASHALA-READY'],
    code: 0,
  );

  final scripts = <String>[];

  late final runner = FakeCommandRunner(
    environmentId: 'any',
    responder: (request) {
      final script = request.stdinText ?? '';
      scripts.add(script);
      CommandResult ok(String out) =>
          CommandResult(exitCode: 0, stdout: out, stderr: '');
      if (script.contains('docker version')) return ok(check);
      if (script.contains('ss -Htln')) return ok(listening);
      if (script.contains('docker volume inspect') &&
          script.contains('echo yes')) {
        return ok(volumeExists);
      }
      if (script.contains('docker run -d')) return runResult;
      if (script.contains('rm -f -v')) return deleteResult;
      if (script.contains('.State.Status')) return ok('running\n');
      return ok('');
    },
    processFactory: (_) => _ScriptHandle((script) {
      scripts.add(script);
      if (script.contains('docker pull')) {
        return (lines: ['Pulling from library/ubuntu'], code: pullCode);
      }
      return setup;
    }),
  );
}

void main() {
  final now = DateTime.utc(2026, 10, 17, 12);
  late Directory temp;
  late AppDatabase db;
  late DataService data;
  late ServerSshDomain ssh;
  late _DockerHost docker;
  late List<String> connected;
  late List<String> detected;
  late ServerContainers containers;
  late List<ContainerProgress> progress;

  const spec = ContainerSpec(
    name: 'sandbox',
    distro: ContainerDistro.ubuntu2404,
    cpus: 2,
    memoryMb: 2048,
    agents: [ContainerAgentCli.codex],
  );

  setUp(() {
    temp = Directory.systemTemp.createTempSync('karmashala_containers_');
    db = AppDatabase.memory();
    data = DataService(db, clock: () => now)
      ..ensureEnvironment(localHostEnvironment(now))
      ..ensureEnvironment(
        ExecutionEnvironment(
          id: 'wsl:probe',
          kind: EnvironmentKind.wsl,
          name: 'probe',
          wslDistribution: 'probe',
          createdAt: now,
        ),
      );
    data.applyAsServer(
      SshHostPut(
        SshHost(
          id: 'box',
          name: 'build-box',
          host: 'build.example',
          port: 22,
          username: 'karma',
          authMethod: SshAuthMethod.privateKey,
          privateKey: const EnvironmentPath(
            environmentId: 'windows',
            path: r'C:\keys\id',
          ),
          createdAt: now,
        ),
      ),
    );
    ssh = ServerSshDomain(data: data, database: db, dataDirectory: temp.path);
    docker = _DockerHost();
    connected = [];
    detected = [];
    progress = [];
    data
        .open(
          (batch) =>
              progress.addAll(batch.changes.whereType<ContainerProgress>()),
        )
        .handle(const DataSubscribe());
    containers = ServerContainers(
      data: data,
      ssh: ssh.ssh,
      dataDirectory: temp.path,
      permissions: const _Permissive(),
      clock: _Fixed(now),
      runnerFor: (_) => docker.runner,
      connect: (hostId) async => connected.add(hostId),
    )..detectAgents = (environmentId) async => detected.add(environmentId);
  });

  tearDown(() async {
    await ssh.close();
    db.close();
    temp.deleteSync(recursive: true);
  });

  File keyOf(String machineId) =>
      File(p.join(temp.path, 'containers', 'keys', machineId));

  test('a container on WSL is reached at localhost, with a key of its '
      'own', () async {
    final host = await containers.create(
      environmentId: 'wsl:probe',
      machineId: 'm1',
      spec: spec,
    );
    expect(host.host, 'localhost');
    expect(host.port, 41001, reason: '41000 is listening');
    expect(host.viaHostId, isNull);
    expect(host.username, kContainerUser);
    expect(host.container!.environmentId, 'wsl:probe');
    expect(host.container!.name, 'ks-sandbox');
    expect(host.container!.id, 'abc123def');
    expect(host.container!.agents, ['codex']);
    expect(host.privateKey!.environmentId, 'windows');
    expect(host.privateKey!.path, keyOf('m1').path);
    expect(keyOf('m1').readAsStringSync(), contains('OPENSSH PRIVATE KEY'));
    expect(ssh.ssh.hostOf('m1'), isNotNull);
    expect(connected, ['m1']);
    expect(detected, ['ssh:m1']);
    expect(progress.map((p) => p.step).toSet(), {
      ContainerStep.checking,
      ContainerStep.pulling,
      ContainerStep.starting,
      ContainerStep.settingUp,
      ContainerStep.connecting,
      ContainerStep.detecting,
      ContainerStep.done,
    });
    expect(progress.last.step, ContainerStep.done);
    expect(progress.map((p) => p.line), contains('karmashala: installing ssh'));
    // The key went into the container as its public half only.
    final run = docker.scripts.firstWhere((s) => s.contains('docker run -d'));
    expect(run, contains("KS_PUBKEY='ssh-ed25519 "));
    expect(run, isNot(contains('PRIVATE KEY')));
    for (final line in progress) {
      expect(line.line ?? '', isNot(contains('PRIVATE KEY')));
    }
  });

  test('a container on an SSH host jumps through it, on a port no saved '
      'host uses', () async {
    await containers.create(
      environmentId: 'wsl:probe',
      machineId: 'm1',
      spec: spec,
    );
    final host = await containers.create(
      environmentId: 'ssh:box',
      machineId: 'm2',
      spec: const ContainerSpec(
        name: 'other',
        distro: ContainerDistro.debian13,
        cpus: 1,
        memoryMb: 1024,
      ),
    );
    expect(host.host, '127.0.0.1');
    expect(host.viaHostId, 'box');
    expect(host.port, 41002, reason: '41000 listens, m1 holds 41001');
    expect(host.hostKeyName, 'container:m2');
  });

  test('a host that cannot run Docker is refused before anything '
      'runs', () async {
    docker.check =
        'user=karma\narch=x86_64\ndocker_rc=1\n'
        'docker_out=permission denied while trying to connect\n';
    await expectLater(
      containers.create(environmentId: 'ssh:box', machineId: 'm1', spec: spec),
      throwsA(
        isA<DataRefused>().having(
          (r) => r.message,
          'message',
          "karma can't use Docker on build-box: not in the docker group.",
        ),
      ),
    );
    expect(docker.scripts.where((s) => s.contains('docker run')), isEmpty);
    expect(progress.last.step, ContainerStep.failed);
  });

  test('a failed setup removes the container, its new volume and the '
      'key', () async {
    docker.setup = (lines: ['KARMASHALA-FAILED'], code: 3);
    await expectLater(
      containers.create(
        environmentId: 'wsl:probe',
        machineId: 'm1',
        spec: spec,
      ),
      throwsA(isA<DataRefused>()),
    );
    final delete = docker.scripts.lastWhere((s) => s.contains('rm -f -v'));
    expect(delete, contains("WITH_HOME='1'"));
    expect(keyOf('m1').existsSync(), isFalse);
    expect(ssh.ssh.hostOf('m1'), isNull);
    expect(progress.last.step, ContainerStep.failed);
  });

  test('a failed recreate keeps the home volume it found', () async {
    docker
      ..volumeExists = 'yes'
      ..setup = (lines: const [], code: 4);
    await expectLater(
      containers.create(
        environmentId: 'wsl:probe',
        machineId: 'm1',
        spec: spec,
      ),
      throwsA(isA<DataRefused>()),
    );
    final delete = docker.scripts.lastWhere((s) => s.contains('rm -f -v'));
    expect(delete, contains("WITH_HOME='0'"));
  });

  test('delete forgets the host, its pinned key and its key file', () async {
    final host = await containers.create(
      environmentId: 'ssh:box',
      machineId: 'm1',
      spec: spec,
    );
    data.applyAsServer(
      KnownHostTrust(
        KnownHostKey(
          host: host.hostKeyName,
          port: host.port,
          keyType: 'ssh-ed25519',
          fingerprint: 'SHA256:abc',
          trustedAt: now,
        ),
      ),
    );
    await containers.delete('m1', withHome: true);
    expect(ssh.ssh.hostOf('m1'), isNull);
    expect(keyOf('m1').existsSync(), isFalse);
    expect(KnownHostDao(db).find('container:m1', host.port), isNull);
    final delete = docker.scripts.lastWhere((s) => s.contains('rm -f -v'));
    expect(delete, contains("C='ks-sandbox'"));
    expect(delete, contains("WITH_HOME='1'"));
  });

  test('a delete Docker refuses puts the machine back', () async {
    await containers.create(
      environmentId: 'wsl:probe',
      machineId: 'm1',
      spec: spec,
    );
    docker.deleteResult = const CommandResult(
      exitCode: 9,
      stdout: '',
      stderr: 'karmashala: ks-sandbox was not made by Karmashala; left alone',
    );
    await expectLater(
      containers.delete('m1', withHome: false),
      throwsA(
        isA<DataRefused>().having(
          (r) => r.message,
          'message',
          contains('not made by Karmashala'),
        ),
      ),
    );
    expect(ssh.ssh.hostOf('m1'), isNotNull);
    expect(keyOf('m1').existsSync(), isTrue);
  });

  test('only an SSH host or WSL may run containers, and not a '
      'container', () async {
    await containers.create(
      environmentId: 'ssh:box',
      machineId: 'm1',
      spec: spec,
    );
    expect((await containers.check('windows')).canHost, isFalse);
    expect(
      (await containers.check('ssh:m1')).problem,
      contains('is a container'),
    );
    expect((await containers.check('wsl:nowhere')).canHost, isFalse);
  });

  test('a phone may start and stop a container, not create or delete '
      'one', () {
    expect(
      phoneRefusal(
        const ContainerCreate(
          environmentId: 'ssh:box',
          machineId: 'm1',
          spec: spec,
        ),
      ),
      isNotNull,
    );
    expect(phoneRefusal(const ContainerDelete('m1')), isNotNull);
    expect(
      phoneRefusal(const ContainerPower('m1', ContainerPowerAction.start)),
      isNull,
    );
  });

  test('status, start and stop speak Docker through the prefix', () async {
    await containers.create(
      environmentId: 'wsl:probe',
      machineId: 'm1',
      spec: spec,
    );
    expect(await containers.status('m1'), ContainerState.running);
    await containers.power('m1', ContainerPowerAction.stop);
    expect(
      docker.scripts.last,
      contains('.State.Status'),
      reason: 'the state is read again after the stop',
    );
    expect(docker.scripts.any((s) => s.contains(r'docker stop "$C"')), isTrue);
    await expectLater(
      containers.status('box'),
      throwsA(isA<DataRefused>()),
      reason: 'build-box is not a container',
    );
  });
}

class _Fixed implements Clock {
  _Fixed(this.now);

  final DateTime now;

  @override
  DateTime nowUtc() => now;
}
