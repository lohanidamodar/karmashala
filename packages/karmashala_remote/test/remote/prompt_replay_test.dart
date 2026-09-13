/// A prompt the phone was never answered for is the one it will send again.
///
/// The host answers `prompt.send` from the far end of one serial chain per
/// device, so a slow transcript read queued ahead of it can push the answer
/// past the phone's request timeout while the prompt itself has already been
/// typed. The composer keeps the text for a retry, and every prompt is
/// keystrokes into one PTY: without a key the retry is the same message typed
/// twice. The key is optional and additive — a phone that sends none is typed
/// for on every frame, exactly as before.
library;

import 'dart:async';

import 'package:karmashala_remote/host.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:test/test.dart';

import './fake_bindings.dart';

typedef Frame = ({FrameType type, String? id, Map<String, Object?> payload});

class PromptHarness {
  PromptHarness() {
    fake = FakeRemoteBindings()..addSession('s1');
    api = _newApi();
  }

  late final FakeRemoteBindings fake;
  late HostSessionApi api;
  final List<Frame> sent = [];
  final ledger = SessionStartLedger<RemotePromptDelivery>();
  int _seq = 0;

  HostSessionApi _newApi() => HostSessionApi(
    device: fakeDevice(),
    bindings: fake.bindings,
    promptLedger: ledger,
    send: (type, {id, payload = const {}}) async {
      sent.add((type: type, id: id, payload: payload));
      return true;
    },
  );

  /// The redial that carries a retry lands on a fresh generation and a fresh
  /// api; only the ledger is the device's.
  void reconnect() => api = _newApi();

  Future<void> send({
    String? requestId,
    String text = 'run the tests',
    String id = 'q1',
  }) => api.handleEnvelope(
    Envelope.of(
      FrameType.promptSend,
      seq: _seq++,
      id: id,
      payload: {'sessionId': 's1', 'text': text, 'requestId': ?requestId},
    ),
  );

  Frame get last => sent.last;
}

void main() {
  group('the idempotency key on prompt.send', () {
    test('the same key twice types the prompt once, and says so', () async {
      final harness = PromptHarness();

      await harness.send(requestId: 'k1', id: 'q1');
      await harness.send(requestId: 'k1', id: 'q2');

      expect(harness.fake.prompts, hasLength(1));
      expect(harness.sent.map((f) => f.type), everyElement(FrameType.result));
      expect(harness.sent.first.payload.containsKey('replayed'), isFalse);
      expect(harness.last.payload['replayed'], isTrue);
    });

    test('a retry after the link dropped still types it once', () async {
      final harness = PromptHarness();

      await harness.send(requestId: 'k1');
      harness.reconnect();
      await harness.send(requestId: 'k1');

      expect(harness.fake.prompts, hasLength(1));
      expect(harness.last.payload['replayed'], isTrue);
    });

    test('a different key is a different message', () async {
      final harness = PromptHarness();

      await harness.send(requestId: 'k1');
      await harness.send(requestId: 'k2', text: 'and the lints', id: 'q2');

      expect(harness.fake.prompts.map((p) => p.text), [
        'run the tests',
        'and the lints',
      ]);
    });

    test('no key is typed for on every frame — the older phone', () async {
      final harness = PromptHarness();

      await harness.send();
      await harness.send(id: 'q2');

      expect(harness.fake.prompts, hasLength(2));
      // And the result keeps the shape every build before this one read.
      expect(harness.last.payload, isEmpty);
    });

    test('a prompt that failed leaves the key free to retry', () async {
      final harness = PromptHarness()
        ..fake.promptError = const RemoteApiRefusal(
          ErrorCode.badRequest,
          'this session was imported from the CLI',
        );

      await harness.send(requestId: 'k1');
      expect(harness.last.type, FrameType.error);

      harness.fake.promptError = null;
      await harness.send(requestId: 'k1', id: 'q2');

      expect(harness.last.type, FrameType.result);
      expect(harness.fake.prompts, hasLength(1));
      expect(harness.last.payload.containsKey('replayed'), isFalse);
    });

    test('two frames racing on one key join the same send', () async {
      final harness = PromptHarness();
      final gate = Completer<void>();
      harness.fake.promptGate = gate;

      final first = harness.send(requestId: 'k1', id: 'q1');
      final second = harness.send(requestId: 'k1', id: 'q2');
      harness.fake.promptGate = null;
      gate.complete();
      await Future.wait([first, second]);

      expect(harness.fake.prompts, hasLength(1));
      expect(harness.sent, hasLength(2));
      expect(harness.sent.map((f) => f.type), everyElement(FrameType.result));
    });

    test('a key past the cap is refused, not stored', () async {
      final harness = PromptHarness();

      await harness.send(requestId: 'k' * (kMaxSessionStartKeyLength + 1));

      expect(harness.last.type, FrameType.error);
      expect(harness.last.payload['code'], ErrorCode.badRequest.wire);
      expect(harness.fake.prompts, isEmpty);
    });

    test('the client puts the key on the wire only when given one', () {
      // Pinned at the payload level: an old host ignores the field, and a
      // phone that has no key must not send an empty one.
      expect(
        {'sessionId': 's1', 'text': 't', 'requestId': ?null},
        {'sessionId': 's1', 'text': 't'},
      );
    });
  });
}
