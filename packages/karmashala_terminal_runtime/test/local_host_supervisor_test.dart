import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_ssh/host.dart';
import 'package:karmashala_terminal_core/pane_lifecycle.dart';
import 'package:karmashala_terminal_runtime/host_link.dart';
import 'package:karmashala_terminal_runtime/instances.dart';
import 'package:karmashala_terminal_runtime/launch.dart';
import 'package:karmashala_terminal_runtime/screen_reading.dart';

/// The app keeps this machine's host up while it is open — against **real**
/// hosts in this process on a real unix socket, as the access's own tests do.
/// Only `serve` is faked: a test must never start a daemon on the developer's
/// socket. Each fake `serve` binds a real `HostServer` where the real one
/// would, and says the banner the real one says.
void main() {
  late Directory home;
  late HostPaths paths;

  setUp(() {
    home = Directory.systemTemp.createTempSync('karmashala-supervisor');
    paths = HostPaths(Directory('${home.path}/.karmashala'))..ensureDirectory();
  });
  tearDown(() {
    try {
      home.deleteSync(recursive: true);
    } on FileSystemException {
      // A socket node can still be held on Windows.
    }
  });

  File anExecutable() {
    final file = File('${home.path}/${LocalHostExecutable.fileName}');
    if (!file.existsSync()) file.writeAsStringSync('not really a binary');
    return file;
  }

  /// A host listening on [paths], of this app's build.
  Future<_Host> serve() async {
    final binary = anExecutable();
    final launcher = FakePtyLauncher();
    final registry = SessionRegistry(launcher: launcher);
    final server = HostServer(
      registry: registry,
      ptyLibrary: 'fake',
      build: hostBuildOf(binary.path),
    );
    final listener = _TrackingListener(
      await UnixSocketHostListener.bind(paths.socketPath),
    );
    final host = _Host(listener, server.listen(listener), registry, launcher);
    addTearDown(host.kill);
    return host;
  }

  String banner() => 'karmashala_host serving on ${paths.socketPath}\n';

  LocalHostSupervisor supervise(
    LocalHostSessionAccess access, {
    List<Duration> backoff = const [
      Duration(milliseconds: 10),
      Duration(milliseconds: 10),
      Duration(milliseconds: 10),
    ],
    Duration stableAfter = const Duration(hours: 1),
    Duration outdatedRecheck = const Duration(hours: 1),
  }) {
    final supervisor = LocalHostSupervisor(
      access: access,
      backoff: backoff,
      stableAfter: stableAfter,
      outdatedRecheck: outdatedRecheck,
    );
    addTearDown(supervisor.dispose);
    return supervisor;
  }

  Future<HostSupervision> phase(
    LocalHostSupervisor supervisor,
    HostSupervisionPhase wanted,
  ) async {
    if (supervisor.state.phase == wanted) return supervisor.state;
    return supervisor.changes
        .firstWhere((s) => s.phase == wanted)
        .timeout(const Duration(seconds: 5));
  }

  group('a host that goes away while the app is open', () {
    test('is started again, through the launch\'s own start, and everything '
        'that rides it is told', () async {
      final first = await serve();
      final binary = anExecutable();
      final starts = <String>[];
      final access = LocalHostSessionAccess(
        paths: paths,
        executable: LocalHostExecutable(executableDirectory: home.path),
        serveFlags: ['--data-dir=${home.path}/data'],
        startServe: (path) async {
          starts.add(path);
          await serve();
          return _ServeProcess(banner());
        },
      );
      final supervisor = supervise(access);

      final reading = await supervisor.start();
      expect(reading?.isReady, isTrue);
      expect(starts, isEmpty, reason: 'one was already listening');
      expect(supervisor.state.phase, HostSupervisionPhase.running);
      expect(supervisor.state.pid, pid);

      final restarted = supervisor.restarted.first;
      await first.kill();
      supervisor.hostLost('the lifecycle link to it closed');

      final back = await restarted.timeout(const Duration(seconds: 5));
      expect(back.isReady, isTrue);
      expect(back.restartedByUs, isTrue);
      expect(starts, [binary.path]);
      expect(supervisor.state.phase, HostSupervisionPhase.running);
      // The arguments the start uses are the launch's, data folder and all.
      expect(await access.serveArguments(), [
        'serve',
        '--data-dir=${home.path}/data',
      ]);
    });

    test(
      'a link that drops while the host still answers restarts nothing',
      () async {
        await serve();
        final access = LocalHostSessionAccess(
          paths: paths,
          executable: LocalHostExecutable(executableDirectory: home.path),
          startServe: (_) async =>
              throw StateError('a host was started over a live one'),
        );
        anExecutable();
        final supervisor = supervise(access);
        await supervisor.start();

        supervisor.hostLost('the lifecycle link to it closed');
        await Future<void>.delayed(const Duration(milliseconds: 100));

        expect(supervisor.state.phase, HostSupervisionPhase.running);
      },
    );

    test('the serve it started closing its pipes is noticed with no link at '
        'all, and its last words are kept', () async {
      final processes = <_ServeProcess>[];
      final hosts = <_Host>[];
      final access = LocalHostSessionAccess(
        paths: paths,
        executable: LocalHostExecutable(executableDirectory: home.path),
        startServe: (_) async {
          hosts.add(await serve());
          final process = _ServeProcess(banner());
          processes.add(process);
          return process;
        },
      );
      anExecutable();
      final supervisor = supervise(access);
      expect((await supervisor.start())?.isReady, isTrue);
      expect(processes, hasLength(1));

      final restarted = supervisor.restarted.first;
      await hosts.single.kill();
      processes.single.exit('panic: the store went away');

      await restarted.timeout(const Duration(seconds: 5));
      expect(processes, hasLength(2));
      expect(supervisor.state.phase, HostSupervisionPhase.running);
    });

    test(
      'a serve whose pipes close while its host answers is not a loss',
      () async {
        var starts = 0;
        final access = LocalHostSessionAccess(
          paths: paths,
          executable: LocalHostExecutable(executableDirectory: home.path),
          startServe: (_) async {
            starts++;
            await serve();
            return _ServeProcess(banner())..exit();
          },
        );
        anExecutable();
        final supervisor = supervise(access);
        await supervisor.start();
        await Future<void>.delayed(const Duration(milliseconds: 100));

        expect(starts, 1);
        expect(supervisor.state.phase, HostSupervisionPhase.running);
      },
    );
  });

  group('a crash loop', () {
    test('a serve that exits before serving every time stops being retried '
        'after the cap, with its own words as the reason', () async {
      var starts = 0;
      final access = LocalHostSessionAccess(
        paths: paths,
        executable: LocalHostExecutable(executableDirectory: home.path),
        startServe: (_) async {
          starts++;
          return _ServeProcess('', stderr: 'fatal: the store is locked\n')
            ..exit();
        },
      );
      anExecutable();
      final supervisor = supervise(access);

      await supervisor.start();
      final stopped = await phase(supervisor, HostSupervisionPhase.stopped);

      expect(starts, 4, reason: 'the launch, then one per delay');
      expect(stopped.reason, contains('3 times in a row'));
      expect(stopped.reason, contains('fatal: the store is locked'));
      expect(stopped.lastOutput, ['fatal: the store is locked']);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(starts, 4, reason: 'it went on after the cap');

      // The person's restart is the way out, and it starts the count again.
      await supervisor.restartNow();
      expect(starts, 5);
    });

    test('a host that comes up and dies at once every time is a crash loop '
        'too: the count is not cleared until it stays up', () async {
      var starts = 0;
      final access = LocalHostSessionAccess(
        paths: paths,
        executable: LocalHostExecutable(executableDirectory: home.path),
        startServe: (_) async {
          starts++;
          final host = await serve();
          final process = _ServeProcess(banner());
          unawaited(
            Future<void>.delayed(const Duration(milliseconds: 20), () async {
              await host.kill();
              process.exit('panic: boom');
            }),
          );
          return process;
        },
      );
      anExecutable();
      final supervisor = supervise(access);

      await supervisor.start();
      final stopped = await phase(supervisor, HostSupervisionPhase.stopped);

      expect(starts, 4);
      expect(stopped.reason, contains('panic: boom'));
      expect(stopped.lastOutput, contains('panic: boom'));
    });

    test('with no binary there is nothing to retry', () async {
      final access = LocalHostSessionAccess(
        paths: paths,
        executable: LocalHostExecutable(
          executableDirectory: home.path,
          repositoryRoot: home.path,
        ),
      );
      final supervisor = supervise(access);
      await supervisor.start();
      expect(supervisor.state.phase, HostSupervisionPhase.stopped);
      expect(supervisor.state.reason, contains('No karmashala_host'));
    });
  });

  group('a host that speaks an older protocol', () {
    Future<_MismatchedHost> mismatched() async {
      final host = await _MismatchedHost.bind(paths.socketPath);
      addTearDown(host.close);
      return host;
    }

    void recordSession(String id, String state) {
      final dir = Directory('${paths.sessionsDirectory}/$id')
        ..createSync(recursive: true);
      File(
        '${dir.path}/meta.json',
      ).writeAsStringSync(jsonEncode({'version': 1, 'id': id, 'state': state}));
    }

    test('holding no running sessions, it is replaced', () async {
      final old = await mismatched();
      recordSession('karmashala_done', 'exited');
      final stops = <bool>[];
      final access = LocalHostSessionAccess(
        paths: paths,
        executable: LocalHostExecutable(executableDirectory: home.path),
        stopServe: (_, {required force}) async {
          stops.add(force);
          await old.close();
          return null;
        },
        startServe: (_) async {
          await serve();
          return _ServeProcess(banner());
        },
      );
      anExecutable();
      final supervisor = supervise(access);

      final reading = await supervisor.start();
      expect(reading?.isReady, isTrue, reason: reading?.reason);
      expect(reading?.reason, contains('spoke another protocol'));
      // It cannot be asked what it holds, so its own `stop` would refuse it;
      // its records said nothing runs.
      expect(stops, [true]);
      expect(supervisor.state.phase, HostSupervisionPhase.running);
    });

    test('holding a running session, it is left running and the person is '
        'told how many a restart ends; only their restart ends them', () async {
      final old = await mismatched();
      recordSession('karmashala_live', 'running');
      final stops = <bool>[];
      final access = LocalHostSessionAccess(
        paths: paths,
        executable: LocalHostExecutable(executableDirectory: home.path),
        stopServe: (_, {required force}) async {
          stops.add(force);
          await old.close();
          return null;
        },
        startServe: (_) async {
          await serve();
          return _ServeProcess(banner());
        },
      );
      anExecutable();
      final supervisor = supervise(access);

      final reading = await supervisor.start();
      expect(reading?.status, HostDeploymentStatus.protocolMismatch);
      expect(reading?.hostOutdated, isTrue);
      expect(reading?.liveSessionIds, ['karmashala_live']);
      expect(stops, isEmpty, reason: 'a host holding live sessions was killed');
      expect(supervisor.state.phase, HostSupervisionPhase.outdated);
      expect(supervisor.state.heldSessions, ['karmashala_live']);
      expect(access.acceptsPane('karmashala_local_new'), isFalse);

      // Asked again and again, it is still left alone.
      supervisor.hostLost('the lifecycle link to it closed');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(stops, isEmpty);

      final back = await supervisor.restartNow(force: true);
      expect(stops, [true]);
      expect(back?.isReady, isTrue);
      expect(supervisor.state.phase, HostSupervisionPhase.running);
    });

    test('once its sessions end, the next look replaces it', () async {
      final old = await mismatched();
      recordSession('karmashala_live', 'running');
      final stops = <bool>[];
      final access = LocalHostSessionAccess(
        paths: paths,
        executable: LocalHostExecutable(executableDirectory: home.path),
        stopServe: (_, {required force}) async {
          stops.add(force);
          await old.close();
          return null;
        },
        startServe: (_) async {
          await serve();
          return _ServeProcess(banner());
        },
      );
      anExecutable();
      final supervisor = supervise(
        access,
        outdatedRecheck: const Duration(milliseconds: 20),
      );

      await supervisor.start();
      expect(supervisor.state.phase, HostSupervisionPhase.outdated);
      recordSession('karmashala_live', 'exited');

      await phase(supervisor, HostSupervisionPhase.running);
      expect(stops, [true]);
    });

    test('records it cannot read count as running sessions', () async {
      await mismatched();
      Directory(
        '${paths.sessionsDirectory}/broken',
      ).createSync(recursive: true);
      File(
        '${paths.sessionsDirectory}/broken/meta.json',
      ).writeAsStringSync('{');
      final access = LocalHostSessionAccess(
        paths: paths,
        executable: LocalHostExecutable(executableDirectory: home.path),
        stopServe: (_, {required force}) async =>
            throw StateError('a host that may hold sessions was killed'),
      );
      anExecutable();
      final supervisor = supervise(access);

      final reading = await supervisor.start();
      expect(reading?.liveSessionIds, isNull);
      expect(supervisor.state.phase, HostSupervisionPhase.outdated);
    });
  });

  group('a pane whose host died', () {
    const launch = PtyLaunch(executable: '/bin/sh', arguments: []);

    HostTerminalInstance paneOn(LocalHostSessionAccess access) {
      final pane = HostTerminalInstance(
        id: 'p1',
        title: 'Local',
        profileId: 'sh',
        access: access,
        launch: launch,
        redialDelays: const [
          Duration(milliseconds: 20),
          Duration(milliseconds: 20),
          Duration(milliseconds: 20),
          Duration(milliseconds: 20),
        ],
      );
      pane.terminal.resize(80, 24);
      addTearDown(pane.dispose);
      return pane;
    }

    String screenOf(HostTerminalInstance pane) =>
        terminalTailLines(pane.terminal, lines: 50).join('\n');

    Future<void> ended(HostTerminalInstance pane) async {
      if (pane.liveness.value == PaneLiveness.exited) return;
      final done = Completer<void>();
      void look() {
        if (pane.liveness.value == PaneLiveness.exited && !done.isCompleted) {
          done.complete();
        }
      }

      pane.liveness.addListener(look);
      try {
        await done.future.timeout(const Duration(seconds: 5));
      } finally {
        pane.liveness.removeListener(look);
      }
    }

    test('ends with no code when nobody answers any more, and starts no '
        'host of its own', () async {
      final host = await serve();
      anExecutable();
      final access = LocalHostSessionAccess(
        paths: paths,
        executable: LocalHostExecutable(executableDirectory: home.path),
        startServe: (_) async =>
            throw StateError('a pane started a host; the supervisor does'),
      );
      final pane = paneOn(access);
      await _until(() => host.launcher.handles.isNotEmpty);

      await host.kill();
      await ended(pane);

      expect(pane.exitCode, isNull);
      expect(screenOf(pane), contains('the session host stopped'));
    });

    test('meeting a new host in its place, ends with no code and never opens '
        'a fresh session there', () async {
      final first = await serve();
      anExecutable();
      final access = LocalHostSessionAccess(
        paths: paths,
        executable: LocalHostExecutable(executableDirectory: home.path),
      );
      final pane = paneOn(access);
      await _until(() => first.launcher.handles.isNotEmpty);

      await first.kill();
      final second = await serve();
      await ended(pane);

      expect(pane.exitCode, isNull);
      expect(screenOf(pane), contains('the session host stopped'));
      expect(second.launcher.started, isEmpty, reason: 'a fresh empty session');
      expect(second.registry.sessions, isEmpty);
    });
  });
}

