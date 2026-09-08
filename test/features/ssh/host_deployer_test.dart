import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/ssh/data/host_binaries.dart';
import 'package:karmashala/src/features/ssh/data/host_deploy_target.dart';
import 'package:karmashala/src/features/ssh/data/host_deployer.dart';
import 'package:karmashala/src/features/ssh/domain/host_deployment.dart';
import 'package:karmashala_host/protocol.dart';

/// A machine that answers scripted commands and speaks the protocol back over
/// a fake exec channel. The real SSH path (SshHostDeployTarget) is *not*
/// covered by anything: it needs an sshd, and the stand-in WSL distribution
/// does not run one.
class FakeTarget implements HostDeployTarget {
  FakeTarget({this.uname = 'Linux\nx86_64\nldd (GNU libc) 2.43\n'});

  @override
  String get address => 'fake.example';

  String uname;
  final commands = <String>[];
  final uploads = <(String, int)>[];
  final Map<String, RemoteRun> scripted = {};

  /// What the host does when `attach` runs: null means nothing answers.
  HostMessage? Function(HelloMessage hello)? greet = (_) => WelcomeMessage(
    requestId: 1,
    protocolVersion: kProtocolVersion,
    hostVersion: '0.1.0',
    operatingSystem: 'linux',
    architecture: 'x64',
    ptyLibrary: 'libc.so.6',
    pid: 99,
    startedAt: DateTime.utc(2026),
    observedAt: DateTime.utc(2026),
  );

  Object? uploadError;
  int existingSize = -1;
  var execCount = 0;

  @override
  Future<RemoteRun> run(String command) async {
    commands.add(command);
    for (final entry in scripted.entries) {
      if (command.contains(entry.key)) return entry.value;
    }
    if (command.startsWith('uname')) return RemoteRun(0, uname, '');
    if (command.contains('wc -c <')) {
      return RemoteRun(0, existingSize < 0 ? 'missing\n' : '$existingSize\n', '');
    }
    return const RemoteRun(0, '', '');
  }

  @override
  Future<void> upload(String remotePath, Uint8List bytes) async {
    final failure = uploadError;
    if (failure != null) throw failure;
    uploads.add((remotePath, bytes.length));
    existingSize = bytes.length;
  }

  @override
  Future<RemoteChannel> exec(String command) async {
    execCount++;
    commands.add(command);
    return FakeChannel(this);
  }
}

class FakeChannel implements RemoteChannel {
  FakeChannel(this._target);

  final FakeTarget _target;
  final _out = StreamController<Uint8List>();
  final _parser = FrameParser();
  var closed = false;

  @override
  Stream<Uint8List> get stdout => _out.stream;

  @override
  Stream<Uint8List> get stderr => const Stream.empty();

  @override
  void add(Uint8List bytes) {
    for (final frame in _parser.add(bytes)) {
      final message = decodeMessage(frame);
      if (message is! HelloMessage) continue;
      final reply = _target.greet?.call(message);
      if (reply != null) _out.add(reply.toFrame().encode());
    }
  }

  @override
  Future<int> get exitCode async => 0;

  @override
  Future<void> close() async {
    closed = true;
    if (!_out.isClosed) await _out.close();
  }
}

class FakeBinaries implements HostBinarySource {
  FakeBinaries({this.targets = const {'linux-x64': 1024}});

  final Map<String, int> targets;

  @override
  Future<HostBinary?> binaryFor(HostPlatform platform) async {
    final size = targets[platform.targetKey];
    if (size == null) return null;
    return HostBinary(
      bytes: Uint8List(size),
      version: '0.1.0',
      source: 'fake/karmashala_host-0.1.0-${platform.targetKey}',
    );
  }

  @override
  Future<List<String>> availableTargets() async => targets.keys.toList()..sort();
}

HostDeployer deployerFor(FakeTarget target, {HostBinarySource? binaries}) => HostDeployer(
  target: target,
  binaries: binaries ?? FakeBinaries(),
  clock: () => DateTime.utc(2026, 9, 8, 14, 0),
  // Production waits 15 s for an answer across a network. Paying that three
  // times in the gate for hosts that are *meant* to stay silent is a minute of
  // nothing; the bound under test is that it gives up, not how long it waits.
  helloTimeout: const Duration(milliseconds: 50),
);

