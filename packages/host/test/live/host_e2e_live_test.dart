@Tags(['live-wsl'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:karmashala_host/karmashala_host.dart';
import 'package:test/test.dart';

import 'wsl_harness.dart';

/// The whole host end to end: the cross-compiled binary serving inside WSL with
/// `attach` proxying over stdio, which is what the app does over SSH. Everything
/// counts bytes; the one `Duration` is a failure bound, not a poll.
void main() {
  final unavailable = WslHarness.unavailableReason();

  late WslHarness harness;
  late Process serving;
  const root = '/tmp/karmashala-host-live';

  setUpAll(() async {
    if (unavailable != null) return;
    harness = WslHarness.prepare();
    // Its own HOME, so the test never touches a host a person is using.
    harness.runOrThrow('''
pkill -f karmashala-host-live/.karmashala/bin/karmashala_host || true
rm -rf $root
${harness.installScript('$root/.karmashala')}
printf '%s\\n' '#!/bin/sh' 'unset XDG_RUNTIME_DIR' 'export HOME=$root' \\
  'exec \$HOME/.karmashala/bin/karmashala_host "\$@"' > $root/kh
chmod +x $root/kh
test -x $root/.karmashala/bin/karmashala_host
''');
    serving = await harness.start(['sh', '$root/kh', 'serve']);
    // Started, not slept for: the daemon says where it bound. If it exits
    // first the failure quotes it, because "already running" costs an hour.
    final banner = Completer<String>();
    final said = StringBuffer();
    serving.stdout.transform(utf8.decoder).listen((text) {
      said.write(text);
      if (text.contains('serving on') && !banner.isCompleted) {
        banner.complete(said.toString());
      }
    });
    serving.stderr.transform(utf8.decoder).listen(said.write);
    unawaited(
      serving.exitCode.then((code) {
        if (!banner.isCompleted) {
          banner.completeError(StateError('serve exited $code saying:\n$said'));
        }
      }),
    );
    expect(
      await banner.future.timeout(const Duration(seconds: 90)),
      contains('$root/.karmashala/host.sock'),
    );
  });

  tearDownAll(() async {
    if (unavailable != null) return;
    harness.runSync(
      'pkill -f karmashala-host-live/.karmashala/bin/karmashala_host || true',
    );
    serving.kill();
  });

  test(
    'a session is opened, driven, survives a disconnect and reports its code',
    () async {
      final client = await _AttachClient.start(harness, '$root/kh', 'pane-1');

      final welcome = await client.expectMessage<WelcomeMessage>();
      expect(welcome.protocolVersion, kProtocolVersion);
      expect(welcome.hostVersion, kHostVersion);
      expect(welcome.operatingSystem, 'linux');
      expect(welcome.architecture, 'x64');
      expect(welcome.ptyLibrary, anyOf('libc.so.6', 'libutil.so.1'));

      client.send(
        const OpenMessage(
          requestId: 2,
          sessionId: 'live-a',
          argv: ['/bin/sh'],
          workingDirectory: '/tmp',
          environment: {'TERM': 'dumb', 'PATH': '/usr/bin:/bin', 'PS1': r'$ '},
          columns: 80,
          rows: 24,
        ),
      );
      final attached = await client.expectMessage<AttachedMessage>();
      expect(attached.sessionId, 'live-a');
      expect(attached.holdsWriteToken, isTrue);
      expect(attached.replayFromOffset, 0);
      final ref = attached.sessionRef;

      // Output that differs from the echo, so a match proves the child ran it.
      client.send(InputMessage(ref, _ascii("echo karma''shala\n")));
      await client.untilOutput('karmashala\r\n');
      final seenBeforeDisconnect = client.nextOffset;
      expect(seenBeforeDisconnect, greaterThan(0));
      expect(client.outputOffsetsAreContiguous, isTrue);

      // Disconnect as an SSH channel closing does: our end of the pipe goes away.
      client.send(InputMessage(ref, _ascii("echo while''-away\n")));
      await client.untilOutput('while-away\r\n');
      final seenAll = client.nextOffset;
      await client.hangUp();

      // The session must still be there, and still be the same child.
      final second = await _AttachClient.start(harness, '$root/kh', 'pane-1');
      await second.expectMessage<WelcomeMessage>();
      second.send(const ListMessage(3));
      final listed = await second.expectMessage<SessionsMessage>();
      expect(listed.summaries.map((s) => s.id), contains('live-a'));
      final row = listed.summaries.firstWhere((s) => s.id == 'live-a');
      expect(
        row.lifecycle,
        isA<SessionRunning>(),
        reason: 'a disconnect kills nothing',
      );
      expect(row.writeHolder, isNull, reason: 'and it frees the write token');
      // The pane's offset is what it *rendered*; the host may be ahead, so
      // asserting equality here would be a flake and also untrue of the design.
      expect(row.totalBytes, greaterThanOrEqualTo(seenAll));

      // Reattach from part way back and get exactly the missing bytes.
      second.send(
        AttachMessage(
          requestId: 4,
          sessionId: 'live-a',
          sinceOffset: seenBeforeDisconnect,
          claimWrite: true,
        ),
      );
      final reattached = await second.expectMessage<AttachedMessage>();
      expect(reattached.replayFromOffset, seenBeforeDisconnect);
      expect(reattached.droppedBytes, 0);
      expect(reattached.totalBytes, greaterThanOrEqualTo(seenAll));
      await second.untilOutput('while-away');
      expect(
        second.outputText.contains('karmashala\r\n'),
        isFalse,
        reason:
            'the replay starts at the offset asked for, not at the beginning',
      );
      expect(second.firstOutputOffset, seenBeforeDisconnect);

      // Resize, and let the child report what it sees.
      final ref2 = reattached.sessionRef;
      second.send(ResizeMessage(ref2, 100, 30));
      second.send(InputMessage(ref2, _ascii('stty size\n')));
      await second.untilOutput('30 100');

      // Exit, with a code that could not be a default.
      second.send(InputMessage(ref2, _ascii('exit 7\n')));
      final exited = await second.expectMessage<ExitedMessage>();
      expect(exited.sessionId, 'live-a');
      expect(exited.exitCode, 7);

      await second.hangUp();
    },
    skip: unavailable,
    timeout: const Timeout(Duration(minutes: 4)),
  );

  test(
    'an observer sees output and is refused a write by name',
    () async {
      final driver = await _AttachClient.start(harness, '$root/kh', 'driver');
      await driver.expectMessage<WelcomeMessage>();
      driver.send(
        const OpenMessage(
          requestId: 2,
          sessionId: 'live-b',
          argv: ['/bin/sh'],
          environment: {'TERM': 'dumb', 'PATH': '/usr/bin:/bin'},
          columns: 80,
          rows: 24,
        ),
      );
      final driverRef =
          (await driver.expectMessage<AttachedMessage>()).sessionRef;

      final watcher = await _AttachClient.start(harness, '$root/kh', 'watcher');
      await watcher.expectMessage<WelcomeMessage>();
      watcher.send(
        const AttachMessage(
          requestId: 3,
          sessionId: 'live-b',
          sinceOffset: 0,
          claimWrite: false,
        ),
      );
      final watched = await watcher.expectMessage<AttachedMessage>();
      expect(watched.holdsWriteToken, isFalse);
      expect(watched.writeHolder, 'driver');

      driver.send(InputMessage(driverRef, _ascii("echo shared''-view\n")));
      await watcher.untilOutput('shared-view');

      watcher.send(InputMessage(watched.sessionRef, _ascii("echo not''-me\n")));
      final refusal = await watcher.expectMessage<ErrorMessage>();
      expect(refusal.code, ProtocolErrorCode.writeRefused);
      expect(refusal.message, contains('write token held by driver'));

      driver.send(const CloseMessage(9, 'live-b', signal: 9));
      await driver.expectMessage<ClosedMessage>();
      await driver.hangUp();
      await watcher.hangUp();
    },
    skip: unavailable,
    timeout: const Timeout(Duration(minutes: 4)),
  );

  test(
    'a client speaking the wrong protocol version is refused',
    () async {
      final client = await _AttachClient.start(
        harness,
        '$root/kh',
        'stale',
        greet: false,
      );
      client.send(
        const HelloMessage(
          requestId: 1,
          clientId: 'stale',
          protocolVersion: 9999,
        ),
      );
      final error = await client.expectMessage<ErrorMessage>();
      expect(error.code, ProtocolErrorCode.protocolMismatch);
      expect(error.message, contains('host speaks protocol $kProtocolVersion'));
      await client.hangUp();
    },
    skip: unavailable,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

Uint8List _ascii(String s) => Uint8List.fromList(utf8.encode(s));

/// `karmashala_host attach` as a child process, with the protocol on its pipes.
class _AttachClient {
  _AttachClient(this._process);

  final Process _process;
  final _parser = FrameParser();
  final _pending = <HostMessage>[];
  final _waiters = <_Waiter>[];
  final _output = StringBuffer();
  final _offsets = <(int, int)>[];
  Completer<void>? _outputWaiter;
  String? _outputWanted;

  static Future<_AttachClient> start(
    WslHarness harness,
    String launcher,
    String clientId, {
    bool greet = true,
  }) async {
    final process = await harness.start(['sh', launcher, 'attach']);
    final client = _AttachClient(process);
    process.stdout.listen(client._onBytes);
    process.stderr.listen(
      (bytes) => printOnFailure('attach stderr: ${utf8.decode(bytes)}'),
    );
    if (greet) client.send(HelloMessage(requestId: 1, clientId: clientId));
    return client;
  }

  int get nextOffset =>
      _offsets.isEmpty ? 0 : _offsets.last.$1 + _offsets.last.$2;
  int get firstOutputOffset => _offsets.isEmpty ? -1 : _offsets.first.$1;
  String get outputText => _output.toString();

  bool get outputOffsetsAreContiguous {
    var at = _offsets.isEmpty ? 0 : _offsets.first.$1;
    for (final (offset, length) in _offsets) {
      if (offset != at) return false;
      at = offset + length;
    }
    return true;
  }

  void send(HostMessage message) =>
      _process.stdin.add(message.toFrame().encode());

  void _onBytes(List<int> bytes) {
    for (final frame in _parser.add(bytes)) {
      final message = decodeMessage(frame);
      if (message is OutputMessage) {
        _offsets.add((message.offset, message.bytes.length));
        _output.write(utf8.decode(message.bytes, allowMalformed: true));
        _checkOutput();
        continue;
      }
      _pending.add(message);
      _drain();
    }
  }

  void _drain() {
    _waiters.removeWhere((waiter) {
      final index = _pending.indexWhere(waiter.matches);
      if (index < 0) return false;
      waiter.completer.complete(_pending.removeAt(index));
      return true;
    });
  }

  void _checkOutput() {
    final wanted = _outputWanted;
    final waiter = _outputWaiter;
    if (wanted == null || waiter == null || waiter.isCompleted) return;
    if (_output.toString().contains(wanted)) {
      _outputWanted = null;
      _outputWaiter = null;
      waiter.complete();
    }
  }

  Future<T> expectMessage<T extends HostMessage>({
    Duration within = const Duration(seconds: 30),
  }) {
    final index = _pending.indexWhere((m) => m is T);
    if (index >= 0) return Future.value(_pending.removeAt(index) as T);
    final waiter = _Waiter((m) => m is T);
    _waiters.add(waiter);
    return waiter.completer.future
        .timeout(
          within,
          onTimeout: () => throw StateError('no $T arrived; had $_pending'),
        )
        .then((m) => m as T);
  }

  /// Waits until the child's bytes contain [needle] — counted, never slept for.
  Future<void> untilOutput(
    String needle, {
    Duration within = const Duration(seconds: 30),
  }) {
    if (_output.toString().contains(needle)) return Future.value();
    _outputWanted = needle;
    final waiter = _outputWaiter = Completer<void>();
    return waiter.future.timeout(
      within,
      onTimeout: () => throw StateError('never saw "$needle"; had:\n$_output'),
    );
  }

  /// Closing our end is what an SSH channel closing does. The bound is on
  /// `wsl.exe` relaying the exit, not on `attach`, which answers immediately.
  Future<void> hangUp() async {
    try {
      await _process.stdin.close();
    } on SocketException {
      // Already gone, which is the outcome we wanted.
    }
    await _process.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        _process.kill();
        return -1;
      },
    );
  }
}

class _Waiter {
  _Waiter(this.matches);
  final bool Function(HostMessage) matches;
  final completer = Completer<HostMessage>();
}