/// Waits for [condition], bounded: a pane's attach is asynchronous and has no
/// event of its own to wait on here.
Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 250 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  expect(condition(), isTrue);
}

class _Host {
  _Host(this.listener, this.subscription, this.registry, this.launcher);

  final _TrackingListener listener;
  final StreamSubscription<void> subscription;
  final SessionRegistry registry;
  final FakePtyLauncher launcher;
  var _killed = false;

  /// What the host dying looks like from the app: every link on it closes
  /// and its socket goes — before its sessions could say they ended.
  Future<void> kill() async {
    if (_killed) return;
    _killed = true;
    await subscription.cancel();
    await listener.close();
    for (final connection in listener.opened) {
      await connection.close();
    }
    for (final handle in launcher.handles) {
      handle.finish(0);
    }
    await registry.shutdown();
  }
}

/// The host's listener, remembering every connection so a test can drop them
/// all at once, as a host that died does.
class _TrackingListener implements HostListener {
  _TrackingListener(this._inner);

  final UnixSocketHostListener _inner;
  final opened = <HostConnection>[];

  @override
  String get address => _inner.address;

  @override
  Stream<HostConnection> get connections =>
      _inner.connections.map((connection) {
        opened.add(connection);
        return connection;
      });

  @override
  Future<void> close() => _inner.close();
}

