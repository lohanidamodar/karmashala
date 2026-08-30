import 'dart:async';
import 'dart:convert';

import 'package:chitragupta/src/features/browser/data/cdp_connection.dart';
import 'package:chitragupta/src/features/browser/data/cdp_page.dart';
import 'package:chitragupta/src/features/browser/domain/browser_failure.dart';
import 'package:chitragupta/src/features/browser/domain/browser_target.dart';
import 'package:chitragupta/src/features/browser/domain/element_capture.dart';
import 'package:chitragupta/src/features/browser/domain/picked_element.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_cdp_socket.dart';

const _target = BrowserTarget(
  id: 'T1',
  type: 'page',
  title: 'Example',
  url: 'https://example.com',
  webSocketDebuggerUrl: 'ws://127.0.0.1:9222/devtools/page/T1',
);

/// The `Runtime.evaluate` reply shape, with [value] returned by value.
Map<String, Object?> evaluated(Object? value) => {
  'result': {'type': value is num ? 'number' : 'object', 'value': value},
};

Matcher failsWith(BrowserFailure failure) => throwsA(
  isA<BrowserException>().having((e) => e.failure, 'failure', failure),
);

/// A page whose socket answers the domains every call needs.
({CdpPage page, FakeCdpSocket socket}) buildPage({
  FutureOr<Map<String, Object?>?> Function(
    String method,
    Map<String, Object?> params,
  )?
  responder,
  Duration timeout = const Duration(milliseconds: 200),
}) {
  final socket = FakeCdpSocket();
  socket.responder = (method, params) {
    final custom = responder?.call(method, params);
    if (custom != null) return custom;
    return switch (method) {
      'Page.enable' ||
      'Runtime.enable' ||
      'DOM.enable' ||
      'CSS.enable' => <String, Object?>{},
      _ => <String, Object?>{},
    };
  };
  final page = CdpPage(
    connection: CdpConnection(socket, defaultTimeout: timeout),
    target: _target,
  );
  return (page: page, socket: socket);
}

