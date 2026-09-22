import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ssh/host.dart';
import 'package:karmashala_terminal_runtime/host_link.dart';
import 'package:karmashala_host/protocol.dart';

/// A channel with a host behind it, driven by the test. It parses what the app
/// sends with the real codec, so a message the app builds wrongly fails here
/// rather than on a machine.
class ScriptedChannel implements RemoteChannel {
  ScriptedChannel();

  // Broadcast so closing it is safe after the link has cancelled its listener.
  final _toApp = StreamController<Uint8List>.broadcast();
  final _parser = FrameParser();
  final sent = <HostMessage>[];
  var closed = false;

  /// What the host answers. Return null to say nothing.
  HostMessage? Function(HostMessage request)? answer;

  @override
  Stream<Uint8List> get stdout => _toApp.stream;

  @override
  Stream<Uint8List> get stderr => const Stream.empty();

  @override
  void add(Uint8List bytes) {
    for (final frame in _parser.add(bytes)) {
      final message = decodeMessage(frame);
      sent.add(message);
      final reply = answer?.call(message);
      if (reply != null) push(reply);
    }
  }

  void push(HostMessage message) {
    if (!_toApp.isClosed) _toApp.add(message.toFrame().encode());
  }

  void pushRaw(Uint8List bytes) {
    if (!_toApp.isClosed) _toApp.add(bytes);
  }

  Future<void> drop() async {
    if (!_toApp.isClosed) await _toApp.close();
  }

  @override
  Future<int> get exitCode async => 0;

  @override
  Future<void> close() async {
    closed = true;
    await drop();
  }

  T only<T extends HostMessage>() => sent.whereType<T>().single;
  Iterable<T> all<T extends HostMessage>() => sent.whereType<T>();
}

final _welcome = WelcomeMessage(
  requestId: 1,
  protocolVersion: kProtocolVersion,
  hostVersion: '0.1.0',
  operatingSystem: 'linux',
  architecture: 'x64',
  ptyLibrary: 'libc.so.6',
  pid: 7,
  startedAt: DateTime.utc(2026),
  observedAt: DateTime.utc(2026),
);

AttachedMessage attachedWith({
  int requestId = 2,
  int replayFrom = 0,
  int dropped = 0,
  int total = 0,
  bool holds = true,
  String? holder = 'pane-p1',
}) => AttachedMessage(
  requestId: requestId,
  sessionRef: 4,
  sessionId: 'karmashala_h1_p1',
  columns: 80,
  rows: 24,
  replayFromOffset: replayFrom,
  droppedBytes: dropped,
  totalBytes: total,
  holdsWriteToken: holds,
  writeHolder: holder,
  observedAt: DateTime.utc(2026),
);

/// Answers hello with a welcome and everything else with an attachment.
HostMessage? _greetAndAttach(HostMessage request) => switch (request) {
  HelloMessage(:final requestId) => WelcomeMessage(
    requestId: requestId,
    protocolVersion: _welcome.protocolVersion,
    hostVersion: _welcome.hostVersion,
    operatingSystem: _welcome.operatingSystem,
    architecture: _welcome.architecture,
    ptyLibrary: _welcome.ptyLibrary,
    pid: _welcome.pid,
    startedAt: _welcome.startedAt,
    observedAt: _welcome.observedAt,
  ),
  OpenMessage(:final requestId) => attachedWith(requestId: requestId),
  AttachMessage(:final requestId, :final sinceOffset) => attachedWith(
    requestId: requestId,
    replayFrom: sinceOffset,
  ),
  _ => null,
};

Future<HostPaneLink> connected(ScriptedChannel channel) {
  channel.answer ??= _greetAndAttach;
  return HostPaneLink.open(channel, clientId: 'pane-p1');
}

Uint8List ascii(String s) => Uint8List.fromList(s.codeUnits);

