import 'dart:async';
import 'dart:typed_data';

import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_ssh_host/host.dart';

import '../../serve/pipe_connection.dart';

final boxTime = DateTime.utc(2026, 9, 27, 12);

/// **An SSH box with no sshd** (slice 5d), in this process: a scripted shell
/// that answers the deployer's commands the way a glibc Linux box does, an
/// SFTP side that takes an upload, and — behind `<path> attach` — a real
/// Karmashala host (`HostServer` over its own `SessionRegistry` and fake
/// PTYs), so a link, a relay and a box's sessions run for real.
class FakeBox implements HostDeployTarget {
  FakeBox({this.uname = 'Linux\nx86_64\nldd (GNU libc) 2.39\n'}) {
    registry = SessionRegistry(launcher: launcher, clock: () => boxTime);
    host = HostServer(
      registry: registry,
      ptyLibrary: 'libc.so.6',
      clock: () => boxTime,
    );
  }

  /// What `uname -s; uname -m; ldd --version` answers.
  String uname;

  /// The box user's login shell (`$SHELL`).
  String shell = '/bin/bash';

  /// Whether the host answers `attach` at all; a box whose `serve` is not up
  /// is silent until it is started.
  var serving = true;

  final launcher = FakePtyLauncher();
  late final SessionRegistry registry;
  late final HostServer host;

  final commands = <String>[];
  final uploads = <String>[];
  final installed = <String>[];
  final _channels = <_Channel>[];

  @override
  String get address => 'dev@203.0.113.9:22';

  /// Every PTY the box's host started, in order.
  List<FakePtyHandle> get ptys => launcher.handles;

  @override
  Future<RemoteRun> run(String command) async {
    commands.add(command);
    if (command.startsWith('uname')) return RemoteRun(0, uname, '');
    if (command.contains(r'echo "$HOME"')) {
      return const RemoteRun(0, '/home/dev\n', '');
    }
    if (command.contains('karmashala-shell:')) {
      return RemoteRun(0, 'karmashala-shell:$shell\n', '');
    }
    if (command.contains('karmashala-listed')) {
      return RemoteRun(
        0,
        '${installed.map((n) => 'installed=$n\n').join()}karmashala-listed\n',
        '',
      );
    }
    if (command.contains('relay.pid') || command.contains('relay.token')) {
      return const RemoteRun(0, 'args=\ntoken=\nlog=\n', '');
    }
    if (command.startsWith('for t in')) {
      return const RemoteRun(0, 'uid=1000\n', '');
    }
    if (command.contains('setsid nohup')) {
      serving = true;
      return const RemoteRun(0, 'started\n', '');
    }
    if (command.contains('kill "\$p"')) {
      serving = false;
      return const RemoteRun(0, 'karmashala-stopped\n', '');
    }
    if (command.contains('wc -c <')) return const RemoteRun(0, 'missing\n', '');
    return const RemoteRun(0, '', '');
  }

  @override
  Future<void> upload(String remotePath, Uint8List bytes) async {
    uploads.add(remotePath);
    final name = remotePath.split('/').last;
    final entry = name.endsWith('.tar.gz')
        ? '${name.substring(0, name.length - 7)}.d'
        : name;
    if (!installed.contains(entry)) installed.add(entry);
  }

  @override
  Future<RemoteChannel> exec(String command) async {
    commands.add(command);
    final (client, served) = PipeEnd.pair();
    if (serving) unawaited(host.serveConnection(served));
    final channel = _Channel(client);
    _channels.add(channel);
    return channel;
  }

  /// The SSH connection drops: every channel to the box closes; the box's
  /// host keeps its sessions.
  Future<void> dropLinks() async {
    for (final channel in _channels.toList()) {
      await channel.close();
    }
    _channels.clear();
  }

  Future<void> close() async {
    await dropLinks();
    // A fake PTY never exits by itself: each is ended, so shutting the host
    // down waits on nothing.
    for (final pty in launcher.handles) {
      pty.finish(0);
    }
    await registry.shutdown();
  }
}

class _Channel implements RemoteChannel {
  _Channel(this._end);

  final PipeEnd _end;

  @override
  Stream<Uint8List> get stdout => _end.incoming;

  @override
  Stream<Uint8List> get stderr => const Stream.empty();

  @override
  void add(Uint8List bytes) {
    try {
      _end.add(bytes);
    } on StateError {
      // The box end went away; the link reads its close.
    }
  }

  @override
  Future<int> get exitCode async {
    await _end.done;
    return 0;
  }

  @override
  Future<void> close() => _end.close();
}

/// The bundles a server has. Empty is a server with none for any box.
class FakeBundles implements HostBinarySource {
  FakeBundles([this.targets = const ['linux-x64']]);

  final List<String> targets;

  @override
  Future<HostBinary?> binaryFor(HostPlatform platform) async =>
      !targets.contains(platform.targetKey)
      ? null
      : HostBinary(
          length: 2048,
          readBytes: () async => Uint8List(2048),
          version: '1.25.0',
          isBundleArchive: true,
          source: 'fake/karmashala_host-1.25.0-${platform.targetKey}.tar.gz',
        );

  @override
  Future<List<String>> availableTargets() async => [...targets]..sort();

  @override
  String describeSearch() => '/srv/karmashala/host-bundles';
}
