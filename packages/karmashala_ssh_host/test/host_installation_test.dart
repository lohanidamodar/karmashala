import 'dart:typed_data';

import 'package:karmashala_ssh/connection.dart';
import 'package:karmashala_host_protocol/protocol.dart' show kHostVersion;
import 'package:karmashala_ssh_host/host.dart';
import 'package:test/test.dart';

import 'host_deployer_test.dart' show FakeBinaries, FakeTarget;

const _bin = '/home/fake/.karmashala/bin';
const _this = 'karmashala_host-$kHostVersion-linux-x64.d';
const _older = 'karmashala_host-0.0.9-linux-x64.d';
const _token = '0123456789abcdef0123456789abcdef';

String _exe(String entry) => '$_bin/$entry/bin/karmashala_host';

/// [FakeTarget] with a `bin/` that can be listed and emptied, a `serve` that
/// stops and starts, and a relay's three files.
class _Box extends FakeTarget {
  _Box() {
    runningServe = null;
    // A `hello` is answered by a running `serve`, and by nothing else.
    final answer = greet!;
    greet = (hello) => runningServe == null ? null : answer(hello);
  }

  final installed = <String>[];
  var relayFiles = false;
  var removes = 0;

  @override
  Future<RemoteRun> run(String command) async {
    if (command.contains('karmashala-listed')) {
      commands.add(command);
      return RemoteRun(
        0,
        '${installed.map((n) => 'installed=$n\n').join()}karmashala-listed\n',
        '',
      );
    }
    if (command.contains('karmashala-removed')) {
      commands.add(command);
      removes++;
      installed.clear();
      return const RemoteRun(0, 'karmashala-removed\n', '');
    }
    // The relay's own inspect and delete, which also mention `ps -o args=`.
    if (command.contains('relay.pid') || command.contains('relay.token')) {
      commands.add(command);
      if (command.startsWith('rm -f ')) relayFiles = false;
      return RemoteRun(
        0,
        'args=\ntoken=${relayFiles ? _token : ''}\nlog=\n',
        '',
      );
    }
    if (command.contains('setsid nohup')) {
      commands.add(command);
      runningServe = RegExp(
        r"setsid nohup '([^']+)' serve",
      ).firstMatch(command)!.group(1);
      return const RemoteRun(0, 'started\n', '');
    }
    if (command.contains('host.lock') && command.contains('kill "\$p"')) {
      commands.add(command);
      if (stopOutput.contains('karmashala-stopped')) runningServe = null;
      return RemoteRun(0, stopOutput, '');
    }
    return super.run(command);
  }

  @override
  Future<void> upload(String remotePath, Uint8List bytes) async {
    await super.upload(remotePath, bytes);
    final name = remotePath.split('/').last;
    final entry = name.endsWith('.tar.gz')
        ? '${name.substring(0, name.length - 7)}.d'
        : name;
    if (!installed.contains(entry)) installed.add(entry);
  }
}