void main() {
  group('measuring the machine', () {
    test('reads uname and the libc, and normalises the architecture', () async {
      final target = FakeTarget(uname: 'Linux\naarch64\nldd (GNU libc) 2.36\n');
      final platform = await deployerFor(target).measurePlatform();

      expect(platform!.operatingSystem, 'linux');
      expect(platform.architecture, 'arm64');
      expect(platform.libc, HostLibc.glibc);
      expect(platform.targetKey, 'linux-arm64');
      expect(platform.observedAt, DateTime.utc(2026, 9, 8, 14, 0));
    });

    test('a machine that says nothing is unknown, not assumed', () async {
      final target = FakeTarget(uname: '');
      expect(await deployerFor(target).measurePlatform(), isNull);

      final deployment = await deployerFor(target).deploy();
      expect(deployment.status, HostDeploymentStatus.unknown);
      expect(deployment.reason, contains('did not answer'));
    });

    test('a libc it could not read is unknown rather than assumed glibc', () async {
      final platform = await deployerFor(
        FakeTarget(uname: 'Linux\nx86_64\n'),
      ).measurePlatform();
      expect(platform!.libc, HostLibc.unknown);
    });
  });

  group('platforms with nothing to send', () {
    test('musl is refused with the reason, and nothing is uploaded', () async {
      final target = FakeTarget(uname: 'Linux\nx86_64\nmusl libc (x86_64)\n');
      final deployment = await deployerFor(target).deploy();

      expect(deployment.status, HostDeploymentStatus.unsupportedPlatform);
      expect(deployment.reason, contains('musl'));
      expect(deployment.reason, contains('glibc-linked ELF'));
      expect(deployment.fallsBackToTmux, isTrue);
      expect(target.uploads, isEmpty);
    });

    test('macOS is refused, and the message says the SDK cannot build for it', () async {
      final target = FakeTarget(uname: 'Darwin\narm64\n');
      final deployment = await deployerFor(target).deploy();

      expect(deployment.status, HostDeploymentStatus.unsupportedPlatform);
      expect(deployment.reason, contains('macOS'));
      expect(deployment.platform!.operatingSystem, 'darwin');
      expect(target.uploads, isEmpty);
    });

    test('a Linux arch this build has no binary for names what it does have', () async {
      final target = FakeTarget(uname: 'Linux\nriscv64\nldd (GNU libc) 2.40\n');
      final deployment = await deployerFor(target).deploy();

      expect(deployment.status, HostDeploymentStatus.noBinary);
      expect(deployment.reason, contains('linux-riscv64'));
      expect(deployment.reason, contains('linux-x64'));
    });
  });

  group('installing', () {
    test('uploads, chmods, and reports the version it put there', () async {
      final target = FakeTarget();
      final deployment = await deployerFor(target).deploy();

      expect(deployment.status, HostDeploymentStatus.ready);
      expect(target.uploads.single.$1, contains('karmashala_host-0.1.0-linux-x64'));
      expect(target.uploads.single.$2, 1024);
      expect(deployment.remotePath, r'$HOME/.karmashala/bin/karmashala_host-0.1.0-linux-x64');
      expect(deployment.hostVersion, '0.1.0');
      expect(deployment.protocolVersion, kProtocolVersion);
      expect(deployment.observedAt, DateTime.utc(2026, 9, 8, 14, 0));
      expect(target.commands.any((c) => c.contains('chmod +x')), isTrue);
    });

    test('skips the upload when the remote file is already this build', () async {
      final target = FakeTarget()..existingSize = 1024;
      final deployment = await deployerFor(target).deploy();

      expect(deployment.status, HostDeploymentStatus.ready);
      expect(target.uploads, isEmpty, reason: 'same name, same size, same build');
      expect(
        target.commands.any((c) => c.contains('chmod +x')),
        isTrue,
        reason: 'a restored file can be the right size and not executable',
      );
    });

    test('a different size means a different build and is re-uploaded', () async {
      final target = FakeTarget()..existingSize = 999;
      await deployerFor(target).deploy();
      expect(target.uploads, hasLength(1));
    });

    test('a read-only home is reported as cannot-install, in those words', () async {
      final target = FakeTarget()..uploadError = StateError('permission denied');
      final deployment = await deployerFor(target).deploy();

      expect(deployment.status, HostDeploymentStatus.cannotInstall);
      expect(deployment.reason, contains('read-only home'));
      expect(deployment.fallsBackToTmux, isTrue);
    });

    test('a noexec home is caught by the chmod check, not discovered later', () async {
      final target = FakeTarget()
        ..scripted['chmod +x'] = const RemoteRun(1, '', 'Operation not permitted');
      final deployment = await deployerFor(target).deploy();

      expect(deployment.status, HostDeploymentStatus.cannotInstall);
      expect(deployment.reason, contains('noexec'));
    });
  });

  group('starting and greeting', () {
    test('a host that answers first time is never started twice', () async {
      final target = FakeTarget();
      final deployment = await deployerFor(target).deploy();

      expect(deployment.isReady, isTrue);
      expect(target.execCount, 1, reason: 'one hello, no restart');
      expect(target.commands.any((c) => c.contains('setsid nohup')), isFalse);
    });

    test('a silent host is started with setsid nohup and then asked again', () async {
      final target = FakeTarget();
      var asked = 0;
      target.greet = (hello) {
        asked++;
        return asked == 1
            ? null
            : WelcomeMessage(
                requestId: 1,
                protocolVersion: kProtocolVersion,
                hostVersion: '0.1.0',
                operatingSystem: 'linux',
                architecture: 'x64',
                ptyLibrary: 'libc.so.6',
                pid: 5,
                startedAt: DateTime.utc(2026),
                observedAt: DateTime.utc(2026),
              );
      };

      final deployment = await deployerFor(target).deploy();

      expect(deployment.isReady, isTrue);
      expect(asked, 2);
      final start = target.commands.firstWhere((c) => c.contains('setsid nohup'));
      expect(start, contains('serve'));
      expect(start, contains('< /dev/null'), reason: 'the channel must not stay open');
      expect(start, contains('host.log'));
    }, timeout: const Timeout(Duration(seconds: 40)));

    test('a host that was already running is not reported as restarted', () async {
      final deployment = await deployerFor(FakeTarget()).deploy();
      expect(deployment.isReady, isTrue);
      expect(deployment.restartedByUs, isFalse);
      expect(deployment.reason, isNot(contains('restarted')));
    });

    test('a host that had to be started reports that its sessions are gone', () async {
      final target = FakeTarget();
      var asked = 0;
      target.greet = (hello) {
        asked++;
        // Exactly the shape of a reboot: nothing is listening until we start it.
        return asked == 1
            ? null
            : WelcomeMessage(
                requestId: 1,
                protocolVersion: kProtocolVersion,
                hostVersion: '0.1.0',
                operatingSystem: 'linux',
                architecture: 'x64',
                ptyLibrary: 'libc.so.6',
                pid: 5,
                startedAt: DateTime.utc(2026),
                observedAt: DateTime.utc(2026),
              );
      };

      final deployment = await deployerFor(target).deploy();

      expect(deployment.isReady, isTrue);
      expect(deployment.restartedByUs, isTrue);
      expect(deployment.reason, contains('was not running and has been restarted'));
      expect(deployment.reason, contains('sessions it held before are gone'));
      expect(target.commands.any((c) => c.contains('setsid nohup')), isTrue);
    });

    test('a host that would not start is still reported as one we tried to start', () async {
      final target = FakeTarget()
        ..greet = ((_) => null)
        ..scripted['setsid nohup'] = const RemoteRun(127, '', 'sh: setsid: not found');
      final deployment = await deployerFor(target).deploy();
      expect(deployment.restartedByUs, isTrue);
    });

    test('a host that never answers is cannot-start, and falls back', () async {
      final target = FakeTarget()..greet = (_) => null;
      final deployment = await deployerFor(target).deploy();

      expect(deployment.status, HostDeploymentStatus.cannotStart);
      expect(deployment.reason, contains('never answered `hello`'));
      expect(deployment.fallsBackToTmux, isTrue);
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('a serve that will not start quotes what the machine said', () async {
      // The closure is parenthesised because a cascade after `=> null` binds
      // to the null, not to the target.
      final target = FakeTarget()
        ..greet = ((_) => null)
        ..scripted['setsid nohup'] = const RemoteRun(127, '', 'sh: setsid: not found');
      final deployment = await deployerFor(target).deploy();

      expect(deployment.status, HostDeploymentStatus.cannotStart);
      expect(deployment.reason, contains('setsid: not found'));
    }, timeout: const Timeout(Duration(seconds: 40)));

    test('an older host still running is reported as a protocol mismatch', () async {
      final target = FakeTarget()
        ..greet = ((_) => const ErrorMessage(
          1,
          ProtocolErrorCode.protocolMismatch,
          'host speaks protocol 7, client speaks 1',
        ));
      final deployment = await deployerFor(target).deploy();

      expect(deployment.status, HostDeploymentStatus.protocolMismatch);
      expect(deployment.protocolVersion, 7);
      expect(deployment.reason, contains('speaks protocol 7'));
      expect(deployment.reason, contains('stale `serve`'));
      expect(deployment.fallsBackToTmux, isTrue);
    });

    test('a refusal that is not a version mismatch is not read as one', () async {
      final target = FakeTarget()
        ..greet = ((_) =>
            const ErrorMessage(1, ProtocolErrorCode.internal, 'something else entirely'));
      final deployment = await deployerFor(target).deploy();

      expect(deployment.status, HostDeploymentStatus.cannotStart);
    }, timeout: const Timeout(Duration(seconds: 60)));
  });

  group('HostPlatform', () {
    test('normalises the architectures that matter and leaves the rest alone', () {
      expect(HostPlatform.normaliseArchitecture('x86_64'), 'x64');
      expect(HostPlatform.normaliseArchitecture('amd64'), 'x64');
      expect(HostPlatform.normaliseArchitecture('aarch64'), 'arm64');
      expect(HostPlatform.normaliseArchitecture('armv7l'), 'armv7l');
    });
  });
}
