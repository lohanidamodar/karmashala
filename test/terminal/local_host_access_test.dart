import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/ssh/domain/host_deployment.dart';
import 'package:karmashala/src/features/terminal/data/local_host_access.dart';
import 'package:karmashala_host/karmashala_host.dart';

/// The app's end of the local transport, against a **real** session host in
/// this process: a real unix domain socket, the real `HostServer`, the real
/// protocol. Only the pty is a fake, because a test does not need a shell to
/// prove that the app can reach a host and read what it says.
///
/// The socket is the point. Nothing here is a named pipe or a loopback port,
/// and this file is what makes that claim checkable on Windows as well as
/// POSIX — `ServerSocket` binds `AF_UNIX` on both.
void main() {
  late Directory home;
  late HostPaths paths;

  setUp(() {
    home = Directory.systemTemp.createTempSync('karmashala-local-access');
    paths = HostPaths(Directory('${home.path}/.karmashala'))..ensureDirectory();
  });
  tearDown(() {
    try {
      home.deleteSync(recursive: true);
    } on FileSystemException {
      // A socket node can still be held on Windows; the temp directory is the
      // OS's problem after that.
    }
  });

  /// A host listening on [paths], with no operating system behind its pty.
  Future<UnixSocketHostListener> serve() async {
    final registry = SessionRegistry(launcher: FakePtyLauncher());
    final server = HostServer(registry: registry, ptyLibrary: 'fake');
    final listener = await UnixSocketHostListener.bind(paths.socketPath);
    final subscription = server.listen(listener);
    addTearDown(() async {
      await subscription.cancel();
      await listener.close();
      await registry.shutdown();
    });
    return listener;
  }

  File anExecutable() {
    final file = File('${home.path}/${LocalHostExecutable.fileName}')
      ..writeAsStringSync('not really a binary');
    return file;
  }

  test('a host that is already listening is ready, and nothing was started', () async {
    await serve();
    var started = 0;
    final access = LocalHostSessionAccess(
      paths: paths,
      executable: LocalHostExecutable(executableDirectory: home.path),
      startServe: (_) async {
        started++;
        throw StateError('nothing should have been started');
      },
    );
    anExecutable();

    final reading = await access.deployment();
    expect(reading.status, HostDeploymentStatus.ready);
    expect(reading.restartedByUs, isFalse);
    expect(reading.hostVersion, kHostVersion);
    expect(reading.protocolVersion, kProtocolVersion);
    expect(started, 0);
  });

  test('a reading is memoised on the future, so two panes share one', () async {
    await serve();
    anExecutable();
    final access = LocalHostSessionAccess(
      paths: paths,
      executable: LocalHostExecutable(executableDirectory: home.path),
    );
    final both = await Future.wait([access.deployment(), access.deployment()]);
    expect(identical(both.first, both.last), isTrue);
  });

  test('with no binary anywhere it says where it looked, and starts nothing', () async {
    var started = 0;
    final access = LocalHostSessionAccess(
      paths: paths,
      executable: LocalHostExecutable(
        executableDirectory: '${home.path}/absent',
        repositoryRoot: '${home.path}/absent',
      ),
      startServe: (_) async {
        started++;
        throw StateError('nothing to start');
      },
    );
    final reading = await access.deployment();
    expect(reading.status, HostDeploymentStatus.noBinary);
    expect(reading.reason, contains(LocalHostExecutable.fileName));
    expect(reading.reason, contains('absent'));
    expect(started, 0);
  });

  test('a host that was not running is started, and the reading says we did it', () async {
    anExecutable();
    final access = LocalHostSessionAccess(
      paths: paths,
      executable: LocalHostExecutable(executableDirectory: home.path),
      // What a real `serve` does: bind the socket, then print where. The banner
      // is the event the start waits on — nothing sleeps and nothing polls.
      startServe: (_) async {
        await serve();
        return _FakeProcess('karmashala_host serving on ${paths.socketPath}\n');
      },
    );

    final reading = await access.deployment();
    expect(reading.status, HostDeploymentStatus.ready);
    expect(reading.restartedByUs, isTrue, reason: 'the honest version of having no supervisor');
    expect(reading.reason, contains('Started'));
  });

  test('a host that was started and still does not answer is refused, with what it said', () async {
    anExecutable();
    final access = LocalHostSessionAccess(
      paths: paths,
      executable: LocalHostExecutable(executableDirectory: home.path),
      startServe: (_) async => _FakeProcess(
        'karmashala_host serving on ${paths.socketPath}\n',
      ),
    );
    final reading = await access.deployment();
    expect(reading.status, HostDeploymentStatus.cannotStart);
    expect(reading.reason, contains(paths.socketPath));
  });

  test('a serve that exits is quoted rather than waited out', () async {
    anExecutable();
    final access = LocalHostSessionAccess(
      paths: paths,
      executable: LocalHostExecutable(executableDirectory: home.path),
      startServe: (_) async =>
          _FakeProcess('', stderr: 'no usable libc on this machine\n', exitCode: 4),
    );
    final reading = await access.deployment();
    expect(reading.status, HostDeploymentStatus.cannotStart);
    expect(reading.reason, contains('exited 4'));
    expect(reading.reason, contains('no usable libc'));
  });

  group('observe', () {
    test('answers unknown when nothing is listening, and starts nothing', () async {
      anExecutable();
      var started = 0;
      final access = LocalHostSessionAccess(
        paths: paths,
        executable: LocalHostExecutable(executableDirectory: home.path),
        startServe: (_) async {
          started++;
          throw StateError('a status row must not launch a daemon');
        },
      );

      final reading = await access.observe();
      // Unknown, not "unavailable": reading Settings is looking, not deciding.
      expect(reading.status, HostDeploymentStatus.unknown);
      expect(reading.reason, contains(paths.socketPath));
      expect(started, 0);
      expect(access.lastReading, isNull, reason: 'nobody has taken a real reading yet');
    });

    test('reports the version and the time it was read when one answers', () async {
      await serve();
      anExecutable();
      final access = LocalHostSessionAccess(
        paths: paths,
        executable: LocalHostExecutable(executableDirectory: home.path),
      );
      final before = DateTime.now();
      final reading = await access.observe();
      expect(reading.status, HostDeploymentStatus.ready);
      expect(reading.hostVersion, kHostVersion);
      expect(reading.observedAt.isBefore(before), isFalse);
    });
  });

  test('a dial that fails forgets the reading, so the next pane measures again', () async {
    final listener = await serve();
    anExecutable();
    final access = LocalHostSessionAccess(
      paths: paths,
      executable: LocalHostExecutable(executableDirectory: home.path),
    );
    expect((await access.deployment()).status, HostDeploymentStatus.ready);

    await listener.close();
    await expectLater(access.exec('attach'), throwsA(isA<SocketException>()));
    expect(access.lastReading, isNotNull);
    // Forgotten: a remembered `ready` would send every later pane at a socket
    // nothing is listening on.
    var measuredAgain = false;
    final second = LocalHostSessionAccess(
      paths: paths,
      executable: LocalHostExecutable(executableDirectory: home.path),
      startServe: (_) async {
        measuredAgain = true;
        return _FakeProcess('', exitCode: 1);
      },
    );
    await second.deployment();
    expect(measuredAgain, isTrue);
  });
}

/// A process that says what a test wants it to say. Not a real one on purpose:
/// starting a real `serve` here would bind the developer's own socket and take
/// their sessions with it when the test tore it down.
class _FakeProcess implements Process {
  _FakeProcess(String out, {String stderr = '', int exitCode = 0})
    : _out = Stream.value(utf8.encode(out)),
      _err = Stream.value(utf8.encode(stderr)),
      _exit = exitCode;

  final Stream<List<int>> _out;
  final Stream<List<int>> _err;
  final int _exit;

  @override
  Stream<List<int>> get stdout => _out;

  @override
  Stream<List<int>> get stderr => _err;

  @override
  IOSink get stdin => throw UnimplementedError();

  @override
  Future<int> get exitCode async => _exit;

  @override
  int get pid => 4242;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => true;
}
