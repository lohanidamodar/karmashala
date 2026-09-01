import 'package:karmashala/src/features/browser/data/cdp_payloads.dart';
import 'package:karmashala/src/features/browser/domain/browser_failure.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('unwrapEvaluateResult', () {
    test('returns a primitive value', () {
      expect(
        unwrapEvaluateResult({
          'result': {'type': 'number', 'value': 42},
        }),
        42,
      );
    });

    test('returns a structured value', () {
      expect(
        unwrapEvaluateResult({
          'result': {
            'type': 'object',
            'value': {'width': 10},
          },
        }),
        {'width': 10},
      );
    });

    test('maps undefined to null', () {
      expect(
        unwrapEvaluateResult({
          'result': {'type': 'undefined'},
        }),
        isNull,
      );
    });

    test('reports a thrown JavaScript error with its description', () {
      expect(
        () => unwrapEvaluateResult({
          'result': {'type': 'object'},
          'exceptionDetails': {
            'text': 'Uncaught',
            'exception': {
              'description': 'TypeError: x is not a function\n    at <anon>',
            },
          },
        }),
        throwsA(
          isA<BrowserException>()
              .having(
                (e) => e.failure,
                'failure',
                BrowserFailure.evaluationFailed,
              )
              .having(
                (e) => e.message,
                'message',
                contains('TypeError: x is not a function'),
              )
              .having(
                (e) => e.message,
                'message',
                isNot(contains('at <anon>')),
              ),
        ),
      );
    });

    test('falls back to the exception text when there is no description', () {
      expect(
        () => unwrapEvaluateResult({
          'exceptionDetails': {'text': 'Uncaught SyntaxError'},
        }),
        throwsA(
          isA<BrowserException>().having(
            (e) => e.message,
            'message',
            contains('Uncaught SyntaxError'),
          ),
        ),
      );
    });

    test('reports a reply with no result object as malformed', () {
      expect(
        () => unwrapEvaluateResult(const {}),
        throwsA(
          isA<BrowserException>().having(
            (e) => e.failure,
            'failure',
            BrowserFailure.malformedResponse,
          ),
        ),
      );
    });

    test('returns null for an object handle with no value', () {
      expect(
        unwrapEvaluateResult({
          'result': {'type': 'object', 'objectId': '1.2.3'},
        }),
        isNull,
      );
    });
  });

  group('parseComputedStyle', () {
    test('flattens name/value pairs', () {
      expect(
        parseComputedStyle({
          'computedStyle': [
            {'name': 'display', 'value': 'flex'},
            {'name': 'color', 'value': 'rgb(0, 0, 0)'},
          ],
        }),
        {'display': 'flex', 'color': 'rgb(0, 0, 0)'},
      );
    });

    test('skips malformed entries instead of failing', () {
      expect(
        parseComputedStyle({
          'computedStyle': [
            {'name': 'display'},
            'nonsense',
            {'name': 'color', 'value': 'red'},
          ],
        }),
        {'color': 'red'},
      );
    });

    test('returns empty when the domain sent nothing', () {
      expect(parseComputedStyle(const {}), isEmpty);
    });
  });

  group('parseTargetList', () {
    const body = '''
[
  {"id":"A","type":"page","title":"Example","url":"https://example.com",
   "webSocketDebuggerUrl":"ws://127.0.0.1:9222/devtools/page/A"},
  {"id":"B","type":"service_worker","title":"sw","url":"https://x/sw.js",
   "webSocketDebuggerUrl":"ws://127.0.0.1:9222/devtools/page/B"},
  {"id":"C","type":"page","title":"DevTools","url":"devtools://devtools/x",
   "webSocketDebuggerUrl":"ws://127.0.0.1:9222/devtools/page/C"},
  {"id":"D","type":"page","title":"Busy","url":"https://busy.example"}
]
''';

    test('parses every entry', () {
      expect(parseTargetList(body), hasLength(4));
    });

    test('only ordinary attachable pages are drivable', () {
      final drivable = parseTargetList(
        body,
      ).where((t) => t.isDrivablePage).map((t) => t.id).toList();
      expect(drivable, ['A']);
    });

    test('rejects a body that is not JSON', () {
      expect(
        () => parseTargetList('<html>'),
        throwsA(
          isA<BrowserException>().having(
            (e) => e.failure,
            'failure',
            BrowserFailure.malformedResponse,
          ),
        ),
      );
    });

    test('rejects a body that is not an array', () {
      expect(
        () => parseTargetList('{"targets":[]}'),
        throwsA(isA<BrowserException>()),
      );
    });
  });

  group('isDevToolsVersionBody', () {
    test('accepts a real /json/version body', () {
      expect(
        isDevToolsVersionBody(
          '{"Browser":"Chrome/128.0","webSocketDebuggerUrl":'
          '"ws://127.0.0.1:9222/devtools/browser/x"}',
        ),
        isTrue,
      );
    });

    test('rejects an unrelated server answering on the port', () {
      expect(isDevToolsVersionBody('Hello from my dev server'), isFalse);
      expect(isDevToolsVersionBody('{"status":"ok"}'), isFalse);
      expect(isDevToolsVersionBody('[]'), isFalse);
    });
  });
}