void main() {
  group('enableDomains', () {
    test('enables the four domains everything else depends on', () async {
      final fixture = buildPage();
      await fixture.page.enableDomains();
      expect(fixture.socket.methods, [
        'Page.enable',
        'Runtime.enable',
        'DOM.enable',
        'CSS.enable',
      ]);
      await fixture.page.close();
    });

    test('is idempotent', () async {
      final fixture = buildPage();
      await fixture.page.enableDomains();
      await fixture.page.enableDomains();
      expect(fixture.socket.methods, hasLength(4));
      await fixture.page.close();
    });
  });

  group('navigate', () {
    test('waits for the load event before reporting success', () async {
      late FakeCdpSocket socket;
      final fixture = buildPage(
        responder: (method, params) {
          if (method != 'Page.navigate') return null;
          scheduleMicrotask(() => socket.emitEvent('Page.loadEventFired'));
          return {'frameId': 'F1'};
        },
      );
      socket = fixture.socket;
      await fixture.page.navigate('https://example.com/next');
      expect(socket.paramsFor('Page.navigate'), {
        'url': 'https://example.com/next',
      });
      await fixture.page.close();
    });

    test('reports navigationTimeout when the load event never comes', () async {
      final fixture = buildPage(
        responder: (method, params) =>
            method == 'Page.navigate' ? {'frameId': 'F1'} : null,
      );
      await expectLater(
        fixture.page.navigate(
          'https://slow.example',
          timeout: const Duration(milliseconds: 50),
        ),
        failsWith(BrowserFailure.navigationTimeout),
      );
      await fixture.page.close();
    });

    test('reports a refused navigation with the browser errorText', () async {
      final fixture = buildPage(
        responder: (method, params) => method == 'Page.navigate'
            ? {'frameId': 'F1', 'errorText': 'net::ERR_NAME_NOT_RESOLVED'}
            : null,
      );
      await expectLater(
        fixture.page.navigate('https://nope.invalid'),
        throwsA(
          isA<BrowserException>()
              .having((e) => e.failure, 'failure', BrowserFailure.protocolError)
              .having(
                (e) => e.message,
                'message',
                contains('net::ERR_NAME_NOT_RESOLVED'),
              ),
        ),
      );
      await fixture.page.close();
    });

    test(
      'a browser that goes away mid-navigation reports disconnected',
      () async {
        late FakeCdpSocket socket;
        final fixture = buildPage(
          responder: (method, params) {
            if (method != 'Page.navigate') return null;
            scheduleMicrotask(socket.drop);
            return {'frameId': 'F1'};
          },
          timeout: const Duration(seconds: 5),
        );
        socket = fixture.socket;
        await expectLater(
          fixture.page.navigate('https://example.com'),
          failsWith(BrowserFailure.disconnected),
        );
      },
    );
  });

  group('evaluate', () {
    test('asks for the value, not a handle', () async {
      final fixture = buildPage(
        responder: (method, params) =>
            method == 'Runtime.evaluate' ? evaluated(42) : null,
      );
      expect(await fixture.page.evaluate('6 * 7'), 42);
      expect(fixture.socket.paramsFor('Runtime.evaluate'), {
        'expression': '6 * 7',
        'returnByValue': true,
        'awaitPromise': false,
        'userGesture': true,
      });
      await fixture.page.close();
    });

    test('surfaces a JavaScript exception', () async {
      final fixture = buildPage(
        responder: (method, params) => method == 'Runtime.evaluate'
            ? {
                'result': {'type': 'object'},
                'exceptionDetails': {
                  'exception': {'description': 'ReferenceError: x'},
                },
              }
            : null,
      );
      await expectLater(
        fixture.page.evaluate('x'),
        failsWith(BrowserFailure.evaluationFailed),
      );
      await fixture.page.close();
    });

    test('countMatches counts through the page', () async {
      final fixture = buildPage(
        responder: (method, params) =>
            method == 'Runtime.evaluate' ? evaluated(3) : null,
      );
      expect(await fixture.page.countMatches('.box'), 3);
      expect(
        fixture.socket.paramsFor('Runtime.evaluate')!['expression'],
        'document.querySelectorAll(".box").length',
      );
      await fixture.page.close();
    });
  });

  group('querySelectorNodeId', () {
    test('re-resolves the document, then the selector', () async {
      final fixture = buildPage(
        responder: (method, params) => switch (method) {
          'DOM.getDocument' => {
            'root': {'nodeId': 1},
          },
          'DOM.querySelector' => {'nodeId': 42},
          _ => null,
        },
      );
      expect(await fixture.page.querySelectorNodeId('#go'), 42);
      expect(fixture.socket.paramsFor('DOM.querySelector'), {
        'nodeId': 1,
        'selector': '#go',
      });
      await fixture.page.close();
    });

    test('nodeId 0 means nothing matched', () async {
      final fixture = buildPage(
        responder: (method, params) => switch (method) {
          'DOM.getDocument' => {
            'root': {'nodeId': 1},
          },
          'DOM.querySelector' => {'nodeId': 0},
          _ => null,
        },
      );
      await expectLater(
        fixture.page.querySelectorNodeId('#nope'),
        failsWith(BrowserFailure.elementNotFound),
      );
      await fixture.page.close();
    });

    test('an invalid selector is reported as elementNotFound, not a protocol '
        'error', () async {
      final fixture = buildPage(
        responder: (method, params) {
          if (method == 'DOM.getDocument') {
            return {
              'root': {'nodeId': 1},
            };
          }
          if (method == 'DOM.querySelector') {
            throw CdpFault(-32000, 'DOM Error while querying');
          }
          return null;
        },
      );
      await expectLater(
        fixture.page.querySelectorNodeId('>>>'),
        failsWith(BrowserFailure.elementNotFound),
      );
      await fixture.page.close();
    });

    test('a document with no root is malformed', () async {
      final fixture = buildPage(
        responder: (method, params) =>
            method == 'DOM.getDocument' ? <String, Object?>{} : null,
      );
      await expectLater(
        fixture.page.querySelectorNodeId('#go'),
        failsWith(BrowserFailure.malformedResponse),
      );
      await fixture.page.close();
    });
  });

  group('screenshot', () {
    test(
      'clips in page coordinates and captures beyond the viewport',
      () async {
        final fixture = buildPage(
          responder: (method, params) => method == 'Page.captureScreenshot'
              ? {
                  'data': base64Encode([1, 2, 3]),
                }
              : null,
        );
        final bytes = await fixture.page.screenshot(
          clip: const ElementBox(x: 90, y: 2510, width: 300, height: 180),
        );
        expect(bytes, [1, 2, 3]);
        final params = fixture.socket.paramsFor('Page.captureScreenshot')!;
        expect(params['captureBeyondViewport'], isTrue);
        expect(params['clip'], {
          'x': 90.0,
          'y': 2510.0,
          'width': 300.0,
          'height': 180.0,
          'scale': 1,
        });
        await fixture.page.close();
      },
    );

    test('a plain viewport shot sends no clip at all', () async {
      final fixture = buildPage(
        responder: (method, params) => method == 'Page.captureScreenshot'
            ? {
                'data': base64Encode([9]),
              }
            : null,
      );
      await fixture.page.screenshot();
      final params = fixture.socket.paramsFor('Page.captureScreenshot')!;
      expect(params.containsKey('clip'), isFalse);
      expect(params.containsKey('captureBeyondViewport'), isFalse);
      await fixture.page.close();
    });

    test('a full-page shot clips to the css content size', () async {
      final fixture = buildPage(
        responder: (method, params) => switch (method) {
          'Page.getLayoutMetrics' => {
            'cssContentSize': {'x': 0, 'y': 0, 'width': 1000, 'height': 4000},
          },
          'Page.captureScreenshot' => {
            'data': base64Encode([7]),
          },
          _ => null,
        },
      );
      await fixture.page.screenshot(fullPage: true);
      expect(
        (fixture.socket.paramsFor('Page.captureScreenshot')!['clip']!
            as Map)['height'],
        4000.0,
      );
      await fixture.page.close();
    });

    test('a reply with no image is malformed', () async {
      final fixture = buildPage(
        responder: (method, params) =>
            method == 'Page.captureScreenshot' ? <String, Object?>{} : null,
      );
      await expectLater(
        fixture.page.screenshot(),
        failsWith(BrowserFailure.malformedResponse),
      );
      await fixture.page.close();
    });

    test('layout metrics without a content size are malformed', () async {
      final fixture = buildPage(
        responder: (method, params) =>
            method == 'Page.getLayoutMetrics' ? <String, Object?>{} : null,
      );
      await expectLater(
        fixture.page.contentBox(),
        failsWith(BrowserFailure.malformedResponse),
      );
      await fixture.page.close();
    });
  });

  group('captureElement', () {
    ({CdpPage page, FakeCdpSocket socket}) buildCapturePage() => buildPage(
      responder: (method, params) => switch (method) {
        'Runtime.evaluate' => evaluated({
          'ok': true,
          'selector': '#go',
          'tagName': 'button',
          'id': 'go',
          'classNames': ['primary'],
          'box': {'x': 10, 'y': 20, 'width': 120, 'height': 40},
          'url': 'https://example.com',
          'title': 'Example',
        }),
        'DOM.getDocument' => {
          'root': {'nodeId': 1},
        },
        'DOM.querySelector' => {'nodeId': 42},
        'DOM.getOuterHTML' => {'outerHTML': '<button id="go">Go</button>'},
        'CSS.getComputedStyleForNode' => {
          'computedStyle': [
            {'name': 'display', 'value': 'inline-flex'},
            {'name': 'background-color', 'value': 'rgb(37, 99, 235)'},
          ],
        },
        'Page.captureScreenshot' => {
          'data': base64Encode([4, 5, 6]),
        },
        _ => null,
      },
    );

    test('assembles html, computed css and a cropped screenshot', () async {
      final fixture = buildCapturePage();
      final capture = await fixture.page.captureSelector('#go');
      expect(capture.selector, '#go');
      expect(capture.tagName, 'button');
      expect(capture.elementId, 'go');
      expect(capture.outerHtml, '<button id="go">Go</button>');
      expect(capture.computedStyles['display'], 'inline-flex');
      expect(capture.screenshotPng, [4, 5, 6]);
      expect(capture.box.y, 20);
      expect(capture.pageUrl, 'https://example.com');
      await fixture.page.close();
    });

    test('the screenshot is clipped to the element box', () async {
      final fixture = buildCapturePage();
      await fixture.page.captureSelector('#go');
      expect(fixture.socket.paramsFor('Page.captureScreenshot')!['clip'], {
        'x': 10.0,
        'y': 20.0,
        'width': 120.0,
        'height': 40.0,
        'scale': 1,
      });
      await fixture.page.close();
    });

    test(
      'an element with no area gets no screenshot rather than a blank one',
      () async {
        final fixture = buildPage(
          responder: (method, params) => switch (method) {
            'DOM.getDocument' => {
              'root': {'nodeId': 1},
            },
            'DOM.querySelector' => {'nodeId': 42},
            'DOM.getOuterHTML' => {'outerHTML': '<span id="x"></span>'},
            'CSS.getComputedStyleForNode' => {'computedStyle': <Object?>[]},
            _ => null,
          },
        );
        final capture = await fixture.page.captureElement(
          const PickedElement(
            selector: '#x',
            tagName: 'span',
            box: ElementBox(x: 0, y: 0, width: 0, height: 0),
            url: 'https://example.com',
            title: 'Example',
          ),
        );
        expect(capture.screenshotPng, isNull);
        expect(
          fixture.socket.methods,
          isNot(contains('Page.captureScreenshot')),
        );
        await fixture.page.close();
      },
    );

    test('without a selector it hit-tests the click point instead', () async {
      final fixture = buildPage(
        responder: (method, params) => switch (method) {
          'DOM.getDocument' => {
            'root': {'nodeId': 1},
          },
          'DOM.getNodeForLocation' => {'backendNodeId': 77},
          'DOM.pushNodesByBackendIdsToFrontend' => {
            'nodeIds': [88],
          },
          'DOM.getOuterHTML' => {'outerHTML': '<div id="shadow-inner"></div>'},
          'CSS.getComputedStyleForNode' => {'computedStyle': <Object?>[]},
          'Page.captureScreenshot' => {
            'data': base64Encode([1]),
          },
          _ => null,
        },
      );
      final capture = await fixture.page.captureElement(
        const PickedElement(
          tagName: 'div',
          clientX: 120,
          clientY: 240,
          box: ElementBox(x: 60, y: 210, width: 200, height: 100),
          url: 'https://example.com',
          title: 'Example',
        ),
      );
      expect(capture.outerHtml, contains('shadow-inner'));
      expect(capture.selector, contains('picked by position'));
      expect(fixture.socket.paramsFor('DOM.getNodeForLocation'), {
        'x': 120,
        'y': 240,
        'includeUserAgentShadowDOM': false,
      });
      expect(fixture.socket.paramsFor('DOM.getOuterHTML'), {'nodeId': 88});
      await fixture.page.close();
    });

    test(
      'an element addressable neither way is reported, not guessed',
      () async {
        final fixture = buildPage();
        await expectLater(
          fixture.page.captureElement(
            const PickedElement(
              tagName: 'div',
              box: ElementBox(x: 0, y: 0, width: 10, height: 10),
              url: '',
              title: '',
            ),
          ),
          failsWith(BrowserFailure.elementNotFound),
        );
        await fixture.page.close();
      },
    );

    test('a selector that matches nothing is reported', () async {
      final fixture = buildPage(
        responder: (method, params) =>
            method == 'Runtime.evaluate' ? evaluated(null) : null,
      );
      await expectLater(
        fixture.page.captureSelector('#nope'),
        failsWith(BrowserFailure.elementNotFound),
      );
      await fixture.page.close();
    });
  });

  group('nextEvent', () {
    test(
      'fails as disconnected the moment the browser goes, not on timeout',
      () async {
        final fixture = buildPage();
        final waiting = fixture.page.nextEvent(
          'Page.loadEventFired',
          timeout: const Duration(seconds: 30),
          detail: 'while loading',
        );
        fixture.socket.drop();
        await expectLater(waiting, failsWith(BrowserFailure.disconnected));
      },
    );

    test('uses the caller-supplied failure kind on timeout', () async {
      final fixture = buildPage();
      await expectLater(
        fixture.page.nextEvent(
          'Page.loadEventFired',
          timeout: const Duration(milliseconds: 20),
          detail: 'while loading',
          onTimeout: BrowserFailure.navigationTimeout,
        ),
        failsWith(BrowserFailure.navigationTimeout),
      );
      await fixture.page.close();
    });
  });

  test('isConnected follows the socket', () async {
    final fixture = buildPage();
    expect(fixture.page.isConnected, isTrue);
    fixture.socket.drop();
    await pumpEventQueue();
    expect(fixture.page.isConnected, isFalse);
  });
}
