import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:test/test.dart';
import 'package:karmashala_ssh_host/host.dart';
import 'package:karmashala_host_protocol/protocol.dart';

/// A machine that answers scripted commands and speaks the protocol back over
/// a fake exec channel. The real SSH path (SshHostDeployTarget) is *not*
/// covered by anything: it needs an sshd, and the stand-in WSL distribution
/// does not run one.
///
/// **It is a shell on [run] and an SFTP server on [upload]**, which is the one
/// asymmetry that matters here. Until 2026-09-10 this fake expanded `$HOME` for
/// both, so a deploy that wrote every byte to a literal `$HOME/...` — which
/// `sftp.open` reads as a directory that does not exist — passed the whole
/// suite while never once installing the host on a real machine.
class FakeTarget implements HostDeployTarget {
  FakeTarget({this.uname = 'Linux\nx86_64\nldd (GNU libc) 2.43\n'});

  @override
  String get address => 'fake.example';

  String uname;

  /// What this machine's shell expands `$HOME` to, and the only place a path
  /// under it can legitimately come from. Null is a machine that will not say.
  String? home = '/home/fake';
  final commands = <String>[];
  final uploads = <(String, int)>[];
  final Map<String, RemoteRun> scripted = {};

  /// What the host does when `attach` runs: null means nothing answers.
  HostMessage? Function(HelloMessage hello)? greet = (_) => WelcomeMessage(
    requestId: 1,
    protocolVersion: kProtocolVersion,
    hostVersion: kHostVersion,
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

  /// Whether an already-present bundle was ever unpacked. False is the state a
  /// size check alone reads as installed: the archive arrived, nothing extracted.
  var executableInstalled = true;

  /// How many sessions the running host reports when asked. Null refuses to
  /// say, which is a third answer and not zero.
  int? heldSessions = 0;

  /// What the stop command prints. The default is a machine whose `serve`
  /// took the signal and went.
  String stopOutput = 'karmashala-stopped\n';

  /// The executable the running `serve` was started from. Null is a machine
  /// that would not say; the default is the build this deploy installs.
  String? runningServe =
      '/home/fake/.karmashala/bin/karmashala_host-$kHostVersion-linux-x64';

  @override
  Future<RemoteRun> run(String command) async {
    commands.add(command);
    for (final entry in scripted.entries) {
      if (command.contains(entry.key)) return entry.value;
    }
    if (command.contains('ps -o args=')) {
      final running = runningServe;
      return RemoteRun(0, running == null ? '' : '$running serve\n', '');
    }
    if (command.contains('host.lock')) return RemoteRun(0, stopOutput, '');
    if (command.startsWith('uname')) return RemoteRun(0, uname, '');
    if (command.contains(r'echo "$HOME"')) {
      return RemoteRun(0, '${home ?? ''}\n', '');
    }
    if (command.contains('wc -c <')) {
      return RemoteRun(
        0,
        existingSize < 0 ? 'missing\n' : '$existingSize\n',
        '',
      );
    }
    // Only the "is what is already here runnable" question — `chmod …; test -x`
    // — never the `chmod … && test -x` that verifies a fresh install. The two
    // are told apart by the separator, which is the whole difference between
    // asking and asserting.
    if (command.contains('2>/dev/null; test -x')) {
      return RemoteRun(executableInstalled ? 0 : 1, '', '');
    }
    return const RemoteRun(0, '', '');
  }

  @override
  Future<void> upload(String remotePath, Uint8List bytes) async {
    // SFTP has no shell behind it. `sftp.open` takes the path byte for byte,
    // so a `$HOME` or a `~` in it names a directory nobody ever created and
    // the server answers SSH_FX_NO_SUCH_FILE — the failure the owner's droplet
    // took silently for a day.
    if (remotePath.contains(r'$') || remotePath.contains('~')) {
      throw SftpStatusError(
        SftpStatusCode.noSuchFile,
        'No such file: $remotePath',
      );
    }
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
      if (message is HelloMessage) {
        final reply = _target.greet?.call(message);
        if (reply != null) _out.add(reply.toFrame().encode());
        continue;
      }
      if (message is! ListMessage) continue;
      final held = _target.heldSessions;
      if (held == null) {
        _out.add(
          ErrorMessage(
            message.requestId,
            ProtocolErrorCode.internal,
            'not saying',
          ).toFrame().encode(),
        );
        continue;
      }
      _out.add(
        SessionsMessage(message.requestId, [
          for (var i = 0; i < held; i++) _summary('s$i'),
        ]).toFrame().encode(),
      );
    }
  }