void main() {
  group('opening the link', () {
    test('says hello and keeps what the host answered', () async {
      final channel = ScriptedChannel();
      final link = await connected(channel);

      expect(channel.only<HelloMessage>().clientId, 'pane-p1');
      expect(channel.only<HelloMessage>().protocolVersion, kProtocolVersion);
      expect(link.welcome!.hostVersion, '0.1.0');
      expect(link.welcome!.ptyLibrary, 'libc.so.6');
    });

    test('refuses a host speaking another protocol, and closes', () async {
      final channel = ScriptedChannel()
        ..answer = ((request) => WelcomeMessage(
          requestId: (request as HelloMessage).requestId,
          protocolVersion: 99,
          hostVersion: '9.9.9',
          operatingSystem: 'linux',
          architecture: 'x64',
          ptyLibrary: 'libc.so.6',
          pid: 1,
          startedAt: DateTime.utc(2026),
          observedAt: DateTime.utc(2026),
        ));

      await expectLater(
        HostPaneLink.open(channel, clientId: 'pane-p1'),
        throwsA(isA<HostLinkException>()),
      );
      expect(channel.closed, isTrue);
    });

    test(
      'a host that never answers gives up with a reason, not a hang',
      () async {
        final channel = ScriptedChannel()..answer = ((_) => null);
        await expectLater(
          HostPaneLink.open(
            channel,
            clientId: 'pane-p1',
            bound: const Duration(milliseconds: 30),
          ),
          throwsA(
            isA<HostLinkException>().having(
              (e) => e.message,
              'message',
              contains('did not answer'),
            ),
          ),
        );
      },
    );
  });

  group('refusals', () {
    test(
      'a refusal carries the host\'s code, so callers can tell them apart',
      () async {
        final channel = ScriptedChannel()
          ..answer = ((request) => switch (request) {
            HelloMessage() => _welcome,
            AttachMessage(:final requestId) => ErrorMessage(
              requestId,
              ProtocolErrorCode.unknownSession,
              'no session',
            ),
            _ => null,
          });
        final link = await HostPaneLink.open(channel, clientId: 'pane-p1');
        await expectLater(
          link.attachSession(sessionId: 's1', sinceOffset: 0),
          throwsA(
            isA<HostLinkException>()
                .having((e) => e.code, 'code', ProtocolErrorCode.unknownSession)
                .having((e) => e.timedOut, 'timedOut', isFalse),
          ),
        );
      },
    );
  });

  group('unreadable messages', () {
    test(
      'a frame that cannot be decoded fails the link with words, not a stall',
      () async {
        final channel = ScriptedChannel()
          ..answer = ((request) => request is HelloMessage ? _welcome : null);
        final link = await HostPaneLink.open(channel, clientId: 'pane-p1');
        // In flight when the bad frame lands: it must be answered, not left to its bound.
        final attaching = link.attachSession(sessionId: 's1', sinceOffset: 0);
        channel.pushRaw(
          Frame(
            MessageType.welcome,
            0,
            Uint8List.fromList([0x7b, 0x01, 0x02]),
          ).encode(),
        );
        await expectLater(
          attaching,
          throwsA(
            isA<HostLinkException>().having(
              (e) => e.message,
              'message',
              contains('unreadable'),
            ),
          ),
        );
      },
    );
  });

  group('output and offsets', () {
    test('bytes arrive untouched and the offset follows them', () async {
      final channel = ScriptedChannel();
      final link = await connected(channel);
      await link.openSession(
        sessionId: 's',
        argv: const ['/bin/sh'],
        columns: 80,
        rows: 24,
      );
      final seen = <int>[];
      link.output.listen(seen.addAll);

      // An OSC 133 prompt mark: the exact sequence tmux drops.
      final mark = ascii('\x1b]133;A\x07ok');
      channel.push(OutputMessage(4, 0, mark));
      await Future<void>.delayed(Duration.zero);

      expect(seen, mark);
      expect(link.lastOffset, mark.length);
    });

    test('the offset is where the next attach asks from', () async {
      final channel = ScriptedChannel();
      final link = await connected(channel);
      await link.openSession(
        sessionId: 's',
        argv: const ['/bin/sh'],
        columns: 80,
        rows: 24,
      );
      link.output.listen((_) {});

      channel.push(OutputMessage(4, 0, ascii('abcde')));
      channel.push(OutputMessage(4, 5, ascii('fgh')));
      await Future<void>.delayed(Duration.zero);

      expect(link.lastOffset, 8);
    });

    test('a reattach asks from the offset it is given', () async {
      final channel = ScriptedChannel();
      final link = await connected(channel);
      await link.attachSession(
        sessionId: 'karmashala_h1_p1',
        sinceOffset: 4096,
      );

      expect(channel.only<AttachMessage>().sinceOffset, 4096);
      expect(channel.only<AttachMessage>().claimWrite, isTrue);
      expect(link.lastOffset, 4096, reason: 'resuming, not restarting');
    });
  });

  group('what the pane is told', () {
    test('a gap in the backlog is announced, not papered over', () async {
      final channel = ScriptedChannel()
        ..answer = ((request) => request is HelloMessage
            ? _greetAndAttach(request)
            : attachedWith(
                requestId: 2,
                replayFrom: 900,
                dropped: 900,
                total: 5000,
              ));
      final link = await connected(channel);
      final notices = <String>[];
      link.notices.listen(notices.add);

      final attachment = await link.attachSession(
        sessionId: 's',
        sinceOffset: 0,
      );
      await Future<void>.delayed(Duration.zero);

      expect(attachment.droppedBytes, 900);
      expect(notices.single, contains('900 bytes'));
      expect(notices.single, contains('discarded'));
    });

    test('a read-only attach names who is driving', () async {
      final channel = ScriptedChannel()
        ..answer = ((request) => request is HelloMessage
            ? _greetAndAttach(request)
            : attachedWith(requestId: 2, holds: false, holder: 'pane-other'));
      final link = await connected(channel);
      final notices = <String>[];
      link.notices.listen(notices.add);

      final attachment = await link.attachSession(
        sessionId: 's',
        sinceOffset: 0,
      );
      await Future<void>.delayed(Duration.zero);

      expect(attachment.holdsWriteToken, isFalse);
      expect(notices.single, contains('pane-other is driving'));
    });

    test(
      'an unsolicited refusal becomes a notice, not a dropped frame',
      () async {
        final channel = ScriptedChannel();
        final link = await connected(channel);
        await link.attachSession(sessionId: 's', sinceOffset: 0);
        final notices = <String>[];
        link.notices.listen(notices.add);

        channel.push(
          const ErrorMessage(
            0,
            ProtocolErrorCode.writeRefused,
            'write token held by pane-2',
          ),
        );
        await Future<void>.delayed(Duration.zero);

        expect(notices.single, 'write token held by pane-2');
      },
    );
  });

  group('driving the session', () {
    test(
      'input and resize carry the session ref the host handed out',
      () async {
        final channel = ScriptedChannel();
        final link = await connected(channel);
        await link.attachSession(sessionId: 's', sinceOffset: 0);

        link.write(ascii('ls\n'));
        link.resize(132, 43);

        expect(channel.only<InputMessage>().sessionRef, 4);
        expect(channel.only<InputMessage>().bytes, ascii('ls\n'));
        expect(channel.only<ResizeMessage>().columns, 132);
        expect(channel.only<ResizeMessage>().rows, 43);
      },
    );

    test(
      'a resize before the host has named the session is not sent',
      () async {
        // It could only carry ref 0, which the host answers with an error; the
        // pane says its size once the attach has told it what the host holds.
        final channel = ScriptedChannel();
        final link = await connected(channel);

        link.resize(132, 43);
        expect(channel.all<ResizeMessage>(), isEmpty);

        final attachment = await link.attachSession(
          sessionId: 's',
          sinceOffset: 0,
        );
        link.matchGrid(attachment, 132, 43);
        expect(channel.only<ResizeMessage>().sessionRef, 4);
        expect(channel.only<ResizeMessage>().columns, 132);
      },
    );

    test('a session already at the size of the pane is left alone', () async {
      final channel = ScriptedChannel();
      final link = await connected(channel);
      final attachment = await link.attachSession(
        sessionId: 's',
        sinceOffset: 0,
      );

      link.matchGrid(attachment, attachment.columns, attachment.rows);
      expect(channel.all<ResizeMessage>(), isEmpty);
    });

    test('an empty write costs no frame', () async {
      final channel = ScriptedChannel();
      final link = await connected(channel);
      await link.attachSession(sessionId: 's', sinceOffset: 0);
      link.write(Uint8List(0));
      expect(channel.all<InputMessage>(), isEmpty);
    });

    test('open sends the whole spawn request', () async {
      final channel = ScriptedChannel();
      final link = await connected(channel);
      await link.openSession(
        sessionId: 'karmashala_h1_p1',
        argv: const ['/usr/bin/claude', '--resume'],
        workingDirectory: '/srv/app',
        environment: const {'TERM': 'xterm-256color'},
        columns: 120,
        rows: 40,
      );

      final open = channel.only<OpenMessage>();
      expect(open.sessionId, 'karmashala_h1_p1');
      expect(open.argv, ['/usr/bin/claude', '--resume']);
      expect(open.workingDirectory, '/srv/app');
      expect(open.environment['TERM'], 'xterm-256color');
      expect(open.columns, 120);
      expect(open.removedEnvironment, isEmpty);
    });

    test('open carries the names the child must not inherit', () async {
      final channel = ScriptedChannel();
      final link = await connected(channel);
      await link.openSession(
        sessionId: 's',
        argv: const ['claude.exe'],
        removedEnvironment: const {'ANTHROPIC_API_KEY'},
        columns: 80,
        rows: 24,
      );
      expect(channel.only<OpenMessage>().removedEnvironment, {
        'ANTHROPIC_API_KEY',
      });
    });

    test(
      'a host that cannot read the open fails it with its own words',
      () async {
        final channel = ScriptedChannel();
        final link = await connected(channel);
        // What an older host does with a frame type it predates: id 0,
        // `badRequest`, and it hangs up.
        channel.answer = (request) {
          if (request is OpenMessage) {
            channel.push(
              const ErrorMessage(
                0,
                ProtocolErrorCode.badRequest,
                'unknown message type 0x14',
              ),
            );
            unawaited(channel.drop());
          }
          return null;
        };

        await expectLater(
          link.openSession(
            sessionId: 's',
            argv: const ['claude.exe'],
            removedEnvironment: const {'ANTHROPIC_API_KEY'},
            columns: 80,
            rows: 24,
          ),
          throwsA(
            isA<HostLinkException>()
                .having((e) => e.code, 'code', ProtocolErrorCode.badRequest)
                .having((e) => e.message, 'message', contains('0x14')),
          ),
        );
      },
    );
  });

  group('ending', () {
    test('an exit code is reported as itself', () async {
      final channel = ScriptedChannel();
      final link = await connected(channel);
      await link.attachSession(sessionId: 's', sinceOffset: 0);

      channel.push(
        ExitedMessage(
          sessionRef: 4,
          sessionId: 's',
          exitCode: 7,
          reason: 'exited 7',
          observedAt: DateTime.utc(2026),
        ),
      );

      expect((await link.ended).exitCode, 7);
    });

    test(
      'an unknown exit code stays unknown all the way to the pane',
      () async {
        final channel = ScriptedChannel();
        final link = await connected(channel);
        await link.attachSession(sessionId: 's', sinceOffset: 0);

        channel.push(
          ExitedMessage(
            sessionRef: 4,
            sessionId: 's',
            exitCode: null,
            reason: 'ended, exit code unknown (the child could not be reaped)',
            observedAt: DateTime.utc(2026),
          ),
        );

        final end = await link.ended;
        expect(end.exitCode, isNull);
        expect(end.reason, contains('unknown'));
      },
    );

    test(
      'a dropped channel closes the output and keeps the last offset',
      () async {
        final channel = ScriptedChannel();
        final link = await connected(channel);
        await link.attachSession(sessionId: 's', sinceOffset: 100);
        final done = Completer<void>();
        link.output.listen((_) {}, onDone: done.complete);

        channel.push(OutputMessage(4, 100, ascii('xyz')));
        await Future<void>.delayed(Duration.zero);
        await channel.drop();
        await done.future;

        expect(
          link.lastOffset,
          103,
          reason: 'the pane resumes from exactly here',
        );
      },
    );

    test(
      'closing the link is a disconnect: it closes the channel and nothing else',
      () async {
        final channel = ScriptedChannel();
        final link = await connected(channel);
        await link.attachSession(sessionId: 's', sinceOffset: 0);

        await link.close();

        expect(channel.closed, isTrue);
        expect(
          channel.all<CloseMessage>(),
          isEmpty,
          reason: 'a pane going away must never end the session',
        );
      },
    );
  });
}
