import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/ssh/data/host_deploy_target.dart';
import 'package:karmashala/src/features/ssh/data/ssh_connection.dart';
import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/util/clock.dart';
import 'package:karmashala/src/features/ssh/data/known_host_dao.dart';
import 'package:karmashala/src/features/ssh/data/ssh_host_key_verifier.dart';
import 'package:karmashala/src/features/ssh/domain/host_deployment.dart';
import 'package:karmashala/src/features/ssh/domain/ssh_host.dart';
import 'package:karmashala/src/features/terminal/data/ssh_terminal_instance.dart';
import 'package:karmashala/src/features/terminal/data/terminal_grid_text.dart';
import 'package:xterm2/xterm.dart';
import 'package:karmashala_host/protocol.dart';

/// A target whose exec channel is a host that answers. `run` and `upload` are
/// never reached by the pane — it only ever opens a channel.
class PaneTarget implements HostDeployTarget {
  final channels = <ScriptedHostChannel>[];
  final execs = <String>[];

  @override
  String get address => 'fake.example';

  @override
  Future<RemoteRun> run(String command) async => const RemoteRun(0, '', '');

  @override
  Future<void> upload(String remotePath, Uint8List bytes) async {}

  @override
  Future<RemoteChannel> exec(String command) async {
    execs.add(command);
    final channel = ScriptedHostChannel();
    channels.add(channel);
    return channel;
  }
}

class ScriptedHostChannel implements RemoteChannel {
  final _toApp = StreamController<Uint8List>.broadcast();
  final _parser = FrameParser();
  final received = <HostMessage>[];
  var closed = false;

  @override
  Stream<Uint8List> get stdout => _toApp.stream;

  @override
  Stream<Uint8List> get stderr => const Stream.empty();

  @override
  void add(Uint8List bytes) {
    for (final frame in _parser.add(bytes)) {
      final message = decodeMessage(frame);
      received.add(message);
      switch (message) {
        case HelloMessage(:final requestId):
          _push(
            WelcomeMessage(
              requestId: requestId,
              protocolVersion: kProtocolVersion,
              hostVersion: '0.1.0',
              operatingSystem: 'linux',
              architecture: 'x64',
              ptyLibrary: 'libc.so.6',
              pid: 11,
              startedAt: DateTime.utc(2026),
              observedAt: DateTime.utc(2026),
            ),
          );
        case AttachMessage(:final requestId, :final sessionId):
          // No such session yet — the pane must fall through to `open`.
          _push(
            ErrorMessage(requestId, ProtocolErrorCode.unknownSession, 'no session "$sessionId"'),
          );
        case OpenMessage(:final requestId, :final sessionId):
          _push(
            AttachedMessage(
              requestId: requestId,
              sessionRef: 1,
              sessionId: sessionId,
              columns: 80,
              rows: 24,
              replayFromOffset: 0,
              droppedBytes: 0,
              totalBytes: 0,
              holdsWriteToken: true,
              writeHolder: 'pane-p1',
              observedAt: DateTime.utc(2026),
            ),
          );
        default:
          break;
      }
    }
  }

  void _push(HostMessage message) {
    if (!_toApp.isClosed) _toApp.add(message.toFrame().encode());
  }

  void pushOutput(int offset, String text) =>
      _push(OutputMessage(1, offset, Uint8List.fromList(text.codeUnits)));

  @override
  Future<int> get exitCode async => 0;

  @override
  Future<void> close() async {
    closed = true;
    if (!_toApp.isClosed) await _toApp.close();
  }

  T only<T extends HostMessage>() => received.whereType<T>().single;
}

final _host = SshHost(
  id: 'h1',
  name: 'box',
  host: 'box.example',
  port: 22,
  username: 'me',
  authMethod: SshAuthMethod.password,
  createdAt: DateTime.utc(2026),
);

HostDeployment ready() => HostDeployment(
  status: HostDeploymentStatus.ready,
  observedAt: DateTime.utc(2026, 9, 8, 14, 0),
  reason: 'answering',
  remotePath: r'$HOME/.karmashala/bin/karmashala_host-0.1.0-linux-x64',
  hostVersion: '0.1.0',
  protocolVersion: kProtocolVersion,
);

SshTerminalInstance paneWith({
  HostDeployment? deployment,
  HostDeployTarget? target,
}) => SshTerminalInstance(
  id: 'p1',
  title: 'box',
  profileId: 'default',
  host: _host,
  // Never dialled: every test here takes the host path or the fallback notice,
  // both of which stop before `connection.client()`.
  connection: SshConnection(
    host: _host,
    verifier: SshHostKeyVerifier(
      knownHosts: KnownHostDao(_UnusedDatabase()),
      host: _host.host,
      port: _host.port,
      clock: const SystemClock(),
    ),
  ),
  hostDeployment: deployment,
  hostTarget: target,
);

/// The pane's whole visible buffer as plain text. terminalTailLines reads only
/// the bottom rows on purpose; these assertions are about notices that may have
/// scrolled, so they read all of it.
String screenText(Terminal terminal) => terminalTailLines(terminal, lines: 200).join('\n');

