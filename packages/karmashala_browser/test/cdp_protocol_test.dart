import 'dart:convert';

import 'package:karmashala_browser/browser.dart';
import 'package:test/test.dart';

void main() {
  group('encodeCdpCommand', () {
    test('writes id and method', () {
      final frame =
          jsonDecode(encodeCdpCommand(id: 7, method: 'Page.enable'))
              as Map<String, Object?>;
      expect(frame, {'id': 7, 'method': 'Page.enable'});
    });

    test('omits params entirely when there are none', () {
      final frame =
          jsonDecode(
                encodeCdpCommand(id: 1, method: 'DOM.enable', params: const {}),
              )
              as Map<String, Object?>;
      expect(frame.containsKey('params'), isFalse);
    });

    test('carries params and a session id', () {
      final frame =
          jsonDecode(
                encodeCdpCommand(
                  id: 2,
                  method: 'Page.navigate',
                  params: {'url': 'https://example.com'},
                  sessionId: 'S1',
                ),
              )
              as Map<String, Object?>;
      expect(frame['params'], {'url': 'https://example.com'});
      expect(frame['sessionId'], 'S1');
    });
  });

  group('decodeCdpMessage', () {
    test('reads a result frame', () {
      final message =
          decodeCdpMessage('{"id":3,"result":{"frameId":"F1"}}') as CdpResult;
      expect(message.id, 3);
      expect(message.result['frameId'], 'F1');
      expect(message.sessionId, isNull);
    });

    test('a sessionId that is not a string is a protocol error, not a '
        'TypeError', () {
      // A TypeError escapes the connection's protocol-error handler and takes
      // the whole frame loop down with it.
      expect(
        () => decodeCdpMessage('{"id":3,"sessionId":7,"result":{}}'),
        throwsA(isA<CdpProtocolException>()),
      );
    });

    test('treats a result-less reply as an empty result', () {
      final message = decodeCdpMessage('{"id":4}') as CdpResult;
      expect(message.result, isEmpty);
    });

    test('reads an error frame and folds data into the description', () {
      final message =
          decodeCdpMessage(
                '{"id":5,"error":{"code":-32000,"message":"Cannot find node",'
                '"data":"nodeId 12"}}',
              )
              as CdpErrorMessage;
      expect(message.id, 5);
      expect(message.code, -32000);
      expect(message.description, 'Cannot find node: nodeId 12');
    });

    test('reads an error frame without data', () {
      final message =
          decodeCdpMessage('{"id":6,"error":{"code":-1,"message":"nope"}}')
              as CdpErrorMessage;
      expect(message.description, 'nope');
    });

    test('reads an event frame', () {
      final message =
          decodeCdpMessage(
                '{"method":"Page.loadEventFired","params":{"timestamp":1.5}}',
              )
              as CdpEvent;
      expect(message.method, 'Page.loadEventFired');
      expect(message.params['timestamp'], 1.5);
    });

    test('reads an event with no params', () {
      final message =
          decodeCdpMessage('{"method":"Runtime.executionContextsCleared"}')
              as CdpEvent;
      expect(message.params, isEmpty);
    });

    test('keeps the session id on every kind of frame', () {
      expect(
        (decodeCdpMessage('{"id":1,"result":{},"sessionId":"A"}') as CdpResult)
            .sessionId,
        'A',
      );
      expect(
        (decodeCdpMessage('{"method":"X","sessionId":"B"}') as CdpEvent)
            .sessionId,
        'B',
      );
    });

    test('rejects frames that are not JSON', () {
      expect(
        () => decodeCdpMessage('not json'),
        throwsA(isA<CdpProtocolException>()),
      );
    });

    test('rejects frames that are not objects', () {
      expect(
        () => decodeCdpMessage('[1,2,3]'),
        throwsA(isA<CdpProtocolException>()),
      );
    });

    test('rejects frames with neither id nor method', () {
      expect(
        () => decodeCdpMessage('{"hello":"world"}'),
        throwsA(isA<CdpProtocolException>()),
      );
    });

    test('rejects a non-integer id', () {
      expect(
        () => decodeCdpMessage('{"id":"three","result":{}}'),
        throwsA(isA<CdpProtocolException>()),
      );
    });

    test('rejects a result that is not an object', () {
      expect(
        () => decodeCdpMessage('{"id":1,"result":42}'),
        throwsA(isA<CdpProtocolException>()),
      );
    });

    test('an id wins over a method on the same frame', () {
      final message =
          decodeCdpMessage('{"id":9,"method":"Runtime.evaluate"}') as CdpResult;
      expect(message.id, 9);
    });
  });
}