void main() {
  final host = SshHost(
    id: 'h1',
    name: 'do-box',
    host: '203.0.113.9',
    port: 22,
    username: 'dlohani',
    authMethod: SshAuthMethod.privateKey,
    createdAt: DateTime.utc(2026, 9, 17),
  );

  late _Box box;

  setUp(() => box = _Box());

  HostInstaller installer({FakeBinaries? binaries}) => HostInstaller(
    host: host,
    deployer: HostDeployer(
      target: box,
      binaries: binaries ?? FakeBinaries(isBundleArchive: true),
      clock: () => DateTime.utc(2026, 9, 17, 12),
      helloTimeout: const Duration(milliseconds: 50),
    ),
  );

  group('the state line', () {
    test('a machine with nothing on it reads "not installed"', () async {
      final reading = await installer().check();

      expect(reading.state, HostInstallState.notInstalled);
      expect(reading.label, 'not installed');
      expect(reading.offeredVersion, kHostVersion);
      // Where it would go, and that it needs no root.
      expect(reading.reason, contains('/home/fake/.karmashala'));
      expect(reading.reason, contains('no root'));
      expect(box.uploads, isEmpty, reason: 'looking uploads nothing');
      expect(box.commands.where((c) => c.contains('setsid')), isEmpty);
    });

    test('this build, running, with what it holds', () async {
      box
        ..installed.add(_this)
        ..runningServe = _exe(_this)
        ..heldSessions = 2;

      final reading = await installer().check();

      expect(reading.state, HostInstallState.installed);
      expect(reading.label, 'installed $kHostVersion (running)');
      expect(reading.sessionsHeld, 2);
      expect(reading.reason, contains('holding 2 session'));
      expect(reading.remotePath, _exe(_this));
    });

    test('this build, installed and not running, reads "stopped"', () async {
      box.installed.add(_this);

      final reading = await installer().check();

      expect(reading.label, 'installed $kHostVersion (stopped)');
      expect(reading.sessionsHeld, isNull);
    });

    test('another version is "older than this app", from → to', () async {
      box
        ..installed.add(_older)
        ..runningServe = _exe(_older);

      final reading = await installer().check();

      expect(reading.state, HostInstallState.outdated);
      expect(
        reading.label,
        'older than the server\'s (0.0.9 → $kHostVersion), running',
      );
      expect(reading.reason, contains('Update'));
    });

    test('a host newer than this app is not called older, nor "updated" '
        'downwards by that name', () async {
      // An app that was downgraded, or a second desktop on a newer build.
      const newer = 'karmashala_host-99.0.0-linux-x64.d';
      box
        ..installed.add(newer)
        ..runningServe = _exe(newer);

      final reading = await installer().check();

      expect(reading.state, HostInstallState.outdated);
      expect(reading.hostIsNewer, isTrue);
      expect(
        reading.label,
        'newer than the server\'s (99.0.0; the server carries $kHostVersion), running',
      );
      expect(reading.reason, isNot(contains('Update')));
      expect(reading.reason, contains(kHostVersion));
    });

    test(
      'this build installed beside a running older one is still older',
      () async {
        box
          ..installed.addAll([_older, _this])
          ..runningServe = _exe(_older);

        final reading = await installer().check();

        expect(reading.state, HostInstallState.outdated);
        expect(reading.installedVersion, '0.0.9');
      },
    );

    test(
      'no bundle for the machine is "can\'t install", with the reason',
      () async {
        box.uname = 'Linux\naarch64\nldd (GNU libc) 2.36\n';

        final reading = await installer().check();

        expect(reading.state, HostInstallState.cannotInstall);
        expect(reading.label, startsWith('can\'t install: '));
        expect(reading.deployment?.status, HostDeploymentStatus.noBinary);
        expect(reading.deployment?.availableTargets, ['linux-x64']);
        expect(reading.platform?.targetKey, 'linux-arm64');
        expect(reading.canInstall, isFalse);
      },
    );

    test('a musl machine is "can\'t install", and says musl', () async {
      box.uname = 'Linux\nx86_64\nmusl libc (x86_64)\n';

      final reading = await installer().check();

      expect(reading.state, HostInstallState.cannotInstall);
      expect(reading.label, contains('musl'));
    });

    test(
      'a machine that does not answer is unknown, never "not installed"',
      () async {
        box.uname = '';

        final reading = await installer().check();

        expect(reading.state, HostInstallState.unknown);
        expect(reading.label, startsWith('unknown: '));
      },
    );

    test('a host this build cannot replace still says what is there', () async {
      box
        ..uname = 'Linux\naarch64\nldd (GNU libc) 2.36\n'
        ..installed.add('karmashala_host-0.0.9-linux-arm64.d');

      final reading = await installer().check();

      expect(reading.state, HostInstallState.installed);
      // Older than this app, and nothing newer carried to put there.
      expect(reading.label, 'installed 0.0.9 (stopped; older than this app)');
      expect(reading.noNewerHost, isTrue);
      expect(
        reading.reason,
        contains('carries no host bundle for linux-arm64'),
      );
      expect(reading.canInstall, isFalse);
    });
  });

  group('install, update, reinstall', () {
    test(
      'Install is the one deploy: upload under the home, unpack, start',
      () async {
        final reading = await installer().install();

        expect(reading.state, HostInstallState.installed);
        expect(reading.label, 'installed $kHostVersion (running)');
        expect(
          reading.deployment,
          isNull,
          reason: 'a ready deploy is not a failure',
        );
        expect(
          box.uploads.single.$1,
          '$_bin/karmashala_host-$kHostVersion-linux-x64.tar.gz',
        );
        final argv = box.commands;
        expect(argv.any((c) => c.contains('tar -xzf')), isTrue);
        expect(
          argv.any((c) => c.contains("setsid nohup '${_exe(_this)}' serve")),
          isTrue,
        );
        // Home only: nothing here ever asks for root.
        expect(argv.any((c) => c.contains('sudo')), isFalse);
      },
    );

    test(
      'Update installs beside a running older host and moves over',
      () async {
        box
          ..installed.add(_older)
          ..runningServe = _exe(_older)
          ..heldSessions = 0;

        final reading = await installer().install();

        expect(reading.label, 'installed $kHostVersion (running)');
        expect(box.runningServe, _exe(_this));
      },
    );

    test('Update leaves an older host that holds work, and says so', () async {
      box
        ..installed.add(_older)
        ..runningServe = _exe(_older)
        ..heldSessions = 3;

      final reading = await installer().install();

      expect(reading.state, HostInstallState.outdated);
      expect(reading.reason, contains('3 session'));
      expect(box.runningServe, _exe(_older));
    });

    test('Reinstall uploads again over a bundle of the right size', () async {
      box
        ..installed.add(_this)
        ..existingSize = 1024
        ..runningServe = _exe(_this);

      await installer().install();
      expect(box.uploads, isEmpty, reason: 'the steady state uploads nothing');

      final reading = await installer().install(reinstall: true);

      expect(box.uploads, hasLength(1));
      expect(reading.label, 'installed $kHostVersion (running)');
      // Holding nothing, so it was restarted onto the fresh files.
      expect(
        box.commands.where((c) => c.contains('setsid nohup')),
        hasLength(1),
      );
    });

    test('Reinstall under a host that holds work leaves it running', () async {
      box
        ..installed.add(_this)
        ..existingSize = 1024
        ..runningServe = _exe(_this)
        ..heldSessions = 1;

      final reading = await installer().install(reinstall: true);

      expect(box.uploads, hasLength(1));
      expect(box.commands.where((c) => c.contains('setsid nohup')), isEmpty);
      expect(reading.reason, contains('1 session'));
    });

    test(
      'an install that cannot happen carries the deployment to explain',
      () async {
        box.uploadError = StateError('disk full');

        final reading = await installer().install();

        expect(reading.deployment?.status, HostDeploymentStatus.cannotInstall);
        expect(reading.state, HostInstallState.notInstalled);
      },
    );
  });

  group('start and stop', () {
    test(
      'Start runs the installed executable and proves it with a hello',
      () async {
        box.installed.add(_this);

        final reading = await installer().start();

        expect(reading.label, 'installed $kHostVersion (running)');
        expect(reading.reason, contains('does not come back by itself'));
        expect(
          box.commands.singleWhere((c) => c.contains('setsid nohup')),
          contains("'${_exe(_this)}' serve"),
        );
      },
    );

    test('Start on a running host changes nothing', () async {
      box
        ..installed.add(_this)
        ..runningServe = _exe(_this);

      final reading = await installer().start();

      expect(reading.reason, contains('already running'));
      expect(box.commands.where((c) => c.contains('setsid nohup')), isEmpty);
    });

    test('Stop says what ended with it', () async {
      box
        ..installed.add(_this)
        ..runningServe = _exe(_this)
        ..heldSessions = 2;

      final reading = await installer().stop();

      expect(reading.label, 'installed $kHostVersion (stopped)');
      expect(reading.reason, contains('2 session(s) it held have ended'));
    });

    test('a host that will not stop is reported as still running', () async {
      box
        ..installed.add(_this)
        ..runningServe = _exe(_this)
        ..stopOutput = 'karmashala-still-running\n';

      final reading = await installer().stop();

      expect(reading.running, isTrue);
      expect(reading.reason, contains('would not stop'));
    });
  });

  group('remove', () {
    test('stops the relay and the host, deletes what they wrote, and says '
        'what it leaves', () async {
      box
        ..installed.addAll([_older, _this])
        ..runningServe = _exe(_this)
        ..relayFiles = true;

      final reading = await installer().remove();

      expect(reading.state, HostInstallState.notInstalled);
      expect(box.relayFiles, isFalse);
      expect(box.runningServe, isNull);
      final rm = box.commands.singleWhere(
        (c) => c.contains('karmashala-removed'),
      );
      // Every bundle, by the fixed prefix under the home — never the directory.
      expect(rm, contains("rm -rf '$_bin'/karmashala_host-*"));
      expect(rm, contains('host.log'));
      expect(rm, contains('host.lock'));
      expect(rm, isNot(contains('sessions')));
      expect(rm, isNot(contains('sudo')));
      expect(
        box.commands.any(
          (c) => c.startsWith('rm -f ') && c.contains('relay.token'),
        ),
        isTrue,
      );
      expect(reading.reason, contains('Left in place'));
      expect(reading.reason, contains('/home/fake/.karmashala/sessions'));
      expect(reading.reason, contains('paired'));
      expect(reading.reason, isNot(contains(_token)));
    });

    test('a host that will not stop keeps its files', () async {
      box
        ..installed.add(_this)
        ..runningServe = _exe(_this)
        ..stopOutput = 'karmashala-still-running\n';

      final reading = await installer().remove();

      expect(box.removes, 0);
      expect(reading.reason, contains('would not stop'));
      expect(reading.state, HostInstallState.installed);
    });

    test('a machine that cannot be asked is not told it was removed', () async {
      box.home = null;

      final reading = await installer().remove();

      expect(reading.state, HostInstallState.unknown);
      expect(box.removes, 0);
    });
  });
}