/// A host of an earlier build that speaks another protocol: it refuses the
/// hello with `protocolMismatch`, as the real one does, and hangs up.
class _MismatchedHost {
  _MismatchedHost._(this._server);

  final ServerSocket _server;
  final _held = <Socket>[];
  var _closed = false;

  static Future<_MismatchedHost> bind(String path) async {
    final server = await ServerSocket.bind(
      InternetAddress(path, type: InternetAddressType.unix),
      0,
    );
    final host = _MismatchedHost._(server);
    server.listen(host._accept);
    return host;
  }

  void _accept(Socket socket) {
    _held.add(socket);
    final parser = FrameParser();
    socket.listen((bytes) {
      for (final frame in parser.add(bytes)) {
        final message = decodeMessage(frame);
        if (message is HelloMessage) {
          socket.add(
            ErrorMessage(
              message.requestId,
              ProtocolErrorCode.protocolMismatch,
              'host speaks protocol 1, client speaks $kProtocolVersion',
            ).toFrame().encode(),
          );
          unawaited(socket.close());
        }
      }
    }, onError: (Object _) {});
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final socket in _held) {
      socket.destroy();
    }
    await _server.close();
    final node = File(_server.address.address);
    if (node.existsSync()) node.deleteSync();
  }
}

/// A `serve` started the way the app starts one: detached, with pipes and no
/// exit code. Its pipes stay open until [exit], as a live host's do.
class _ServeProcess implements Process {
  _ServeProcess(String out, {String stderr = ''}) {
    if (out.isNotEmpty) _out.add(utf8.encode(out));
    if (stderr.isNotEmpty) _err.add(utf8.encode(stderr));
  }

  final _out = StreamController<List<int>>();
  final _err = StreamController<List<int>>();

  /// The process ends: its last words, then both pipes close.
  void exit([String lastWords = '']) {
    if (lastWords.isNotEmpty) _err.add(utf8.encode('$lastWords\n'));
    unawaited(_out.close());
    unawaited(_err.close());
  }

  @override
  Stream<List<int>> get stdout => _out.stream;

  @override
  Stream<List<int>> get stderr => _err.stream;

  @override
  IOSink get stdin => throw UnimplementedError();

  @override
  Future<int> get exitCode => throw StateError('Process is detached');

  @override
  int get pid => 4242;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => true;
}