  static SessionSummary _summary(String id) => SessionSummary(
    id: id,
    argv: const ['/bin/sh'],
    workingDirectory: null,
    pid: 7,
    columns: 80,
    rows: 24,
    startedAt: DateTime.utc(2026),
    observedAt: DateTime.utc(2026),
    totalBytes: 0,
    firstAvailableOffset: 0,
    lifecycle: const SessionRunning(),
    writeHolder: null,
  );

  @override
  Future<int> get exitCode async => 0;

  @override
  Future<void> close() async {
    closed = true;
    if (!_out.isClosed) await _out.close();
  }
}

class FakeBinaries implements HostBinarySource {
  @override
  String describeSearch() => 'the fake bundle folder';

  @override
  String? get dropFolder => null;

  FakeBinaries({
    this.targets = const {'linux-x64': 1024},
    this.isBundleArchive = false,
  });

  final Map<String, int> targets;

  /// What every current build ships; false is a host from before the store.
  final bool isBundleArchive;

  /// How many times the artifact's bytes were actually read off disk.
  var reads = 0;

  @override
  Future<HostBinary?> binaryFor(HostPlatform platform) async {
    final size = targets[platform.targetKey];
    if (size == null) return null;
    return HostBinary(
      length: size,
      // Counted, so a test can prove the skip path never reads the file.
      readBytes: () async {
        reads++;
        return Uint8List(size);
      },
      version: kHostVersion,
      isBundleArchive: isBundleArchive,
      source:
          'fake/karmashala_host-$kHostVersion-${platform.targetKey}'
          '${isBundleArchive ? '.tar.gz' : ''}',
    );
  }

  @override
  Future<List<String>> availableTargets() async =>
      targets.keys.toList()..sort();
}

HostDeployer deployerFor(
  FakeTarget target, {
  HostBinarySource? binaries,
}) => HostDeployer(
  target: target,
  binaries: binaries ?? FakeBinaries(),
  clock: () => DateTime.utc(2026, 9, 8, 14, 0),
  // Production waits 15 s for an answer across a network. Paying that three
  // times in the gate for hosts that are *meant* to stay silent is a minute of
  // nothing; the bound under test is that it gives up, not how long it waits.
  helloTimeout: const Duration(milliseconds: 50),
);

