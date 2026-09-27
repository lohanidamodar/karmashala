import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_host/protocol.dart';
import 'package:karmashala_ssh/connection.dart';
import 'package:karmashala_ssh_host/host.dart';

import '../../support/fixtures.dart';

const kBoxBin = '/home/dlohani/.karmashala/bin';
const kBoxThisBundle = 'karmashala_host-1.25.0-linux-x64.d';
const kBoxOlderBundle = 'karmashala_host-1.24.0-linux-x64.d';

String boxExecutable(String bundle) => '$kBoxBin/$bundle/bin/karmashala_host';

final boxHost = SshHost(
  id: 'h1',
  name: 'do-box',
  host: '203.0.113.9',
  port: 22,
  username: 'dlohani',
  authMethod: SshAuthMethod.password,
  createdAt: testTime,
);

/// A machine for the install panel: a shell that lists, stops, starts and
/// deletes, an SFTP side that takes an upload, and a `serve` that answers
/// `hello` only while it runs. No socket, no sshd.
class FakeHostBox implements HostDeployTarget {
  String uname = 'Linux\nx86_64\nldd (GNU libc) 2.39\n';
  final installed = <String>[];
  String? runningServe;
  int heldSessions = 0;

  /// What the tools question answers; empty is a machine with everything.
  String tools = 'uid=1000\n';

  /// Held open by a test that wants to see the spinner.
  Completer<void>? gate;

  final commands = <String>[];
  final uploads = <String>[];

  @override
  String get address => 'dlohani@203.0.113.9:22';

  @override
  Future<RemoteRun> run(String command) async {
    commands.add(command);
    await gate?.future;
    if (command.startsWith('uname')) return RemoteRun(0, uname, '');
    if (command.contains(r'echo "$HOME"')) {
      return const RemoteRun(0, '/home/dlohani\n', '');
    }
    if (command.contains('karmashala-listed')) {
      return RemoteRun(
        0,
        '${installed.map((n) => 'installed=$n\n').join()}karmashala-listed\n',
        '',
      );
    }
    if (command.contains('karmashala-removed')) {
      installed.clear();
      return const RemoteRun(0, 'karmashala-removed\n', '');
    }
    if (command.contains('relay.pid') || command.contains('relay.token')) {
      return const RemoteRun(0, 'args=\ntoken=\nlog=\n', '');
    }
    if (command.startsWith('for t in')) return RemoteRun(0, tools, '');
    if (command.contains('setsid nohup')) {
      runningServe = RegExp(
        r"setsid nohup '([^']+)' serve",
      ).firstMatch(command)!.group(1);
      return const RemoteRun(0, 'started\n', '');
    }
    if (command.contains('kill "\$p"')) {
      runningServe = null;
      return const RemoteRun(0, 'karmashala-stopped\n', '');
    }
    if (command.contains('ps -o args=')) {
      final running = runningServe;
      return RemoteRun(0, running == null ? '' : '$running serve\n', '');
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
    return _Channel(this);
  }
}

class _Channel implements RemoteChannel {
  _Channel(this._box);

  final FakeHostBox _box;
  final _out = StreamController<Uint8List>();
  final _parser = FrameParser();

  @override
  Stream<Uint8List> get stdout => _out.stream;

  @override
  Stream<Uint8List> get stderr => const Stream.empty();

  @override
  void add(Uint8List bytes) {
    // Nothing is listening when no `serve` runs: the hello goes unanswered.
    if (_box.runningServe == null) return;
    for (final frame in _parser.add(bytes)) {
      final message = decodeMessage(frame);
      if (message is HelloMessage) {
        _out.add(
          WelcomeMessage(
            requestId: message.requestId,
            protocolVersion: kProtocolVersion,
            hostVersion: '0.1.0',
            operatingSystem: 'linux',
            architecture: 'x64',
            ptyLibrary: 'libc.so.6',
            pid: 99,
            startedAt: testTime,
            observedAt: testTime,
          ).toFrame().encode(),
        );
      } else if (message is ListMessage) {
        _out.add(
          SessionsMessage(message.requestId, [
            for (var i = 0; i < _box.heldSessions; i++)
              SessionSummary(
                id: 's$i',
                argv: const ['/bin/sh'],
                workingDirectory: null,
                pid: 7,
                columns: 80,
                rows: 24,
                startedAt: testTime,
                observedAt: testTime,
                totalBytes: 0,
                firstAvailableOffset: 0,
                lifecycle: const SessionRunning(),
                writeHolder: null,
              ),
          ]).toFrame().encode(),
        );
      }
    }
  }

  @override
  Future<int> get exitCode async => 0;

  /// Not awaited: closing a cancelled controller answers with a root-zone
  /// future, which a widget test's fake clock never gets to run.
  @override
  Future<void> close() async {
    if (!_out.isClosed) unawaited(_out.close());
  }
}

/// The bundles a build carries. Empty is the macOS app of 2026-09-17.
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
}

/// The real installer over the fake machine: what the panel drives.
HostInstaller installerOver(
  FakeHostBox box, {
  FakeBundles? bundles,
  SshHost? host,
}) => HostInstaller(
  host: host ?? boxHost,
  deployer: HostDeployer(
    target: box,
    binaries: bundles ?? FakeBundles(),
    clock: () => testTime.subtract(const Duration(minutes: 3)),
    helloTimeout: const Duration(milliseconds: 20),
  ),
);

/// Lets a deploy over a [FakeHostBox] finish inside `testWidgets`.
///
/// Not `pumpAndSettle`: the spinner spins. Two clocks, because the deployer
/// needs both — an unanswered `hello` is a 20 ms timer on the test's fake
/// clock, and cancelling a stream subscription answers with a root-zone future
/// that only the real event loop completes.
Future<void> settleHostBox(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1)),
    );
  }
  await tester.pump();
}
