import 'dart:convert';

import 'package:karmashala_relay_protocol/karmashala_relay_protocol.dart';
import 'package:test/test.dart';

const _key = '00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff';
const _listen = '0123456789abcdef0123456789abcdef';
const _hook = 'fedcba9876543210fedcba9876543210';

void main() {
  group('hook routes', () {
    test('the listener presents its key under v1/hooks/', () {
      expect(hooksListenPath(_key), 'v1/hooks/$_key');
      expect(hooksListenKeyOf('v1/hooks/$_key'), _key);
      expect(hooksListenKeyOf('v1/hooks/${_key.substring(2)}'), isNull);
      expect(hooksListenKeyOf('v1/hooks/${_key.toUpperCase()}'), isNull);
    });

    test('the listener route is never a rendezvous, nor a rendezvous a '
        'listener', () {
      expect(rendezvousIdOf('v1/hooks/$_key'), isNull);
      expect(rendezvousIdOf(hookCallPath(_listen, _hook)), isNull);
      expect(hooksListenKeyOf(rendezvousPath(_listen)), isNull);
      expect(hookCallOf(rendezvousPath(_listen)), isNull);
    });

    test('a call names a listen id and a hook id', () {
      expect(hookCallPath(_listen, _hook), 'h/$_listen/$_hook');
      final call = hookCallOf('h/$_listen/$_hook')!;
      expect(call.listenId, _listen);
      expect(call.hookId, _hook);
      expect(hookCallOf('h/$_listen'), isNull);
      expect(hookCallOf('h/$_listen/$_hook/x'), isNull);
      expect(hookCallOf('h/$_listen/${_hook.toUpperCase()}'), isNull);
      expect(isHookCallRoute('h/anything'), isTrue);
      expect(isHookCallRoute('hx/anything'), isFalse);
    });

    test('the listen id derivation has a fixed known answer', () {
      expect(hooksListenKeyPattern.hasMatch(kHooksListenIdVector.key), isTrue);
      expect(hooksListenIdPattern.hasMatch(kHooksListenIdVector.id), isTrue);
      expect(
        hooksListenIdInput(kHooksListenIdVector.key),
        'karmashala-hooks-listen:${kHooksListenIdVector.key}',
      );
    });
  });

  group('hook frames', () {
    test('a call round-trips with its raw bytes', () {
      final bytes = utf8.encode('{"a":"é"}');
      final call = HookCall(
        id: 'c1',
        hookId: _hook,
        method: 'POST',
        headers: const {'content-type': 'application/json'},
        body: bytes,
        ip: '203.0.113.9',
      );
      final read = HookFrame.tryDecode(call.encode())! as HookCall;
      expect(read.id, 'c1');
      expect(read.hookId, _hook);
      expect(read.body, bytes);
      expect(read.ip, '203.0.113.9');
      expect(read.headers, {'content-type': 'application/json'});
    });

    test('a call drops headers outside the forwarded set', () {
      final json = HookCall(
        id: 'c1',
        hookId: _hook,
        method: 'POST',
        headers: const {},
        body: const [],
      ).toJson()..['headers'] = {'cookie': 'x', 'x-github-delivery': 'd'};
      final read = HookFrame.tryDecode(jsonEncode(json))! as HookCall;
      expect(read.headers, {'x-github-delivery': 'd'});
    });

    test('an answer round-trips', () {
      const answer = HookAnswer(id: 'c1', status: 202, body: {'session': 's1'});
      final read = HookFrame.tryDecode(answer.encode())! as HookAnswer;
      expect(read.status, 202);
      expect(read.body, {'session': 's1'});
    });

    test('an answer breaking a rule is refused', () {
      Map<String, Object?> answer(Object? status, Object? body) => {
        'type': 'answer',
        'id': 'c1',
        'status': status,
        'body': body,
      };
      expect(HookAnswer.tryParse(answer(99, {})), isNull);
      expect(HookAnswer.tryParse(answer(600, {})), isNull);
      expect(HookAnswer.tryParse(answer('202', {})), isNull);
      expect(HookAnswer.tryParse(answer(202, 'x')), isNull);
      expect(
        HookAnswer.tryParse(answer(202, {'pad': 'x' * kHookMaxAnswerBytes})),
        isNull,
      );
    });

    test('the ready frame carries the listen id and the version', () {
      const ready = HooksReady(listenId: _listen);
      final read = HookFrame.tryDecode(ready.encode())! as HooksReady;
      expect(read.listenId, _listen);
      expect(read.version, kHooksProtocolVersion);
      expect(read.maxBodyBytes, kHookMaxBodyBytes);
    });

    test('unknown or broken frames read as nothing', () {
      expect(HookFrame.tryDecode('{"type":"later"}'), isNull);
      expect(HookFrame.tryDecode('not json'), isNull);
      expect(HookFrame.tryDecode(const [1, 2]), isNull);
      expect(HookFrame.tryDecode('{"type":"call","id":"c"}'), isNull);
    });

    test('the relay error body is a small JSON object', () {
      expect(jsonDecode(hookErrorBody('server offline')), {
        'error': 'server offline',
      });
    });
  });
}
