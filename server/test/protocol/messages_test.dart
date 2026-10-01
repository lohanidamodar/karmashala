import 'dart:typed_data';

import 'package:karmashala_host/karmashala_host.dart';
import 'package:test/test.dart';

T roundTrip<T extends HostMessage>(T message) {
  final frames = FrameParser().add(message.toFrame().encode());
  expect(
    frames,
    hasLength(1),
    reason: 'a message must encode to exactly one frame',
  );
  return decodeMessage(frames.single) as T;
}

void main() {
  final t0 = DateTime.utc(2026, 9, 8, 14, 0, 30);

  test('the protocol version is pinned; changing it is a deliberate act', () {
    expect(kProtocolVersion, 31);
  });

  test('protocol 28 retired the forwarded agent tools: 0x1d–0x1f are no '
      'frame any more, and the data streams and stop frames stay', () {
    // mcpTools, mcpCall, mcpResult (slice 5b): the server runs every tool.
    for (final code in [0x1d, 0x1e, 0x1f]) {
      expect(
        MessageType.fromCode(code),
        isNull,
        reason: '0x${code.toRadixString(16)}',
      );
      expect(
        () =>
            FrameParser().add(Uint8List.fromList([code, 0, 0, 0, 0, 0, 0, 0])),
        throwsA(isA<FrameFormatException>()),
      );
    }
    expect(MessageType.dataStreamOpen.code, 0x3b);
    expect(MessageType.dataStreamItems.code, 0x3c);
    expect(MessageType.dataStreamClose.code, 0x3d);
    // 0x3e and 0x3f are 5e's outputAck and presence; 0x40 is 5d's detach.
    expect(MessageType.outputAck.code, 0x3e);
    expect(MessageType.presence.code, 0x3f);
    expect(MessageType.detach.code, 0x40);
    expect(MessageType.stopCheck.code, 0xf0);
    expect(MessageType.stopCheckAnswer.code, 0xf1);
  });

  test('protocol 27 retired the forwarded companion calls, the automations '
      'frames and the pane facts, and 29 the companion attach: their codes '
      'are no frame any more', () {
    // 0x20 companion attach (the LAN relay is the server's, protocol 29);
    // 0x21–0x22 companion call/result; 0x25, 0x27–0x2a automations and
    // checks; 0x36–0x37 pane facts (slice 5c).
    for (final code in [
      0x20, 0x21, 0x22, 0x25, 0x27, 0x28, 0x29, 0x2a, 0x36, 0x37, //
    ]) {
      expect(
        MessageType.fromCode(code),
        isNull,
        reason: '0x${code.toRadixString(16)}',
      );
      expect(
        () =>
            FrameParser().add(Uint8List.fromList([code, 0, 0, 0, 0, 0, 0, 0])),
        throwsA(isA<FrameFormatException>()),
      );
    }
    // What stays: the pairing dialog closing, a pairing window ending — and
    // the frozen stop frames.
    expect(MessageType.companionNotice.code, 0x23);
    expect(MessageType.companionEvent.code, 0x24);
    expect(MessageType.stopCheck.code, 0xf0);
    expect(MessageType.stopCheckAnswer.code, 0xf1);
    final notice = roundTrip(
      const CompanionNoticeMessage(CompanionNoticeKind.pairingCancelled),
    );
    expect(notice.kind, CompanionNoticeKind.pairingCancelled);
  });

  group('client to host', () {
    test('hello carries the version it speaks and who is speaking', () {
      final decoded = roundTrip(
        const HelloMessage(requestId: 9, clientId: 'pane-1'),
      );
      expect(decoded.requestId, 9);
      expect(decoded.clientId, 'pane-1');
      expect(decoded.protocolVersion, kProtocolVersion);
    });

    test('a mismatched version survives decoding so it can be refused', () {
      final decoded = roundTrip(
        const HelloMessage(requestId: 1, clientId: 'x', protocolVersion: 99),
      );
      expect(decoded.protocolVersion, 99);
    });

    test('open carries the whole spawn request, cwd and env included', () {
      final decoded = roundTrip(
        const OpenMessage(
          requestId: 4,
          sessionId: 'pane-a',
          argv: ['/bin/sh', '-lc', 'echo hi'],
          workingDirectory: '/srv/app',
          environment: {'TERM': 'xterm-256color', 'LANG': 'en_US.UTF-8'},
          columns: 132,
          rows: 43,
        ),
      );
      expect(decoded.sessionId, 'pane-a');
      expect(decoded.argv, ['/bin/sh', '-lc', 'echo hi']);
      expect(decoded.workingDirectory, '/srv/app');
      expect(decoded.environment['LANG'], 'en_US.UTF-8');
      expect(decoded.columns, 132);
      expect(decoded.rows, 43);
    });

    test(
      'an absent working directory decodes as absent, not as an empty path',
      () {
        final decoded = roundTrip(
          const OpenMessage(
            requestId: 1,
            sessionId: 's',
            argv: ['/bin/sh'],
            environment: {},
            columns: 80,
            rows: 24,
          ),
        );
        expect(decoded.workingDirectory, isNull);
      },
    );

    test('open carries the names to withhold, as its own frame type', () {
      const open = OpenMessage(
        requestId: 3,
        sessionId: 'karmashala_s1',
        argv: ['claude.exe'],
        environment: {'TERM': 'xterm-256color'},
        removedEnvironment: {'ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN'},
        columns: 100,
        rows: 30,
      );
      expect(open.toFrame().type, MessageType.openWithout);
      final decoded = roundTrip(open);
      expect(decoded.removedEnvironment, {
        'ANTHROPIC_API_KEY',
        'ANTHROPIC_AUTH_TOKEN',
      });
      expect(decoded.environment, {'TERM': 'xterm-256color'});
      expect(decoded.columns, 100);
      expect(decoded.rows, 30);
    });

    test('an open with nothing to withhold is the frame every host reads', () {
      const open = OpenMessage(
        requestId: 3,
        sessionId: 's',
        argv: ['sh'],
        environment: {},
        columns: 80,
        rows: 24,
      );
      expect(open.toFrame().type, MessageType.open);
      expect(roundTrip(open).removedEnvironment, isEmpty);
    });

    test(
      'a withholding open cannot be read as a plain one by an older host',
      () {
        final frame = const OpenMessage(
          requestId: 3,
          sessionId: 's',
          argv: ['sh'],
          environment: {},
          removedEnvironment: {'ANTHROPIC_API_KEY'},
          columns: 80,
          rows: 24,
        ).toFrame();
        // What an older host reads for `open`: every field it knows, then it
        // stops. A trailing field would have been dropped without a word,
        // which is why the removals ride a type it does not know instead.
        final r = WireReader(frame.payload)
          ..u32()
          ..str()
          ..strings()
          ..str()
          ..map()
          ..u16()
          ..u16();
        expect(r.remaining, greaterThan(0));
        expect(frame.type.code, isNot(MessageType.open.code));
        expect(frame.type.code, 0x14);
      },
    );

    test('attach carries the exact offset the pane last rendered', () {
      final decoded = roundTrip(
        const AttachMessage(
          requestId: 2,
          sessionId: 'pane-a',
          sinceOffset: 9007199254740000,
          claimWrite: false,
        ),
      );
      expect(decoded.sinceOffset, 9007199254740000);
      expect(decoded.claimWrite, isFalse);
    });

    test('input is raw bytes with no framing tax beyond the header', () {
      final payload = Uint8List.fromList([0x1b, 0x5b, 0x41, 0x00, 0xff]);
      final message = InputMessage(3, payload);
      expect(
        message.toFrame().encode(),
        hasLength(Frame.headerBytes + payload.length),
      );
      expect(roundTrip(message).bytes, payload);
    });

    test('resize and claim and release ride on the session ref', () {
      expect(roundTrip(const ResizeMessage(5, 100, 30)).sessionRef, 5);
      expect(roundTrip(const ResizeMessage(5, 100, 30)).columns, 100);
      expect(roundTrip(const ClaimMessage(7, 5)).requestId, 7);
      expect(roundTrip(const ReleaseMessage(7, 5)).sessionRef, 5);
    });

    test('close names the session and the signal', () {
      final decoded = roundTrip(const CloseMessage(1, 'pane-a', signal: 9));
      expect(decoded.sessionId, 'pane-a');
      expect(decoded.signal, 9);
    });
  });

  group('host to client', () {
    WelcomeMessage welcome({String? build}) => WelcomeMessage(
      requestId: 1,
      protocolVersion: kProtocolVersion,
      hostVersion: kHostVersion,
      operatingSystem: 'windows',
      architecture: 'x64',
      ptyLibrary: 'kernel32',
      pid: 4,
      startedAt: t0,
      observedAt: t0,
      build: build,
    );

    test('welcome carries the build the host runs', () {
      expect(
        roundTrip(welcome(build: '8605696-1790000000000')).build,
        '8605696-1790000000000',
      );
    });

    test('a welcome from a host that predates builds reads as no build', () {
      // What an older host sends: every field up to `observedAt`, then nothing
      // — neither the build ('x', length-prefixed) nor the features after it
      // (an empty list, its count alone).
      final full = welcome(build: 'x').toFrame().payload;
      final older = Frame(
        MessageType.welcome,
        0,
        Uint8List.sublistView(full, 0, full.length - (4 + 1) - 4),
      );
      final decoded = WelcomeMessage.decode(older);
      expect(decoded.build, isNull);
      expect(decoded.features, isEmpty);
      expect(decoded.hostVersion, kHostVersion);
    });

    test('an older app reading a newer welcome stops before the build', () {
      final r = WireReader(welcome(build: 'b').toFrame().payload)
        ..u32()
        ..u32()
        ..str()
        ..str()
        ..str()
        ..str()
        ..u32()
        ..u64()
        ..u64();
      // No released decoder calls `expectEnd`, so these are left unread.
      expect(r.remaining, greaterThan(0));
    });

    test(
      'welcome reports what the host measured about itself, with an age',
      () {
        final decoded = roundTrip(
          WelcomeMessage(
            requestId: 1,
            protocolVersion: kProtocolVersion,
            hostVersion: '0.1.0',
            operatingSystem: 'linux',
            architecture: 'x64',
            ptyLibrary: 'libc.so.6',
            pid: 4242,
            startedAt: t0.subtract(const Duration(hours: 2)),
            observedAt: t0,
          ),
        );
        expect(decoded.hostVersion, '0.1.0');
        expect(decoded.ptyLibrary, 'libc.so.6');
        expect(decoded.architecture, 'x64');
        expect(decoded.observedAt, t0);
        expect(decoded.startedAt, t0.subtract(const Duration(hours: 2)));
      },
    );

    test('output is an offset and then the bytes, untouched', () {
      final bytes = Uint8List.fromList([
        0x1b,
        0x5d,
        0x31,
        0x33,
        0x33,
        0x3b,
        0x41,
        0x07,
      ]);
      final decoded = roundTrip(OutputMessage(2, 4096, bytes));
      expect(decoded.offset, 4096);
      expect(
        decoded.bytes,
        bytes,
        reason: 'OSC 133 must survive byte for byte',
      );
      expect(decoded.nextOffset, 4096 + bytes.length);
    });

    test('attached says where the replay really starts and what was lost', () {
      final decoded = roundTrip(
        AttachedMessage(
          requestId: 3,
          sessionRef: 1,
          sessionId: 'pane-a',
          columns: 80,
          rows: 24,
          replayFromOffset: 1000,
          droppedBytes: 400,
          totalBytes: 5000,
          holdsWriteToken: false,
          writeHolder: 'pane-b',
          observedAt: t0,
        ),
      );
      expect(decoded.replayFromOffset, 1000);
      expect(decoded.droppedBytes, 400);
      expect(decoded.writeHolder, 'pane-b');
      expect(decoded.holdsWriteToken, isFalse);
    });

    test('an unheld token decodes as no holder, not as an empty name', () {
      final decoded = roundTrip(
        AttachedMessage(
          requestId: 1,
          sessionRef: 1,
          sessionId: 's',
          columns: 80,
          rows: 24,
          replayFromOffset: 0,
          droppedBytes: 0,
          totalBytes: 0,
          holdsWriteToken: true,
          writeHolder: null,
          observedAt: t0,
        ),
      );
      expect(decoded.writeHolder, isNull);
    });

    test('an unknown exit code stays unknown across the wire, never zero', () {
      final decoded = roundTrip(
        ExitedMessage(
          sessionRef: 1,
          sessionId: 'pane-a',
          exitCode: null,
          reason: 'ended, exit code unknown (the child could not be reaped)',
          observedAt: t0,
        ),
      );
      expect(decoded.exitCode, isNull);
      expect(decoded.reason, contains('unknown'));
    });

    test('a real exit code survives, including a signalled one', () {
      expect(
        roundTrip(
          ExitedMessage(
            sessionRef: 1,
            sessionId: 'a',
            exitCode: 130,
            reason: 'exited 130',
            observedAt: t0,
          ),
        ).exitCode,
        130,
      );
      expect(
        roundTrip(
          ExitedMessage(
            sessionRef: 1,
            sessionId: 'a',
            exitCode: 0,
            reason: 'exited 0',
            observedAt: t0,
          ),
        ).exitCode,
        0,
      );
    });

    test('a session list round-trips every lifecycle shape', () {
      final decoded = roundTrip(
        SessionsMessage(1, [
          SessionSummary(
            id: 'running',
            argv: ['/bin/sh'],
            workingDirectory: '/srv',
            pid: 10,
            columns: 80,
            rows: 24,
            startedAt: t0,
            observedAt: t0,
            totalBytes: 12,
            firstAvailableOffset: 0,
            lifecycle: const SessionRunning(),
            writeHolder: 'pane-1',
          ),
          SessionSummary(
            id: 'exited',
            argv: ['/bin/false'],
            workingDirectory: null,
            pid: 11,
            columns: 80,
            rows: 24,
            startedAt: t0,
            observedAt: t0,
            totalBytes: 0,
            firstAvailableOffset: 0,
            lifecycle: SessionExited(1, t0),
            writeHolder: null,
          ),
          SessionSummary(
            id: 'unknown',
            argv: ['/bin/sh'],
            workingDirectory: null,
            pid: 12,
            columns: 80,
            rows: 24,
            startedAt: t0,
            observedAt: t0,
            totalBytes: 0,
            firstAvailableOffset: 0,
            lifecycle: SessionEndedWithoutCode(t0, 'not reaped'),
            writeHolder: null,
          ),
        ]),
      );

      expect(decoded.summaries.map((s) => s.id), [
        'running',
        'exited',
        'unknown',
      ]);
      expect(decoded.summaries[0].lifecycle, isA<SessionRunning>());
      expect(decoded.summaries[0].workingDirectory, '/srv');
      expect(decoded.summaries[0].writeHolder, 'pane-1');
      expect(decoded.summaries[1].lifecycle.exitCode, 1);
      expect(decoded.summaries[2].lifecycle.exitCode, isNull);
      expect(
        (decoded.summaries[2].lifecycle as SessionEndedWithoutCode).reason,
        'not reaped',
      );
    });

    test(
      'error carries a code a client can branch on and words a user can read',
      () {
        final decoded = roundTrip(
          const ErrorMessage(
            3,
            ProtocolErrorCode.protocolMismatch,
            'host speaks 1, client 99',
          ),
        );
        expect(decoded.code, ProtocolErrorCode.protocolMismatch);
        expect(decoded.message, 'host speaks 1, client 99');
        expect(decoded.detail, isNull);
      },
    );

    test('error carries its whole account apart from its short words, and a '
        'frame without one still reads', () {
      final decoded = roundTrip(
        const ErrorMessage(
          4,
          ProtocolErrorCode.internal,
          "Can't reach DO.",
          detail: 'dev@203.0.113.9:22: connection refused',
        ),
      );
      expect(decoded.message, "Can't reach DO.");
      expect(decoded.detail, 'dev@203.0.113.9:22: connection refused');

      final bare = Frame(
        MessageType.error,
        0,
        (WireWriter()
              ..u32(5)
              ..u32(ProtocolErrorCode.protocolMismatch.code)
              ..str('host speaks protocol 17'))
            .take(),
      );
      final read = ErrorMessage.decode(bare);
      expect(read.message, 'host speaks protocol 17');
      expect(read.detail, isNull);
    });

    test('an error code this build has never heard of reads as internal', () {
      expect(ProtocolErrorCode.fromCode(9999), ProtocolErrorCode.internal);
    });

    test('closed reports the exit code it managed to collect, or none', () {
      expect(roundTrip(const ClosedMessage(1, 'a', 3)).exitCode, 3);
      expect(roundTrip(const ClosedMessage(1, 'a', null)).exitCode, isNull);
    });

    test('claimed reports who holds it after the attempt', () {
      final decoded = roundTrip(
        const ClaimedMessage(
          requestId: 2,
          sessionRef: 4,
          holdsWriteToken: true,
          writeHolder: 'me',
        ),
      );
      expect(decoded.holdsWriteToken, isTrue);
      expect(decoded.writeHolder, 'me');
      expect(decoded.sessionRef, 4);
    });
  });

  test('a mixed conversation decodes in order from one byte stream', () {
    final bytes = <int>[
      ...const HelloMessage(requestId: 1, clientId: 'p').toFrame().encode(),
      ...OutputMessage(1, 0, Uint8List.fromList([65])).toFrame().encode(),
      ...InputMessage(1, Uint8List(0)).toFrame().encode(),
      ...const ListMessage(2).toFrame().encode(),
    ];
    final decoded = FrameParser().add(bytes).map(decodeMessage).toList();
    expect(decoded.map((m) => m.runtimeType.toString()), [
      'HelloMessage',
      'OutputMessage',
      'InputMessage',
      'ListMessage',
    ]);
  });

  group('the screen on attach', () {
    test('an attach carries its grid, and one without reads as none', () {
      const withGrid = AttachMessage(
        requestId: 7,
        sessionId: 's',
        sinceOffset: 0,
        claimWrite: true,
        screenGrid: (120, 40),
      );
      expect(AttachMessage.decode(withGrid.toFrame()).screenGrid, (120, 40));
      const without = AttachMessage(
        requestId: 7,
        sessionId: 's',
        sinceOffset: 9,
        claimWrite: false,
      );
      final decoded = AttachMessage.decode(without.toFrame());
      expect(decoded.screenGrid, isNull);
      expect(decoded.sinceOffset, 9);
    });

    test('attached says whether a screen follows; an older host says no', () {
      AttachedMessage attached({required bool screen}) => AttachedMessage(
        requestId: 1,
        sessionRef: 2,
        sessionId: 's',
        columns: 80,
        rows: 24,
        replayFromOffset: 5,
        droppedBytes: 0,
        totalBytes: 5,
        holdsWriteToken: true,
        writeHolder: null,
        observedAt: DateTime.utc(2026, 9, 24),
        screenFollows: screen,
      );
      final frame = attached(screen: true).toFrame();
      expect(AttachedMessage.decode(frame).screenFollows, isTrue);
      // The payload an older host sends: everything but the trailing flag.
      final older = Frame(
        MessageType.attached,
        frame.sessionRef,
        Uint8List.sublistView(frame.payload, 0, frame.payload.length - 1),
      );
      expect(AttachedMessage.decode(older).screenFollows, isFalse);
    });

    test('a screen message carries its offset and bytes', () {
      final message = ScreenMessage(3, 1234, Uint8List.fromList([27, 99, 65]));
      final decoded =
          decodeMessage(FrameParser().add(message.toFrame().encode()).single)
              as ScreenMessage;
      expect((decoded.sessionRef, decoded.offset), (3, 1234));
      expect(decoded.bytes, [27, 99, 65]);
    });
  });

  // docs/daemon-architecture.md, "Frames that never change": a host of every
  // protocol answers these bytes, so no bump may touch them.
  group('the stop check never changes', () {
    test('stopCheck, byte for byte', () {
      expect(const StopCheckMessage(7).toFrame().encode(), [
        0xf0, 0, 0, 0, 0, 0, 0, 4, //
        0, 0, 0, 7,
      ]);
      expect(roundTrip(const StopCheckMessage(7)).requestId, 7);
    });

    test('stopNow, byte for byte, and its code sits in the frozen set', () {
      expect(MessageType.stopNow.code, 0xf2);
      expect(const StopNowMessage(7).toFrame().encode(), [
        0xf2, 0, 0, 0, 0, 0, 0, 4, //
        0, 0, 0, 7,
      ]);
      expect(roundTrip(const StopNowMessage(7)).requestId, 7);
    });

    test('stopCheckAnswer, byte for byte', () {
      const answer = StopCheckAnswerMessage(
        requestId: 7,
        protocolVersion: 17,
        pid: 0x01020304,
        runningSessions: 2,
      );
      expect(answer.toFrame().encode(), [
        0xf1, 0, 0, 0, 0, 0, 0, 16, //
        0, 0, 0, 7, 0, 0, 0, 17, 1, 2, 3, 4, 0, 0, 0, 2,
      ]);
      final decoded = roundTrip(answer);
      expect(
        (decoded.requestId, decoded.protocolVersion, decoded.pid),
        (7, 17, 0x01020304),
      );
      expect(decoded.runningSessions, 2);
    });
  });
}