WelcomeMessage welcomeSaying(String version) => WelcomeMessage(
  requestId: 1,
  protocolVersion: kProtocolVersion,
  hostVersion: version,
  operatingSystem: 'linux',
  architecture: 'x64',
  ptyLibrary: 'libc.so.6',
  pid: 5,
  startedAt: DateTime.utc(2026),
  observedAt: DateTime.utc(2026),
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

    test(
      'a libc it could not read is unknown rather than assumed glibc',
      () async {
        final platform = await deployerFor(
          FakeTarget(uname: 'Linux\nx86_64\n'),
        ).measurePlatform();
        expect(platform!.libc, HostLibc.unknown);
      },
    );
  });

  group('platforms with nothing to send', () {
    test('musl is refused with the reason, and nothing is uploaded', () async {
      final target = FakeTarget(uname: 'Linux\nx86_64\nmusl libc (x86_64)\n');
      final deployment = await deployerFor(target).deploy();

      expect(deployment.status, HostDeploymentStatus.unsupportedPlatform);
      expect(deployment.reason, contains('musl'));
      expect(deployment.reason, contains('glibc-linked ELF'));
      expect(deployment.isReady, isFalse);
      expect(target.uploads, isEmpty);
    });

    test(
      'a Mac with no macOS bundle in this build says which it has',
      () async {
        final target = FakeTarget(uname: 'Darwin\narm64\n');
        final deployment = await deployerFor(target).deploy();

        expect(deployment.status, HostDeploymentStatus.noBinary);
        expect(deployment.reason, contains('macos-arm64'));
        expect(deployment.platform!.operatingSystem, 'darwin');
        expect(target.uploads, isEmpty);
      },
    );

    test(
      'a Mac is served the macos bundle, named macos and not darwin',
      () async {
        final target = FakeTarget(uname: 'Darwin\narm64\n')
          ..home = '/Users/dlohani';
        final deployment = await deployerFor(
          target,
          binaries: FakeBinaries(targets: const {'macos-arm64': 1024}),
        ).deploy();

        expect(deployment.status, HostDeploymentStatus.ready);
        expect(
          target.uploads.single.$1,
          '/Users/dlohani/.karmashala/bin/karmashala_host-$kHostVersion-macos-arm64',
        );
      },
    );

    test(
      'a Linux arch this build has no binary for names what it does have',
      () async {
        final target = FakeTarget(
          uname: 'Linux\nriscv64\nldd (GNU libc) 2.40\n',
        );
        final deployment = await deployerFor(target).deploy();

        expect(deployment.status, HostDeploymentStatus.noBinary);
        expect(deployment.reason, contains('linux-riscv64'));
        expect(deployment.reason, contains('linux-x64'));
      },
    );
  });

  group('where the files go', () {
    test('the deploy uploads to the path the shell resolved, not to a literal '
        r'$HOME', () async {
      final target = FakeTarget()..home = '/home/dlohani';
      final deployment = await deployerFor(target).deploy();

      // The bug, exactly: `mkdir` and `wc` expanded it and the upload did not,
      // so every deploy ended cannotInstall and every pane fell back to tmux.
      expect(deployment.status, HostDeploymentStatus.ready);
      expect(
        target.uploads.single.$1,
        '/home/dlohani/.karmashala/bin/karmashala_host-$kHostVersion-linux-x64',
      );
      expect(
        deployment.remotePath,
        '/home/dlohani/.karmashala/bin/karmashala_host-$kHostVersion-linux-x64',
      );
      expect(
        target.commands.where((c) => c.contains(r'$HOME')),
        // The one place `$HOME` is allowed is the question that resolves it.
        [r'echo "$HOME"'],
      );
      expect(target.commands.any((c) => c.contains('~')), isFalse);
    });

    test(
      'the home is resolved once, and every path is built from it',
      () async {
        final target = FakeTarget()
          ..home = '/srv/agents/dlohani'
          ..greet = ((_) => null);
        await deployerFor(target).deploy();

        expect(
          target.commands.where((c) => c.contains(r'echo "$HOME"')),
          hasLength(1),
        );
        expect(
          target.commands.firstWhere((c) => c.contains('mkdir -p')),
          contains("'/srv/agents/dlohani/.karmashala/bin'"),
        );
        final start = target.commands.firstWhere(
          (c) => c.contains('setsid nohup'),
        );
        expect(start, contains("'/srv/agents/dlohani/.karmashala'"));
        expect(start, contains("'/srv/agents/dlohani/.karmashala/host.log'"));
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test(
      'a machine that will not say where its home is uploads nothing',
      () async {
        final target = FakeTarget()..home = null;
        final deployment = await deployerFor(target).deploy();

        expect(deployment.status, HostDeploymentStatus.unknown);
        expect(deployment.reason, contains(r'echo "$HOME"'));
        expect(deployment.isReady, isFalse);
        expect(target.uploads, isEmpty);
      },
    );

    test(
      'a shell that printed something first is not read as a home',
      () async {
        final target = FakeTarget()..home = '/home/dlohani';
        target.scripted[r'echo "$HOME"'] = const RemoteRun(
          0,
          'Welcome to Ubuntu\n/home/dlohani\n',
          '',
        );
        final deployment = await deployerFor(target).deploy();

        expect(
          deployment.remotePath,
          startsWith('/home/dlohani/.karmashala/bin/'),
        );
      },
    );
  });

  group('a bundle, which is what every current build ships', () {
    FakeBinaries bundled() => FakeBinaries(isBundleArchive: true);

    test(
      'the archive is uploaded and the executable is run from inside it',
      () async {
        final target = FakeTarget()..home = '/home/dlohani';

        final deployment = await deployerFor(
          target,
          binaries: bundled(),
        ).deploy();

        expect(deployment.status, HostDeploymentStatus.ready);
        // The tarball lands beside the directory, not on top of the executable.
        expect(
          target.uploads.single.$1,
          '/home/dlohani/.karmashala/bin/karmashala_host-$kHostVersion-linux-x64.tar.gz',
        );
        // `../lib` has to resolve, so the executable cannot be flattened.
        expect(
          deployment.remotePath,
          '/home/dlohani/.karmashala/bin/karmashala_host-$kHostVersion-linux-x64.d/bin/karmashala_host',
        );
      },
    );

    test(
      'it is unpacked into a directory of its own, replacing what was there',
      () async {
        final target = FakeTarget()..home = '/home/dlohani';

        await deployerFor(target, binaries: bundled()).deploy();

        final unpack = target.commands.firstWhere(
          (c) => c.contains('tar -xzf'),
        );
        // An interrupted deploy leaves a half-extracted tree that looks installed.
        expect(unpack, contains('rm -rf'));
        expect(
          unpack,
          contains(
            "-C '/home/dlohani/.karmashala/bin/karmashala_host-$kHostVersion-linux-x64.d'",
          ),
        );
      },
    );

    test(
      'a machine with no tar says so rather than failing at the handshake',
      () async {
        final target = FakeTarget()..home = '/home/dlohani';
        target.scripted['tar -xzf'] = const RemoteRun(
          127,
          '',
          'sh: tar: not found',
        );

        final deployment = await deployerFor(
          target,
          binaries: bundled(),
        ).deploy();

        expect(deployment.status, HostDeploymentStatus.cannotInstall);
        expect(deployment.reason, contains('tar'));
      },
    );

    test(
      'an archive already the right size is still unpacked if nothing was',
      () async {
        final target = FakeTarget()
          ..home = '/home/dlohani'
          ..existingSize = 1024
          // The archive arrived once and was never extracted.
          ..executableInstalled = false;

        await deployerFor(target, binaries: bundled()).deploy();

        expect(target.commands.any((c) => c.contains('tar -xzf')), isTrue);
      },
    );

    test('an already-installed host is never read off disk', () async {
      final target = FakeTarget()
        ..home = '/home/dlohani'
        ..existingSize = 1024;
      final binaries = bundled();

      final deployment = await deployerFor(target, binaries: binaries).deploy();

      expect(deployment.status, HostDeploymentStatus.ready);
      expect(target.uploads, isEmpty);
      // The bytes are a whole bundle; the size is all the skip needs.
      expect(binaries.reads, 0);
    });

    test(
      'a bare binary from before the store is still installed in place',
      () async {
        final target = FakeTarget()..home = '/home/dlohani';

        final deployment = await deployerFor(
          target,
          binaries: FakeBinaries(),
        ).deploy();

        expect(
          deployment.remotePath,
          '/home/dlohani/.karmashala/bin/karmashala_host-$kHostVersion-linux-x64',
        );
        expect(target.commands.any((c) => c.contains('tar -xzf')), isFalse);
      },
    );
  });

  group('installing', () {
    test('uploads, chmods, and reports the version it put there', () async {
      final target = FakeTarget();
      final deployment = await deployerFor(target).deploy();

      expect(deployment.status, HostDeploymentStatus.ready);
      expect(
        target.uploads.single.$1,
        contains('karmashala_host-$kHostVersion-linux-x64'),
      );
      expect(target.uploads.single.$2, 1024);
      expect(
        deployment.remotePath,
        '/home/fake/.karmashala/bin/karmashala_host-$kHostVersion-linux-x64',
      );
      expect(deployment.hostVersion, kHostVersion);
      expect(deployment.protocolVersion, kProtocolVersion);
      expect(deployment.observedAt, DateTime.utc(2026, 9, 8, 14, 0));
      expect(target.commands.any((c) => c.contains('chmod +x')), isTrue);
    });

    test(
      'skips the upload when the remote file is already this build',
      () async {
        final target = FakeTarget()..existingSize = 1024;
        final deployment = await deployerFor(target).deploy();

        expect(deployment.status, HostDeploymentStatus.ready);
        expect(
          target.uploads,
          isEmpty,
          reason: 'same name, same size, same build',
        );
        expect(
          target.commands.any((c) => c.contains('chmod +x')),
          isTrue,
          reason: 'a restored file can be the right size and not executable',
        );
      },
    );

    test(
      'a different size means a different build and is re-uploaded',
      () async {
        final target = FakeTarget()..existingSize = 999;
        await deployerFor(target).deploy();
        expect(target.uploads, hasLength(1));
      },
    );

    test(
      'a read-only home is reported as cannot-install, in those words',
      () async {
        final target = FakeTarget()
          ..uploadError = StateError('permission denied');
        final deployment = await deployerFor(target).deploy();

        expect(deployment.status, HostDeploymentStatus.cannotInstall);
        expect(deployment.reason, contains('read-only home'));
        expect(deployment.isReady, isFalse);
      },
    );

    test(
      'a noexec home is caught by the chmod check, not discovered later',
      () async {
        final target = FakeTarget()
          ..scripted['chmod +x'] = const RemoteRun(
            1,
            '',
            'Operation not permitted',
          );
        final deployment = await deployerFor(target).deploy();

        expect(deployment.status, HostDeploymentStatus.cannotInstall);
        expect(deployment.reason, contains('noexec'));
      },
    );
  });

  group('starting and greeting', () {
    test('a host that answers first time is never started twice', () async {
      final target = FakeTarget();
      final deployment = await deployerFor(target).deploy();

      expect(deployment.isReady, isTrue);
      expect(target.execCount, 1, reason: 'one hello, no restart');
      expect(target.commands.any((c) => c.contains('setsid nohup')), isFalse);
    });

    test(
      'a silent host is started with setsid nohup and then asked again',
      () async {
        final target = FakeTarget();
        var asked = 0;
        target.greet = (hello) {
          asked++;
          return asked == 1
              ? null
              : WelcomeMessage(
                  requestId: 1,
                  protocolVersion: kProtocolVersion,
                  hostVersion: kHostVersion,
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
        final start = target.commands.firstWhere(
          (c) => c.contains('setsid nohup'),
        );
        expect(start, contains('serve'));
        // The server's default folder — off tmpfs, beside the binaries,
        // holding this box's pairings — so no --data-dir; phones served on
        // every interface as a box always was.
        expect(start, isNot(contains('--data-dir')));
        expect(start, contains("mkdir -p '/home/fake/.karmashala'"));
        expect(start, contains("serve --companion '--bind=0.0.0.0'"));
        expect(
          start,
          contains('< /dev/null'),
          reason: 'the channel must not stay open',
        );
        expect(start, contains('host.log'));
      },
      timeout: const Timeout(Duration(seconds: 40)),
    );

    test('a serve from an older binary, holding nothing, is replaced', () async {
      // Every build reports the same `hostVersion`, so the *path* is what says
      // which one is running.
      final target = FakeTarget()
        ..runningServe =
            '/home/fake/.karmashala/bin/karmashala_host-0.0.9-linux-x64';

      final deployment = await deployerFor(target).deploy();

      expect(deployment.isReady, isTrue);
      expect(deployment.restartedByUs, isTrue);
      expect(
        target.commands.any((c) => c.contains('karmashala-still-running')),
        isTrue,
      );
      expect(target.commands.any((c) => c.contains('setsid nohup')), isTrue);
    }, timeout: const Timeout(Duration(seconds: 40)));

    test('an older serve with work on it is left alone, and says so', () async {
      final target = FakeTarget()
        ..heldSessions = 2
        ..runningServe =
            '/home/fake/.karmashala/bin/karmashala_host-0.0.9-linux-x64';

      final deployment = await deployerFor(target).deploy();

      // Ready, because it answers and speaks the protocol — replacing it would
      // cost the two sessions, which is never this method's call to make.
      expect(deployment.isReady, isTrue);
      expect(deployment.restartedByUs, isFalse);
      expect(deployment.reason, contains('karmashala_host-0.0.9-linux-x64'));
      expect(deployment.reason, contains('2 session(s)'));
      expect(deployment.reason, contains('left alone'));
      expect(
        target.commands.any((c) => c.contains('karmashala-still-running')),
        isFalse,
      );
    }, timeout: const Timeout(Duration(seconds: 40)));

    test(
      'an older serve that will not say what it holds is not touched',
      () async {
        final target = FakeTarget()
          ..heldSessions = null
          ..runningServe =
              '/home/fake/.karmashala/bin/karmashala_host-0.0.9-linux-x64';

        final deployment = await deployerFor(target).deploy();

        expect(deployment.reason, contains('would not say'));
        expect(
          target.commands.any((c) => c.contains('karmashala-still-running')),
          isFalse,
        );
      },
      timeout: const Timeout(Duration(seconds: 40)),
    );

    test(
      'an older serve that will not stop is reported, not pretended about',
      () async {
        final target = FakeTarget()
          ..stopOutput = 'karmashala-still-running\n'
          ..runningServe =
              '/home/fake/.karmashala/bin/karmashala_host-0.0.9-linux-x64';

        final deployment = await deployerFor(target).deploy();

        expect(deployment.restartedByUs, isFalse);
        expect(deployment.reason, contains('could not be replaced'));
      },
      timeout: const Timeout(Duration(seconds: 40)),
    );

    test(
      'a serve from this very binary is never asked to stand down',
      () async {
        final target = FakeTarget();

        final deployment = await deployerFor(target).deploy();

        expect(
          target.commands.any((c) => c.contains('karmashala-still-running')),
          isFalse,
        );
        expect(deployment.reason, isNot(contains('installed beside it')));
      },
      timeout: const Timeout(Duration(seconds: 40)),
    );

    test(
      'a machine that will not name the running serve is left alone',
      () async {
        final target = FakeTarget()..runningServe = null;

        final deployment = await deployerFor(target).deploy();

        expect(deployment.isReady, isTrue);
        expect(
          target.commands.any((c) => c.contains('karmashala-still-running')),
          isFalse,
        );
      },
      timeout: const Timeout(Duration(seconds: 40)),
    );

    test(
      'a host that was already running is not reported as restarted',
      () async {
        final deployment = await deployerFor(FakeTarget()).deploy();
        expect(deployment.isReady, isTrue);
        expect(deployment.restartedByUs, isFalse);
        expect(deployment.reason, isNot(contains('restarted')));
      },
    );

    test(
      'a host that had to be started reports that its sessions are gone',
      () async {
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
                  hostVersion: kHostVersion,
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
        expect(
          deployment.reason,
          contains('was not running and has been restarted'),
        );
        expect(deployment.reason, contains('sessions it held before are gone'));
        expect(target.commands.any((c) => c.contains('setsid nohup')), isTrue);
      },
    );

    test(
      'a host that would not start is still reported as one we tried to start',
      () async {
        final target = FakeTarget()
          ..greet = ((_) => null)
          ..scripted['setsid nohup'] = const RemoteRun(
            127,
            '',
            'sh: setsid: not found',
          );
        final deployment = await deployerFor(target).deploy();
        expect(deployment.restartedByUs, isTrue);
      },
    );

    test('a host that never answers is cannot-start, and falls back', () async {
      final target = FakeTarget()..greet = (_) => null;
      final deployment = await deployerFor(target).deploy();

      expect(deployment.status, HostDeploymentStatus.cannotStart);
      expect(deployment.reason, contains('never answered `hello`'));
      expect(deployment.isReady, isFalse);
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('a serve that will not start quotes what the machine said', () async {
      // The closure is parenthesised because a cascade after `=> null` binds
      // to the null, not to the target.
      final target = FakeTarget()
        ..greet = ((_) => null)
        ..scripted['setsid nohup'] = const RemoteRun(
          127,
          '',
          'sh: setsid: not found',
        );
      final deployment = await deployerFor(target).deploy();

      expect(deployment.status, HostDeploymentStatus.cannotStart);
      expect(deployment.reason, contains('setsid: not found'));
    }, timeout: const Timeout(Duration(seconds: 40)));

    test(
      'an older host still running is reported as a protocol mismatch',
      () async {
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
        // It runs from the path this deploy installs, so the files under it
        // were replaced; this build's bundle is this app's, so there is newer.
        expect(
          deployment.reason,
          contains('running from files that have since been replaced'),
        );
        expect(deployment.noNewerHost, isFalse);
        expect(deployment.isReady, isFalse);

        // From another bundle, it is a stale `serve` beside this app's.
        final beside = FakeTarget()
          ..runningServe =
              '/home/fake/.karmashala/bin/karmashala_host-0.0.9-linux-x64'
          ..greet = target.greet;
        final stale = await deployerFor(beside).deploy();
        expect(stale.status, HostDeploymentStatus.protocolMismatch);
        expect(stale.reason, contains('stale `serve` (0.0.9)'));
      },
    );

    test(
      'a refusal that is not a version mismatch is not read as one',
      () async {
        final target = FakeTarget()
          ..greet = ((_) => const ErrorMessage(
            1,
            ProtocolErrorCode.internal,
            'something else entirely',
          ));
        final deployment = await deployerFor(target).deploy();

        expect(deployment.status, HostDeploymentStatus.cannotStart);
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );
  });

  group('HostPlatform', () {
    test(
      'normalises the architectures that matter and leaves the rest alone',
      () {
        expect(HostPlatform.normaliseArchitecture('x86_64'), 'x64');
        expect(HostPlatform.normaliseArchitecture('amd64'), 'x64');
        expect(HostPlatform.normaliseArchitecture('aarch64'), 'arm64');
        expect(HostPlatform.normaliseArchitecture('armv7l'), 'armv7l');
      },
    );
  });
}
