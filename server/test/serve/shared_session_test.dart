import 'dart:async';
import 'dart:typed_data';

import 'package:karmashala_host/karmashala_host.dart';
import 'package:test/test.dart';

import '../protocol/host_server_test.dart' show PipeConnection;

/// Slice 5e at the server: one connection carrying many refs, output held to
/// a bounded amount unacknowledged (a slow reader gets the screen again,
/// never a gap), who types when two clients share a session, what each is
/// told about it, and what a link from another machine may not ask.
void main() {
  var now = DateTime.utc(2026, 9, 27, 12);

  ({HostServer server, SessionRegistry registry, FakePtyLauncher launcher})
  build({int ring = 64 * 1024 * 1024}) {
    final launcher = FakePtyLauncher();
    final registry = SessionRegistry(
      launcher: launcher,
      backlogCapacityBytes: ring,
      clock: () => now,
    );
    return (
      server: HostServer(
        registry: registry,
        ptyLibrary: 'libc.so.6',
        clock: () => now,
      ),
      registry: registry,
      launcher: launcher,
    );
  }

  setUp(() => now = DateTime.utc(2026, 9, 27, 12));

  Future<PipeConnection> connect(
    HostServer server,
    String id, {
    bool acks = true,
    LinkTrust trust = LinkTrust.local,
  }) async {
    final client = PipeConnection(id);
    unawaited(server.serveConnection(client, trust: trust));
    await client.send(
      HelloMessage(
        requestId: 1,
        clientId: id,
        features: acks ? HelloMessage.acksOutput : 0,
      ),
    );
    return client;
  }

  Uint8List bytes(int length, [int fill = 0x61]) =>
      Uint8List(length)..fillRange(0, length, fill);

  group('one connection, many refs', () {
    test('two panes on one link are told apart by ref', () async {
      final env = build();
      env.registry.open('a', const PtySpawnRequest(argv: ['sh']));
      env.registry.open('b', const PtySpawnRequest(argv: ['sh']));
      final client = await connect(env.server, 'studio');
      await client.send(
        const AttachMessage(
          requestId: 2,
          sessionId: 'a',
          sinceOffset: 0,
          claimWrite: true,
        ),
      );
      await client.send(
        const AttachMessage(
          requestId: 3,
          sessionId: 'b',
          sinceOffset: 0,
          claimWrite: true,
        ),
      );
      final refs = {
        for (final a in client.all<AttachedMessage>()) a.sessionId: a.sessionRef,
      };
      expect(refs.values.toSet(), hasLength(2));
      env.launcher.handles[0].emit('from a'.codeUnits);
      env.launcher.handles[1].emit('from b'.codeUnits);
      await client.pump();
      final outputs = client.all<OutputMessage>().toList();
      expect(
        String.fromCharCodes(
          outputs.firstWhere((o) => o.sessionRef == refs['a']).bytes,
        ),
        'from a',
      );
      expect(
        String.fromCharCodes(
          outputs.firstWhere((o) => o.sessionRef == refs['b']).bytes,
        ),
        'from b',
      );

      // Detaching one leaves the other streaming.
      await client.send(DetachMessage(refs['a']!));
      client.clear();
      env.launcher.handles[0].emit('more a'.codeUnits);
      env.launcher.handles[1].emit('more b'.codeUnits);
      await client.pump();
      expect(client.all<OutputMessage>().map((o) => o.sessionRef), [
        refs['b'],
      ]);
    });
  });

  group('flow control', () {
    test('output goes in pieces of at most 64 KiB', () async {
      final env = build();
      env.registry.open('a', const PtySpawnRequest(argv: ['sh']));
      final client = await connect(env.server, 'studio', acks: false);
      await client.send(
        const AttachMessage(
          requestId: 2,
          sessionId: 'a',
          sinceOffset: 0,
          claimWrite: true,
        ),
      );
      env.launcher.handles.single.emit(bytes(200 * 1024));
      await client.pump();
      final pieces = client.all<OutputMessage>().toList();
      expect(pieces.every((o) => o.bytes.length <= kOutputChunkBytes), isTrue);
      expect(pieces.fold<int>(0, (n, o) => n + o.bytes.length), 200 * 1024);
    });

    test('an acknowledging client is sent at most 512 KiB past its ack, and '
        'the rest once it acks', () async {
      final env = build();
      env.registry.open('a', const PtySpawnRequest(argv: ['sh']));
      final client = await connect(env.server, 'studio');
      await client.send(
        const AttachMessage(
          requestId: 2,
          sessionId: 'a',
          sinceOffset: 0,
          claimWrite: true,
        ),
      );
      final ref = client.only<AttachedMessage>().sessionRef;
      for (var i = 0; i < 32; i++) {
        env.launcher.handles.single.emit(bytes(32 * 1024));
      }
      await client.pump();
      int sent() => client.all<OutputMessage>().fold(
        0,
        (n, o) => o.nextOffset > n ? o.nextOffset : n,
      );
      expect(sent(), lessThanOrEqualTo(kUnackedOutputBytes));
      expect(sent(), greaterThan(0));

      await client.send(OutputAckMessage(ref, sent()));
      await client.pump();
      expect(sent(), greaterThan(kUnackedOutputBytes));
      // Contiguous: every piece starts where the one before ended.
      var at = 0;
      for (final o in client.all<OutputMessage>()) {
        expect(o.offset, at);
        at = o.nextOffset;
      }
    });

    test('a reader that fell behind the ring is sent the screen again, and '
        'output resumes from it — never a gap', () async {
      final env = build(ring: 256 * 1024);
      env.registry.open('a', const PtySpawnRequest(argv: ['sh']));
      final client = await connect(env.server, 'studio');
      await client.send(
        const AttachMessage(
          requestId: 2,
          sessionId: 'a',
          sinceOffset: 0,
          claimWrite: true,
        ),
      );
      final ref = client.only<AttachedMessage>().sessionRef;
      for (var i = 0; i < 64; i++) {
        env.launcher.handles.single.emit(bytes(32 * 1024, 0x62));
      }
      await client.pump();
      final stalledAt = client.all<OutputMessage>().last.nextOffset;
      client.clear();

      await client.send(OutputAckMessage(ref, stalledAt));
      final screen = client.only<ScreenMessage>();
      expect(screen.offset, 64 * 32 * 1024);
      expect(String.fromCharCodes(screen.bytes.take(2)), '\x1bc');
      env.launcher.handles.single.emit('after'.codeUnits);
      await client.pump();
      final next = client.all<OutputMessage>().single;
      expect(next.offset, screen.offset);
      expect(String.fromCharCodes(next.bytes), 'after');
    });

    test('the exit follows the last byte a stalled reader is sent', () async {
      final env = build();
      env.registry.open('a', const PtySpawnRequest(argv: ['sh']));
      final client = await connect(env.server, 'studio');
      await client.send(
        const AttachMessage(
          requestId: 2,
          sessionId: 'a',
          sinceOffset: 0,
          claimWrite: true,
        ),
      );
      final ref = client.only<AttachedMessage>().sessionRef;
      env.launcher.handles.single
        ..emit(bytes(kUnackedOutputBytes + 1024))
        ..finish(0);
      await client.pump();
      expect(client.all<ExitedMessage>(), isEmpty);
      await client.send(
        OutputAckMessage(ref, client.all<OutputMessage>().last.nextOffset),
      );
      await client.pump();
      expect(client.all<ExitedMessage>().single.exitCode, 0);
      expect(
        client.all<OutputMessage>().last.nextOffset,
        kUnackedOutputBytes + 1024,
      );
    });
  });

  group('two clients on one session', () {
    Future<(PipeConnection, PipeConnection, int, int, FakePtyHandle)> twoOn(
      ({
        HostServer server,
        SessionRegistry registry,
        FakePtyLauncher launcher,
      })
      env,
    ) async {
      env.registry.open(
        'a',
        const PtySpawnRequest(argv: ['sh'], columns: 100, rows: 30),
      );
      final laptop = await connect(env.server, 'laptop');
      final desk = await connect(env.server, 'desk');
      await laptop.send(
        const AttachMessage(
          requestId: 2,
          sessionId: 'a',
          sinceOffset: 0,
          claimWrite: true,
          screenGrid: (100, 30),
        ),
      );
      await desk.send(
        const AttachMessage(
          requestId: 2,
          sessionId: 'a',
          sinceOffset: 0,
          claimWrite: true,
          screenGrid: (160, 50),
        ),
      );
      return (
        laptop,
        desk,
        laptop.only<AttachedMessage>().sessionRef,
        desk.only<AttachedMessage>().sessionRef,
        env.launcher.handles.single,
      );
    }

    test('both are told who drives and who watches, and the session keeps '
        'the holder\'s grid', () async {
      final env = build();
      final (laptop, desk, _, deskRef, _) = await twoOn(env);
      final told = desk.last<PresenceMessage>();
      expect(told.sessionRef, deskRef);
      expect(told.holder, 'laptop');
      expect(told.viewers, ['desk']);
      expect((told.columns, told.rows), (100, 30));
      expect(laptop.last<PresenceMessage>().viewers, ['desk']);
    });

    test('a viewer\'s keystroke while the holder is typing is refused on '
        'its ref; after 3 s idle it takes over, at its own grid', () async {
      final env = build();
      final (laptop, desk, _, deskRef, pty) = await twoOn(env);
      await laptop.send(InputMessage(1, Uint8List.fromList('l'.codeUnits)));
      await desk.send(InputMessage(deskRef, Uint8List.fromList('d'.codeUnits)));
      final refused = desk.last<ErrorMessage>();
      expect(refused.code, ProtocolErrorCode.writeRefused);
      expect(refused.sessionRef, deskRef);
      expect(refused.message, contains('laptop'));
      expect(pty.writes.map(String.fromCharCodes), ['l']);

      now = now.add(const Duration(seconds: 4));
      await desk.send(InputMessage(deskRef, Uint8List.fromList('d'.codeUnits)));
      expect(pty.writes.map(String.fromCharCodes), ['l', 'd']);
      expect(pty.resizes.last, (160, 50));
      final told = laptop.last<PresenceMessage>();
      expect(told.holder, 'desk');
      expect(told.sizedFor, 'desk');
      expect((told.columns, told.rows), (160, 50));
    });

    test('Take over moves the token at once; a viewer\'s resize is kept '
        'for then and applies nothing meanwhile', () async {
      final env = build();
      final (laptop, desk, _, deskRef, pty) = await twoOn(env);
      await desk.send(ResizeMessage(deskRef, 120, 40));
      expect(pty.resizes.where((r) => r == (120, 40)), isEmpty);
      expect(desk.all<ErrorMessage>(), isEmpty);

      await desk.send(ClaimMessage(3, deskRef, takeOver: true));
      expect(desk.last<ClaimedMessage>().holdsWriteToken, isTrue);
      expect(pty.resizes.last, (120, 40));
      expect(laptop.last<PresenceMessage>().holder, 'desk');
    });

    test('a claim without taking over is still refused while held', () async {
      final env = build();
      final (_, desk, _, deskRef, _) = await twoOn(env);
      await desk.send(ClaimMessage(4, deskRef));
      expect(desk.last<ErrorMessage>().code, ProtocolErrorCode.writeRefused);
    });

    test('the holder hanging up frees the token, and the other is told',
        () async {
      final env = build();
      final (laptop, desk, _, _, _) = await twoOn(env);
      await laptop.hangUp();
      await desk.pump();
      final told = desk.last<PresenceMessage>();
      expect(told.holder, isNull);
      expect(told.viewers, ['desk']);
    });

    test('two clients naming themselves alike are told apart', () async {
      final env = build();
      env.registry.open('a', const PtySpawnRequest(argv: ['sh']));
      final one = await connect(env.server, 'mac');
      final two = await connect(env.server, 'mac');
      for (final c in [one, two]) {
        await c.send(
          const AttachMessage(
            requestId: 2,
            sessionId: 'a',
            sinceOffset: 0,
            claimWrite: true,
          ),
        );
      }
      final told = two.last<PresenceMessage>();
      expect(told.holder, 'mac');
      expect(told.viewers, ['mac (2)']);
    });

    /// A phone looking at the laptop's session: attached without claiming.
    Future<(PipeConnection, int)> phoneOn(
      ({HostServer server, SessionRegistry registry, FakePtyLauncher launcher})
      env,
    ) async {
      final phone = await connect(env.server, 'phone');
      await phone.send(
        const AttachMessage(
          requestId: 2,
          sessionId: 'a',
          sinceOffset: 0,
          claimWrite: false,
        ),
      );
      return (phone, phone.only<AttachedMessage>().sessionRef);
    }

    test(
      'a phone that only looks never resizes the session: its resize is '
      'ignored, and its keystroke takes the input at the session\'s grid',
      () async {
        final env = build();
        final (laptop, _, _, _, pty) = await twoOn(env);
        final (phone, phoneRef) = await phoneOn(env);
        await phone.send(ResizeMessage(phoneRef, 40, 60));
        expect(pty.resizes, isNot(contains((40, 60))));

        now = now.add(const Duration(seconds: 4));
        await phone.send(
          InputMessage(phoneRef, Uint8List.fromList('p'.codeUnits)),
        );
        expect(laptop.last<PresenceMessage>().holder, 'phone');
        expect(pty.resizes, isNot(contains((40, 60))));
        expect(laptop.last<PresenceMessage>().sizedFor, isNot('phone'));
      },
    );

    test('a phone that took over and lets go gives the session back at the '
        'grid of the one it took it from', () async {
      final env = build();
      final (laptop, _, _, _, pty) = await twoOn(env);
      final (phone, phoneRef) = await phoneOn(env);
      await phone.send(ClaimMessage(3, phoneRef, takeOver: true));
      await phone.send(ResizeMessage(phoneRef, 40, 60));
      expect(pty.resizes.last, (40, 60));

      await phone.send(ReleaseMessage(4, phoneRef));
      expect(pty.resizes.last, (100, 30));
      final told = laptop.last<PresenceMessage>();
      expect(told.sizedFor, 'laptop');
      expect((told.columns, told.rows), (100, 30));
    });

    test('...and so does one that took over and goes away', () async {
      final env = build();
      final (laptop, _, _, _, pty) = await twoOn(env);
      final (phone, phoneRef) = await phoneOn(env);
      await phone.send(ClaimMessage(3, phoneRef, takeOver: true));
      await phone.send(ResizeMessage(phoneRef, 40, 60));

      await phone.send(DetachMessage(phoneRef));
      expect(pty.resizes.last, (100, 30));
      expect(laptop.last<PresenceMessage>().sizedFor, 'laptop');
    });

    test('keys the server types are not gated by the token', () async {
      final env = build();
      final (_, _, _, _, pty) = await twoOn(env);
      expect(env.registry.require('a').typeAsHost(Uint8List.fromList([13])),
          isTrue);
      expect(pty.writes.last, [13]);
    });
  });

  group('a link from another machine', () {
    const remote = LinkTrust.remote(
      admin: false,
      sshPrompts: false,
      transcripts: true,
    );

    test('may not pair, stop, open by argv or administer', () async {
      final env = build();
      env.server.admin = _Admin();
      final client = await connect(env.server, 'far', trust: remote);
      await client.send(const PairMessage(requestId: 2, capabilities: 1));
      expect(client.last<ErrorMessage>().message, contains('pairing'));
      await client.send(
        const OpenMessage(
          requestId: 3,
          sessionId: 'x',
          argv: ['sh'],
          environment: {},
          columns: 80,
          rows: 24,
        ),
      );
      expect(client.last<ErrorMessage>().message, contains('terminals.open'));
      expect(env.launcher.started, isEmpty);
      await client.send(
        const ServerCallMessage(requestId: 4, method: 'server.info'),
      );
      expect(client.last<ServerResultMessage>().ok, isFalse);
      expect(client.last<ServerResultMessage>().message, contains('grant'));

      final stopper = PipeConnection('stop');
      unawaited(env.server.serveConnection(stopper, trust: remote));
      await stopper.send(const StopCheckMessage(9));
      expect(stopper.all<StopCheckAnswerMessage>(), isEmpty);
      expect(stopper.only<ErrorMessage>().message, contains('remote'));
    });

    test('administers when its pairing grants it', () async {
      final env = build();
      env.server.admin = _Admin();
      final client = await connect(
        env.server,
        'far',
        trust: const LinkTrust.remote(
          admin: true,
          sshPrompts: false,
          transcripts: true,
        ),
      );
      await client.send(
        const ServerCallMessage(requestId: 4, method: 'server.info'),
      );
      expect(client.last<ServerResultMessage>().result, {'name': 'droplet'});
    });
  });
}

class _Admin implements ServerAdmin {
  @override
  Future<Map<String, Object?>> call(
    String method,
    Map<String, Object?> arguments,
  ) async => {'name': 'droplet'};
}
