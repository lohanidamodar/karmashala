import 'dart:async';

import 'package:karmashala_companion_server/karmashala_companion_server.dart';
import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_host/lifecycle_client.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

import '../serve/pipe_connection.dart';

T roundTrip<T extends HostMessage>(T message) =>
    decodeMessage(FrameParser().add(message.toFrame().encode()).single) as T;

/// The app's side of the companion over the host protocol: the lifecycle link
/// the app already holds says it is the app (and where its embedded relay
/// is), carries the calls the host forwards and their answers, the desktop's
/// news, and pairing. How phones are served is the server's config, never
/// the link's.
void main() {
  group('the companion frames survive the wire', () {
    test('a call and both kinds of answer', () {
      final call = roundTrip(
        const CompanionCallMessage(
          callId: 3,
          method: 'sessions.get',
          arguments: {'sessionId': 's1'},
        ),
      );
      expect(call.callId, 3);
      expect(call.method, 'sessions.get');
      expect(call.arguments, {'sessionId': 's1'});

      final ok = roundTrip(
        const CompanionResultMessage.success(3, {'session': null}),
      );
      expect(ok.ok, isTrue);
      expect(ok.result, {'session': null});

      final refused = roundTrip(
        const CompanionResultMessage.failure(
          4,
          code: 'bad_request',
          message: 'no',
        ),
      );
      expect(refused.ok, isFalse);
      expect((refused.code, refused.message), ('bad_request', 'no'));
    });

    test('notices and events', () {
      final notice = roundTrip(
        const CompanionNoticeMessage(
          CompanionNoticeKind.attention,
          sessionId: 's1',
          title: 'Fix',
          attention: 'finished',
        ),
      );
      expect(notice.kind, CompanionNoticeKind.attention);
      expect((notice.sessionId, notice.title), ('s1', 'Fix'));

      final event = roundTrip(
        const CompanionEventMessage(
          CompanionEventKind.pairingEnded,
          requestId: 9,
          error: 'expired',
        ),
      );
      expect(event.kind, CompanionEventKind.pairingEnded);
      expect((event.requestId, event.error), (9, 'expired'));
    });

    test('the attach, with and without an embedded relay', () {
      final back = roundTrip(
        const CompanionAttachMessage(localRelayUrl: 'ws://192.168.1.4:8787'),
      );
      expect(back.localRelayUrl, 'ws://192.168.1.4:8787');
      expect(roundTrip(const CompanionAttachMessage()).localRelayUrl, isNull);
    });
  });

  group('over the app\'s lifecycle link', () {
    late AppDatabase database;
    late SessionRegistry registry;
    late DaemonCompanion companion;
    late HostServer server;
    late HostLifecycleWatch watch;

    setUp(() async {
      database = AppDatabase.memory();
      registry = SessionRegistry(launcher: FakePtyLauncher());
      companion = DaemonCompanion(
        database: database,
        registry: registry,
        hostName: 'desk',
        lanPort: 0,
        config: const CompanionConfig(enabled: true),
        transcriptPollInterval: Duration.zero,
      );
      server = HostServer(
        registry: registry,
        ptyLibrary: 'fake',
        companion: companion,
      );
      await companion.start(sessionEvents: server.lifecycle.events);
      final (client, host) = PipeEnd.pair();
      unawaited(server.serveConnection(host));
      watch = await HostLifecycleWatch.over(client, clientId: 'app');
    });

    tearDown(() async {
      await watch.close();
      await companion.close();
      await registry.shutdown();
      database.close();
    });

    Future<void> settle() =>
        Future<void>.delayed(const Duration(milliseconds: 20));

    test('attaching makes this the app calls go to', () async {
      expect(companion.app.connected, isFalse);

      watch.attachCompanion();
      await settle();
      expect(companion.app.connected, isTrue);

      final asked = companion.bindings.listSessions();
      final call = await watch.companionCalls.first;
      expect(call.method, CompanionMethod.listSessions.wire);
      watch.answerCompanionCall(
        call.callId,
        result: {
          'sessions': [
            const RemoteSessionSnapshot(
              sessionId: 's1',
              title: 'From the app',
              status: 'running',
            ).toJson(),
          ],
        },
      );

      expect((await asked).single.title, 'From the app');
    });

    test('the app hanging up leaves the host serving on its own', () async {
      watch.attachCompanion();
      await settle();

      await watch.close();
      await settle();

      expect(companion.app.connected, isFalse);
      expect(await companion.bindings.listSessions(), isEmpty);
    });

    test('the embedded relay is served while the app is attached', () async {
      watch.attachCompanion(localRelayUrl: 'ws://127.0.0.1:8787');
      await settle();
      expect(companion.config.localRelayUrl, Uri.parse('ws://127.0.0.1:8787'));
      expect(companion.config.enabled, isTrue, reason: 'the server config');

      await watch.close();
      await settle();
      expect(
        companion.config.localRelayUrl,
        isNull,
        reason: 'it closed with the app',
      );
    });

    test('a pairing window is opened, drawn and ended', () async {
      watch.attachCompanion();
      await settle();

      final window = await watch.pairCompanion(
        capabilities: CapabilitySet.all.bits,
      );
      expect(window.code, isNotEmpty);
      expect(window.payload, contains('"'), reason: 'the QR payload, encoded');

      final ended = watch.companionEvents.firstWhere(
        (event) => event.kind == CompanionEventKind.pairingEnded,
      );
      watch.noticeCompanion(
        const CompanionNoticeMessage(CompanionNoticeKind.pairingCancelled),
      );
      final event = await ended;
      expect(event.requestId, window.requestId);
      expect(event.deviceId, isNull);
      expect(event.error, isNotNull);
    });

    test('a host with remote access off refuses to pair in words', () async {
      await companion.reconfigure(
        config: CompanionConfig.off,
        lanAddress: '127.0.0.1',
        lanPort: 0,
      );
      watch.attachCompanion();
      await settle();

      await expectLater(
        watch.pairCompanion(capabilities: CapabilitySet.all.bits),
        throwsA(
          isA<HostLifecycleWatchRefused>().having(
            (e) => e.message,
            'message',
            contains('remote access is switched off'),
          ),
        ),
      );
    });
  });
}