/// Lets the pane's own machinery finish.
///
/// The real delay is for PtyOutputCoalescer's 16 ms watchdog, which is what
/// hands bytes to the terminal when there is no frame pump — a plain `test()`
/// has none. It is a bound on the app's batching, not a poll for a condition.
Future<void> settle() async {
  for (var i = 0; i < 4; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

class _UnusedDatabase implements AppDatabase {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('the pane tests never reach the database');
}

void main() {
  test('a ready host is used, and the pane opens its own session id', () async {
    final target = PaneTarget();
    final pane = paneWith(deployment: ready(), target: target);
    await settle();

    expect(target.execs.single, contains('karmashala_host-0.1.0-linux-x64 attach'));
    final channel = target.channels.single;
    expect(channel.only<HelloMessage>().clientId, 'pane-p1');
    // Attach before open: on a reconnect the session is already there.
    expect(channel.only<AttachMessage>().sessionId, 'karmashala_h1_p1');
    expect(channel.only<OpenMessage>().sessionId, 'karmashala_h1_p1');
    expect(channel.only<OpenMessage>().argv, ['/bin/sh', '-l']);

    pane.dispose();
  });

  test("the child's bytes reach the terminal, sequences and all", () async {
    final target = PaneTarget();
    final pane = paneWith(deployment: ready(), target: target);
    await settle();

    target.channels.single.pushOutput(0, 'hello from the host\r\n');
    await settle();

    expect(nonBlankLineCount(pane.terminal), greaterThan(0));
    expect(screenText(pane.terminal), contains('hello from the host'));
    pane.dispose();
  });

  test('typing goes out as input, not down the tmux channel', () async {
    final target = PaneTarget();
    final pane = paneWith(deployment: ready(), target: target);
    await settle();

    pane.terminal.onOutput!('ls\n');
    await settle();

    expect(
      String.fromCharCodes(target.channels.single.only<InputMessage>().bytes),
      'ls\n',
    );
    pane.dispose();
  });

  test('closing the pane disconnects and never asks the host to close', () async {
    final target = PaneTarget();
    final pane = paneWith(deployment: ready(), target: target);
    await settle();

    pane.dispose();
    await settle();

    expect(target.channels.single.closed, isTrue);
    expect(
      target.channels.single.received.whereType<CloseMessage>(),
      isEmpty,
      reason: 'a closed pane must leave the session running',
    );
  });

  group('falling back', () {
    test('an unsupported machine says so in the pane, in words', () async {
      final target = PaneTarget();
      final pane = paneWith(
        deployment: HostDeployment(
          status: HostDeploymentStatus.unsupportedPlatform,
          observedAt: DateTime.utc(2026),
          reason: 'fake.example runs musl libc.',
        ),
        target: target,
      );
      await settle();

      final text = screenText(pane.terminal);
      expect(text, contains('session host unavailable'));
      expect(text, contains('musl'));
      expect(text, contains('tmux'));
      expect(target.execs, isEmpty, reason: 'nothing is attempted on the host');
      pane.dispose();
    });

    test('a host that cannot be started says which, and still falls back', () async {
      final target = PaneTarget();
      final pane = paneWith(
        deployment: HostDeployment(
          status: HostDeploymentStatus.cannotStart,
          observedAt: DateTime.utc(2026),
          reason: 'the host was installed and started but never answered `hello`.',
        ),
        target: target,
      );
      await settle();

      expect(screenText(pane.terminal), contains('never answered'));
      expect(target.execs, isEmpty);
      pane.dispose();
    });

    test('no reading at all is silent: unknown is not a negative answer', () async {
      final target = PaneTarget();
      final pane = paneWith(target: target);
      await settle();

      expect(screenText(pane.terminal), isNot(contains('session host unavailable')));
      expect(target.execs, isEmpty);
      pane.dispose();
    });
  });

  group('ending', () {
    test('an exit code is shown as itself', () async {
      final target = PaneTarget();
      final pane = paneWith(deployment: ready(), target: target);
      await settle();

      target.channels.single._push(
        ExitedMessage(
          sessionRef: 1,
          sessionId: 'karmashala_h1_p1',
          exitCode: 7,
          reason: 'exited 7',
          observedAt: DateTime.utc(2026),
        ),
      );
      await settle();

      expect(pane.exitCode, 7);
      expect(screenText(pane.terminal), contains('exited with code 7'));
      pane.dispose();
    });

    test('an unknown exit code is never rendered as a zero', () async {
      final target = PaneTarget();
      final pane = paneWith(deployment: ready(), target: target);
      await settle();

      target.channels.single._push(
        ExitedMessage(
          sessionRef: 1,
          sessionId: 'karmashala_h1_p1',
          exitCode: null,
          reason: 'ended, exit code unknown (the child could not be reaped)',
          observedAt: DateTime.utc(2026),
        ),
      );
      await settle();

      expect(pane.exitCode, isNull);
      final text = screenText(pane.terminal);
      expect(text, contains('exit code unknown'));
      expect(text, isNot(contains('exited with code 0')));
      pane.dispose();
    });

    test('a dropped link says the session survives, and where it will resume', () async {
      final target = PaneTarget();
      final pane = paneWith(deployment: ready(), target: target);
      await settle();
      target.channels.single.pushOutput(0, 'abcdef');
      await settle();

      await target.channels.single.close();
      await settle();

      final text = screenText(pane.terminal);
      expect(text, contains('still running there'));
      expect(text, contains('byte 6'));
      pane.dispose();
    });
  });
}
